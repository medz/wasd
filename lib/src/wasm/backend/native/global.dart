import '../../global.dart' as wasm;
import '../../value.dart';
import 'interpreter/module.dart' as ir;
import 'interpreter/runtime_global.dart';
import 'interpreter/value.dart';

/// A value box that shares numeric Wasm storage when imported or exported.
class Global<T extends Value<T, V>, V extends Object?>
    implements wasm.Global<T, V> {
  Global(this.descriptor, V initialValue)
    : _mutable = descriptor.mutable,
      _value = initialValue;

  Global._fromRuntime(this.descriptor, RuntimeGlobal binding)
    : _mutable = binding.mutable,
      _value = _publicValue(binding.value) as V,
      _host = binding;

  final wasm.GlobalDescriptor<T, V> descriptor;
  final bool _mutable;
  V _value;
  RuntimeGlobal? _host;

  // Bind only when used by Wasm, preserving the existing standalone value box.
  RuntimeGlobal get host {
    final type = switch (descriptor.value) {
      ValueKind.i32 => ir.WasmValueType.i32,
      ValueKind.i64 => ir.WasmValueType.i64,
      ValueKind.f32 => ir.WasmValueType.f32,
      ValueKind.f64 => ir.WasmValueType.f64,
      _ => throw UnsupportedError(
        'Native global imports support numeric kinds only.',
      ),
    };
    return _host ??= RuntimeGlobal(
      valueType: type,
      valueTypeSignature: switch (type) {
        ir.WasmValueType.i32 => '7f',
        ir.WasmValueType.i64 => '7e',
        ir.WasmValueType.f32 => '7d',
        ir.WasmValueType.f64 => '7c',
      },
      mutable: _mutable,
      value: WasmValue.fromExternal(type, _value),
    );
  }

  @override
  V get value => _host == null ? _value : _publicValue(_host!.value) as V;

  @override
  set value(V v) {
    if (!_mutable) throw StateError('Cannot set value of immutable global');
    final binding = _host;
    if (binding == null) {
      _value = v;
    } else {
      binding.setValue(WasmValue.fromExternal(binding.valueType, v));
    }
  }
}

Object _publicValue(WasmValue value) => switch (value.type) {
  ir.WasmValueType.i64 => value.asI64(),
  _ => value.toExternal(),
};

bool isNumericBinding(RuntimeGlobal binding) =>
    binding.valueTypeSignature == null ||
    const {'7f', '7e', '7d', '7c'}.contains(binding.valueTypeSignature);

wasm.Global fromRuntime(RuntimeGlobal binding) => switch (binding.valueType) {
  ir.WasmValueType.i32 => Global<Int32, int>._fromRuntime(
    wasm.GlobalDescriptor<Int32, int>(
      value: ValueKind.i32,
      mutable: binding.mutable,
    ),
    binding,
  ),
  ir.WasmValueType.i64 => Global<Int64, BigInt>._fromRuntime(
    wasm.GlobalDescriptor<Int64, BigInt>(
      value: ValueKind.i64,
      mutable: binding.mutable,
    ),
    binding,
  ),
  ir.WasmValueType.f32 => Global<Float32, double>._fromRuntime(
    wasm.GlobalDescriptor<Float32, double>(
      value: ValueKind.f32,
      mutable: binding.mutable,
    ),
    binding,
  ),
  ir.WasmValueType.f64 => Global<Float64, double>._fromRuntime(
    wasm.GlobalDescriptor<Float64, double>(
      value: ValueKind.f64,
      mutable: binding.mutable,
    ),
    binding,
  ),
};
