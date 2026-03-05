import 'dart:typed_data';

import '../../errors.dart';
import '../../module.dart' as wasm;
import 'interpreter/module.dart' as native_ir;

class Module implements wasm.Module {
  Module(ByteBuffer bytes) : _bytes = bytes, decoded = _decode(bytes);

  final ByteBuffer _bytes;
  final native_ir.WasmModule decoded;

  static native_ir.WasmModule _decode(ByteBuffer bytes) {
    try {
      return native_ir.WasmModule.decode(bytes.asUint8List());
    } on FormatException catch (e) {
      throw CompileError(e.message, cause: e);
    } on UnsupportedError catch (e) {
      throw CompileError(e.message, cause: e);
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
  native_ir.WasmImportKind.function || native_ir.WasmImportKind.exactFunction =>
    wasm.ImportExportKind.function,
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
  var i = 8; // skip magic + version
  while (i < bytes.length) {
    final sectionId = bytes[i++];
    var size = 0;
    var shift = 0;
    while (i < bytes.length) {
      final b = bytes[i++];
      size |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
    }
    final sectionEnd = i + size;
    if (sectionId == 0 && sectionEnd <= bytes.length) {
      var nameLen = 0;
      var nameShift = 0;
      var j = i;
      while (j < sectionEnd) {
        final b = bytes[j++];
        nameLen |= (b & 0x7f) << nameShift;
        if (b & 0x80 == 0) break;
        nameShift += 7;
      }
      final nameEnd = j + nameLen;
      if (nameEnd <= sectionEnd) {
        final sectionName = String.fromCharCodes(bytes, j, nameEnd);
        if (sectionName == name) {
          result.add(
            Uint8List.fromList(bytes.sublist(nameEnd, sectionEnd)).buffer,
          );
        }
      }
    }
    i = sectionEnd;
  }
  return result;
}
