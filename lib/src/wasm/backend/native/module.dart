import 'dart:typed_data';

import '../../errors.dart';
import '../../module.dart' as wasm;
import 'interpreter/byte_reader.dart';
import 'interpreter/features.dart' as native_features;
import 'interpreter/module.dart' as native_ir;
import 'interpreter/predecode.dart' as native_predecode;
import 'interpreter/validator.dart' as native_validator;

class Module implements wasm.Module {
  Module(ByteBuffer bytes, {Set<wasm.CoreFeature> features = const {}})
    : _bytes = bytes,
      features = native_features.WasmFeatureSet(
        exceptionHandling: features.contains(
          wasm.CoreFeature.exceptionHandling,
        ),
        additionalEnabled: Set.unmodifiable(
          features.map(
            (feature) => switch (feature) {
              wasm.CoreFeature.multiMemory => 'multi-memory',
              wasm.CoreFeature.exceptionHandling => 'exception-handling',
            },
          ),
        ),
      ) {
    final compiled = _decode(bytes, this.features);
    decoded = compiled.module;
    predecodedFunctions = compiled.predecodedFunctions;
  }

  final ByteBuffer _bytes;
  final native_features.WasmFeatureSet features;
  static const supportedFeatures = <wasm.CoreFeature>{
    wasm.CoreFeature.multiMemory,
    wasm.CoreFeature.exceptionHandling,
  };
  late final native_ir.WasmModule decoded;
  late final List<native_predecode.PredecodedFunction> predecodedFunctions;

  static ({
    native_ir.WasmModule module,
    List<native_predecode.PredecodedFunction> predecodedFunctions,
  })
  _decode(ByteBuffer bytes, native_features.WasmFeatureSet features) {
    try {
      final module = native_ir.WasmModule.decode(
        bytes.asUint8List(),
        features: features,
      );
      final predecodedFunctions = <native_predecode.PredecodedFunction>[];
      native_validator.WasmValidator.validateModule(
        module,
        features: features,
        predecodedFunctions: predecodedFunctions,
      );
      return (
        module: module,
        predecodedFunctions: List.unmodifiable(predecodedFunctions),
      );
    } on FormatException catch (e) {
      throw CompileError(e.message, cause: e);
    } on UnsupportedError catch (e) {
      throw CompileError(e.message ?? e.toString(), cause: e);
    } on ArgumentError catch (e) {
      throw CompileError(e.message ?? e.toString(), cause: e);
    }
  }
}

List<wasm.ModuleImportDescriptor> imports(wasm.Module module) => [
  for (final imp in (module as Module).decoded.imports)
    wasm.ModuleImportDescriptor(
      kind: _toImportKind(imp.kind),
      module: imp.module,
      name: imp.name,
    ),
];

List<wasm.ModuleExportDescriptor> exports(wasm.Module module) => [
  for (final exp in (module as Module).decoded.exports)
    wasm.ModuleExportDescriptor(kind: _toExportKind(exp.kind), name: exp.name),
];

List<ByteBuffer> customSections(wasm.Module module, String name) =>
    _parseCustomSections((module as Module)._bytes.asUint8List(), name);

wasm.ImportExportKind _toImportKind(int kind) => switch (kind) {
  native_ir.WasmImportKind.function ||
  native_ir.WasmImportKind.exactFunction => wasm.ImportExportKind.function,
  native_ir.WasmImportKind.table => wasm.ImportExportKind.table,
  native_ir.WasmImportKind.memory => wasm.ImportExportKind.memory,
  native_ir.WasmImportKind.global => wasm.ImportExportKind.global,
  native_ir.WasmImportKind.tag => wasm.ImportExportKind.tag,
  _ => throw UnsupportedError('Unsupported import kind: $kind'),
};

wasm.ImportExportKind _toExportKind(int kind) => switch (kind) {
  native_ir.WasmExportKind.function => wasm.ImportExportKind.function,
  native_ir.WasmExportKind.table => wasm.ImportExportKind.table,
  native_ir.WasmExportKind.memory => wasm.ImportExportKind.memory,
  native_ir.WasmExportKind.global => wasm.ImportExportKind.global,
  native_ir.WasmExportKind.tag => wasm.ImportExportKind.tag,
  _ => throw UnsupportedError('Unsupported export kind: $kind'),
};

// ── Custom-section parser ─────────────────────────────────────────────────────

/// Parses the binary and returns payloads of all custom sections named [name].
List<ByteBuffer> _parseCustomSections(Uint8List bytes, String name) {
  final result = <ByteBuffer>[];
  final reader = ByteReader(bytes)..offset = 8; // skip magic + version
  while (!reader.isEOF) {
    final sectionId = reader.readByte();
    final size = reader.readVarUint32();
    final sectionEnd = reader.offset + size;
    if (sectionId == 0 && reader.readName() == name) {
      result.add(reader.readBytes(sectionEnd - reader.offset).buffer);
    }
    reader.offset = sectionEnd;
  }
  return result;
}
