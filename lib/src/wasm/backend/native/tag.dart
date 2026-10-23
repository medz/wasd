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
            ValueKind.externref || ValueKind.funcref => ir.WasmValueType.i32,
            _ => throw UnsupportedError(
              'Native public tags do not support v128 payloads.',
            ),
          },
        )
        .toList(growable: false);
    return _host ??= WasmTagImport(
      type: ir.WasmFunctionType(
        params: List.unmodifiable(params),
        results: const [],
        kind: ir.WasmCompositeTypeKind.function,
        paramTypeSignatures: List.unmodifiable(_parameters.map(_signature)),
      ),
      nominalTypeKey: 'host:tag:${_nextHostTagId++}',
      typeKey: '${params.map((type) => type.index).join(',')}->',
    );
  }

  static void checkSupportedType(ir.WasmFunctionType type) {
    _runtimeParameters(type);
  }

  String parameterSignature(int index) => _signature(_parameters[index]);

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
        switch ((
          ir.WasmModule.canonicalTagSignature(type.paramTypeSignatures[i]),
          type.params[i],
        )) {
          ('7f', ir.WasmValueType.i32) => ValueKind.i32,
          ('7e', ir.WasmValueType.i64) => ValueKind.i64,
          ('7d', ir.WasmValueType.f32) => ValueKind.f32,
          ('7c', ir.WasmValueType.f64) => ValueKind.f64,
          ('6f', ir.WasmValueType.i32) => ValueKind.externref,
          ('70', ir.WasmValueType.i32) => ValueKind.funcref,
          _ => throw UnsupportedError(
            'Native public tags support numeric, nullable externref and '
            'nullable funcref payloads only.',
          ),
        },
    ]);
  }

  static String _signature(ValueKind kind) => switch (kind) {
    ValueKind.i32 => '7f',
    ValueKind.i64 => '7e',
    ValueKind.f32 => '7d',
    ValueKind.f64 => '7c',
    ValueKind.externref => '6f',
    ValueKind.funcref => '70',
    _ => throw UnsupportedError('Unsupported native tag payload kind.'),
  };
}
