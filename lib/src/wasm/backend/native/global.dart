import '../../global.dart' as wasm;
import '../../value.dart';
import 'interpreter/module.dart' as old_module;
import 'interpreter/runtime_global.dart' as old;
import 'interpreter/value.dart' as old_value;

class Global<T extends Value<T, V>, V extends Object?>
    implements wasm.Global<T, V> {
  Global(wasm.GlobalDescriptor<T, V> descriptor, V initialValue)
    : host = old.RuntimeGlobal(
        valueType: _toWasmValueType(descriptor.value),
        mutable: descriptor.mutable,
        value: old_value.WasmValue.fromExternal(
          _toWasmValueType(descriptor.value),
          initialValue,
        ),
      );

  Global.fromHost(this.host);

  final old.RuntimeGlobal host;

  @override
  V get value => _externalize(host.value) as V;

  @override
  set value(V v) {
    if (!host.mutable) {
      throw StateError('Cannot set value of immutable global');
    }
    host.setValue(old_value.WasmValue.fromExternal(host.valueType, v));
  }
}

old_module.WasmValueType _toWasmValueType(ValueKind<dynamic, dynamic> kind) {
  if (kind == ValueKind.i32) return old_module.WasmValueType.i32;
  if (kind == ValueKind.i64) return old_module.WasmValueType.i64;
  if (kind == ValueKind.f32) return old_module.WasmValueType.f32;
  if (kind == ValueKind.f64) return old_module.WasmValueType.f64;
  throw UnsupportedError(
    'ValueKind $kind is not supported for globals by the native backend.',
  );
}

/// Externalizes a [WasmValue] to the Dart representation expected by callers.
///
/// i64 values are always returned as [BigInt] to match [ValueKind.i64].
Object? _externalize(old_value.WasmValue v) {
  final raw = v.toExternal();
  if (v.type == old_module.WasmValueType.i64 && raw is int) {
    return BigInt.from(raw);
  }
  return raw;
}
