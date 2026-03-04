import 'dart:typed_data';

import '../../errors.dart';
import '../../module.dart' as wasm;
import 'interpreter/module.dart' as old;

class Module implements wasm.Module {
  Module(ByteBuffer bytes)
    : _bytes = bytes,
      host = _decode(bytes);

  final ByteBuffer _bytes;
  final old.WasmModule host;

  static old.WasmModule _decode(ByteBuffer bytes) {
    try {
      return old.WasmModule.decode(bytes.asUint8List());
    } on FormatException catch (e) {
      throw CompileError(e.message, cause: e);
    }
  }
}

List<wasm.ModuleImportDescriptor> imports(wasm.Module module) => [
  for (final imp in (module as Module).host.imports)
    wasm.ModuleImportDescriptor(
      kind: _importKind(imp.kind),
      module: imp.module,
      name: imp.name,
    ),
];

List<wasm.ModuleExportDescriptor> exports(wasm.Module module) => [
  for (final exp in (module as Module).host.exports)
    wasm.ModuleExportDescriptor(kind: _exportKind(exp.kind), name: exp.name),
];

List<ByteBuffer> customSections(wasm.Module module, String name) =>
    _parseCustomSections((module as Module)._bytes.asUint8List(), name);

// ── Kind mappings ─────────────────────────────────────────────────────────────

wasm.ImportExportKind _importKind(int k) {
  if (k == old.WasmImportKind.function || k == old.WasmImportKind.exactFunction) {
    return wasm.ImportExportKind.function;
  }
  if (k == old.WasmImportKind.table) return wasm.ImportExportKind.table;
  if (k == old.WasmImportKind.memory) return wasm.ImportExportKind.memory;
  if (k == old.WasmImportKind.global) return wasm.ImportExportKind.global;
  if (k == old.WasmImportKind.tag) return wasm.ImportExportKind.tag;
  throw UnsupportedError('Unknown import kind: $k');
}

wasm.ImportExportKind _exportKind(int k) {
  if (k == old.WasmExportKind.function) return wasm.ImportExportKind.function;
  if (k == old.WasmExportKind.table) return wasm.ImportExportKind.table;
  if (k == old.WasmExportKind.memory) return wasm.ImportExportKind.memory;
  if (k == old.WasmExportKind.global) return wasm.ImportExportKind.global;
  if (k == old.WasmExportKind.tag) return wasm.ImportExportKind.tag;
  throw UnsupportedError('Unknown export kind: $k');
}

// ── Custom-section parser ─────────────────────────────────────────────────────

/// Parses the WebAssembly binary and returns raw payloads of all custom
/// sections whose name equals [name].
List<ByteBuffer> _parseCustomSections(Uint8List bytes, String name) {
  final result = <ByteBuffer>[];
  var i = 8; // skip magic (4 bytes) + version (4 bytes)
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
      // Leading LEB128 name length followed by UTF-8 name bytes.
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
          result.add(Uint8List.fromList(bytes.sublist(nameEnd, sectionEnd)).buffer);
        }
      }
    }
    i = sectionEnd;
  }
  return result;
}
