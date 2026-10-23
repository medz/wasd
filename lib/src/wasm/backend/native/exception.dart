import '../../exception.dart' as wasm;
import '../../tag.dart' as wasm_tag;
import 'interpreter/module.dart' as ir;
import 'interpreter/value.dart';
import 'interpreter/vm.dart';
import 'reference_values.dart';
import 'tag.dart' as native_tag;

class Exception implements wasm.Exception {
  factory Exception(
    wasm_tag.Tag tag,
    List<Object?> payload, [
    wasm.ExceptionOptions? options,
  ]) {
    final references = ReferenceValues();
    final host = _encode(tag as native_tag.Tag, payload, references);
    return _wrappers[host] = Exception._fromRuntime(host, references);
  }

  Exception._fromRuntime(this.host, this.references);

  factory Exception.fromRuntime(
    WasmGuestException host,
    ReferenceValues references,
  ) {
    final wrapper = _wrappers[host] ??= Exception._fromRuntime(
      host,
      references,
    );
    references.connect(wrapper.references);
    return wrapper;
  }

  static final _wrappers = Expando<Exception>('WebAssembly.Exception');

  // Keep the original carrier so exception references and float bits survive
  // guest -> Dart -> guest propagation. Native does not capture an extra stack.
  final WasmGuestException host;
  final ReferenceValues references;

  static WasmGuestException _encode(
    native_tag.Tag tag,
    List<Object?> payload,
    ReferenceValues references,
  ) {
    final binding = tag.host;
    final parameters = binding.type.params;
    if (payload.length != parameters.length) {
      throw ArgumentError.value(
        payload,
        'payload',
        'Expected ${parameters.length} values for tag payload, '
            'got ${payload.length}.',
      );
    }
    return WasmGuestException(
      nominalTypeKey: binding.nominalTypeKey,
      values: List<WasmValue>.unmodifiable([
        for (var i = 0; i < parameters.length; i++)
          switch (parameters[i]) {
            ir.WasmValueType.i32 => WasmValue.i32(
              references.encode(tag.parameterSignature(i), payload[i]) as int,
            ),
            ir.WasmValueType.i64 => WasmValue.i64(payload[i] as BigInt),
            ir.WasmValueType.f32 => WasmValue.f32(payload[i] as double),
            ir.WasmValueType.f64 => WasmValue.f64(payload[i] as double),
          },
      ]),
    );
  }

  @override
  bool isTag(wasm_tag.Tag candidate) =>
      candidate is native_tag.Tag &&
      candidate.nominalTypeKey == host.nominalTypeKey;

  @override
  Object? getArg(wasm_tag.Tag candidate, int index) {
    if (!isTag(candidate)) {
      throw ArgumentError.value(
        candidate,
        'tag',
        'Tag mismatch for this exception',
      );
    }
    RangeError.checkValidIndex(index, host.values);
    final value = host.values[index];
    return references.decode(
      (candidate as native_tag.Tag).parameterSignature(index),
      value.type == ir.WasmValueType.i64 ? value.asI64() : value.toExternal(),
    );
  }
}
