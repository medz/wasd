import '../../global.dart' as wasm;
import '../../value.dart';
import 'interpreter/module.dart' as ir;
import 'interpreter/runtime_global.dart';
import 'interpreter/value.dart';
import 'reference_values.dart';

/// A value box that shares Wasm storage when imported or exported.
class Global<T extends Value<T, V>, V extends Object?>
    implements wasm.Global<T, V> {
  Global(this.descriptor, V initialValue)
    : _mutable = descriptor.mutable,
      _value = initialValue;

  Global._fromRuntime(this.descriptor, RuntimeGlobal binding, this._references)
    : _mutable = binding.mutable,
      _value = null,
      _host = binding;

  final wasm.GlobalDescriptor<T, V> descriptor;
  final bool _mutable;
  Object? _value;
  RuntimeGlobal? _host;
  ReferenceValues? _references;

  ReferenceValues get references => _references ??= ReferenceValues();

  // Bind only when used by Wasm, preserving the existing standalone value box.
  RuntimeGlobal get host {
    final type = switch (descriptor.value) {
      ValueKind.i32 => ir.WasmValueType.i32,
      ValueKind.i64 => ir.WasmValueType.i64,
      ValueKind.f32 => ir.WasmValueType.f32,
      ValueKind.f64 => ir.WasmValueType.f64,
      ValueKind.externref || ValueKind.funcref => ir.WasmValueType.i32,
      _ => throw UnsupportedError('Native global imports do not support v128.'),
    };
    final existing = _host;
    if (existing != null) return existing;
    final signature = descriptor.value == ValueKind.externref
        ? '6f'
        : descriptor.value == ValueKind.funcref
        ? '70'
        : switch (type) {
            ir.WasmValueType.i32 => '7f',
            ir.WasmValueType.i64 => '7e',
            ir.WasmValueType.f32 => '7d',
            ir.WasmValueType.f64 => '7c',
          };
    final binding = RuntimeGlobal(
      valueType: type,
      valueTypeSignature: signature,
      mutable: _mutable,
      value: WasmValue.fromExternal(
        type,
        ReferenceValues.isExtern(signature) ||
                ReferenceValues.isFunction(signature)
            ? references.encode(signature, _value)
            : _value,
      ),
    );
    _host = binding;
    _value = null;
    return binding;
  }

  @override
  V get value {
    final binding = _host;
    if (binding == null) return _value as V;
    final value = _publicValue(binding.value);
    if (ReferenceValues.isExtern(binding.valueTypeSignature) ||
        ReferenceValues.isFunction(binding.valueTypeSignature)) {
      return references.decode(binding.valueTypeSignature, value) as V;
    }
    return value as V;
  }

  @override
  set value(V v) {
    if (!_mutable) throw StateError('Cannot set value of immutable global');
    final binding = _host;
    if (binding == null) {
      _value = v;
    } else {
      binding.setValue(
        WasmValue.fromExternal(
          binding.valueType,
          ReferenceValues.isExtern(binding.valueTypeSignature) ||
                  ReferenceValues.isFunction(binding.valueTypeSignature)
              ? references.encode(binding.valueTypeSignature, v)
              : v,
        ),
      );
    }
  }
}

Object _publicValue(WasmValue value) => switch (value.type) {
  ir.WasmValueType.i64 => value.asI64(),
  _ => value.toExternal(),
};

wasm.Global fromRuntime(RuntimeGlobal binding, ReferenceValues references) {
  ReferenceValues.checkSignature(binding.valueTypeSignature);
  if (ReferenceValues.isExtern(binding.valueTypeSignature)) {
    return Global<ExternRef, Object?>._fromRuntime(
      wasm.GlobalDescriptor(
        value: ValueKind.externref,
        mutable: binding.mutable,
      ),
      binding,
      references,
    );
  }
  if (ReferenceValues.isFunction(binding.valueTypeSignature)) {
    return Global<FuncRef, Function?>._fromRuntime(
      wasm.GlobalDescriptor(value: ValueKind.funcref, mutable: binding.mutable),
      binding,
      references,
    );
  }
  return switch (binding.valueType) {
    ir.WasmValueType.i32 => Global<Int32, int>._fromRuntime(
      wasm.GlobalDescriptor<Int32, int>(
        value: ValueKind.i32,
        mutable: binding.mutable,
      ),
      binding,
      references,
    ),
    ir.WasmValueType.i64 => Global<Int64, BigInt>._fromRuntime(
      wasm.GlobalDescriptor<Int64, BigInt>(
        value: ValueKind.i64,
        mutable: binding.mutable,
      ),
      binding,
      references,
    ),
    ir.WasmValueType.f32 => Global<Float32, double>._fromRuntime(
      wasm.GlobalDescriptor<Float32, double>(
        value: ValueKind.f32,
        mutable: binding.mutable,
      ),
      binding,
      references,
    ),
    ir.WasmValueType.f64 => Global<Float64, double>._fromRuntime(
      wasm.GlobalDescriptor<Float64, double>(
        value: ValueKind.f64,
        mutable: binding.mutable,
      ),
      binding,
      references,
    ),
  };
}
