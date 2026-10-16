import '../../tag.dart' as wasm;
import '../../value.dart';
import 'interpreter/imports.dart';
import 'interpreter/module.dart' as ir;

class Tag implements wasm.Tag {
  Tag(wasm.TagDescriptor descriptor)
    : _parameters = List<ValueKind>.unmodifiable(descriptor.parameters);

  Tag.fromRuntime(WasmTagImport binding)
    : _parameters = _runtimeParameters(binding.type),
      _host = binding;

  static var _nextHostTagId = 0;
  final List<ValueKind> _parameters;
  WasmTagImport? _host;

  String? get nominalTypeKey => _host?.nominalTypeKey;

  WasmTagImport get host {
    final existing = _host;
    if (existing != null) return existing;
    final params = _parameters
        .map(
          (kind) => switch (kind) {
            ValueKind.i32 => ir.WasmValueType.i32,
            ValueKind.i64 => ir.WasmValueType.i64,
            ValueKind.f32 => ir.WasmValueType.f32,
            ValueKind.f64 => ir.WasmValueType.f64,
            _ => throw UnsupportedError(
              'Native tag bindings support numeric payload kinds only.',
            ),
          },
        )
        .toList(growable: false);
    return _host ??= WasmTagImport(
      type: ir.WasmFunctionType(
        params: List.unmodifiable(params),
        results: const [],
        kind: ir.WasmCompositeTypeKind.function,
        paramTypeSignatures: List.unmodifiable(params.map(_signature)),
      ),
      nominalTypeKey: 'host:tag:${_nextHostTagId++}',
      typeKey: '${params.map((type) => type.index).join(',')}->',
    );
  }

  static void checkSupportedType(ir.WasmFunctionType type) {
    _runtimeParameters(type);
  }

  @override
  wasm.TagDescriptor type() =>
      wasm.TagDescriptor(parameters: List<ValueKind>.of(_parameters));

  static List<ValueKind> _runtimeParameters(ir.WasmFunctionType type) {
    if (!type.isFunctionType ||
        (type.declaresSubtype && !type.subtypeFinal) ||
        type.superTypeIndices.isNotEmpty ||
        type.recGroupSize != 1 ||
        type.descriptorTypeIndex != null ||
        type.describesTypeIndex != null ||
        type.results.isNotEmpty ||
        type.resultTypeSignatures.isNotEmpty ||
        type.paramTypeSignatures.length != type.params.length) {
      throw UnsupportedError('Unsupported native tag payload signature.');
    }
    return List.unmodifiable([
      for (var i = 0; i < type.params.length; i++)
        if (type.paramTypeSignatures[i] == _signature(type.params[i]))
          switch (type.params[i]) {
            ir.WasmValueType.i32 => ValueKind.i32,
            ir.WasmValueType.i64 => ValueKind.i64,
            ir.WasmValueType.f32 => ValueKind.f32,
            ir.WasmValueType.f64 => ValueKind.f64,
          }
        else
          throw UnsupportedError(
            'Native tag bindings support numeric payload kinds only.',
          ),
    ]);
  }

  static String _signature(ir.WasmValueType type) => switch (type) {
    ir.WasmValueType.i32 => '7f',
    ir.WasmValueType.i64 => '7e',
    ir.WasmValueType.f32 => '7d',
    ir.WasmValueType.f64 => '7c',
  };
}
