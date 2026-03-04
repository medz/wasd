/// Pure WebAssembly binary decoder.
///
/// Parses the binary format into [WasmDecoded] without executing anything.
library;

import 'dart:convert';
import 'dart:typed_data';

// ── Value types ───────────────────────────────────────────────────────────────

/// WebAssembly value types.
enum ValType { i32, i64, f32, f64, funcRef, externRef }

/// WebAssembly external kind used in imports and exports.
enum ExternKind { function, table, memory, global, tag }

// ── Data classes ──────────────────────────────────────────────────────────────

/// A WebAssembly function type (signature).
class FuncType {
  const FuncType(this.params, this.results);

  final List<ValType> params;
  final List<ValType> results;
}

/// An entry from the import section.
class ImportEntry {
  const ImportEntry({
    required this.module,
    required this.name,
    required this.kind,
    this.typeIndex = 0,
  });

  final String module;
  final String name;
  final ExternKind kind;

  /// For [ExternKind.function], the index into [WasmDecoded.types].
  final int typeIndex;
}

/// An entry from the export section.
class ExportEntry {
  const ExportEntry({
    required this.name,
    required this.kind,
    required this.index,
  });

  final String name;
  final ExternKind kind;

  /// Index into the corresponding index space.
  final int index;
}

/// A memory definition (limits).
class MemDef {
  const MemDef({required this.min, this.max});

  final int min;
  final int? max;
}

// ── Decoded module ────────────────────────────────────────────────────────────

/// Data decoded from a WebAssembly binary.
class WasmDecoded {
  const WasmDecoded({
    required this.types,
    required this.imports,
    required this.functions,
    required this.memories,
    required this.exports,
    required this.codes,
  });

  final List<FuncType> types;
  final List<ImportEntry> imports;

  /// Type indices for defined (non-imported) functions.
  final List<int> functions;

  final List<MemDef> memories;
  final List<ExportEntry> exports;

  /// Raw code bodies (including local declarations) for each defined function.
  final List<Uint8List> codes;

  /// Number of imported functions.
  int get importedFunctionCount =>
      imports.where((i) => i.kind == ExternKind.function).length;

  /// Returns the [FuncType] for a global function index (imports + definitions).
  FuncType typeOf(int globalFuncIdx) {
    var n = 0;
    for (final imp in imports) {
      if (imp.kind == ExternKind.function) {
        if (n == globalFuncIdx) return types[imp.typeIndex];
        n++;
      }
    }
    final localIdx = globalFuncIdx - n;
    return types[functions[localIdx]];
  }
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decodes a WebAssembly binary into [WasmDecoded].
///
/// Throws [FormatException] if the binary is malformed.
WasmDecoded decode(Uint8List bytes) {
  final r = _Reader(bytes);

  // Magic: \0asm
  if (r.readByte() != 0x00 ||
      r.readByte() != 0x61 ||
      r.readByte() != 0x73 ||
      r.readByte() != 0x6d) {
    throw const FormatException('Invalid WebAssembly magic number');
  }
  // Version: 1
  if (r.readByte() != 0x01 ||
      r.readByte() != 0x00 ||
      r.readByte() != 0x00 ||
      r.readByte() != 0x00) {
    throw const FormatException('Unsupported WebAssembly version');
  }

  final types = <FuncType>[];
  final imports = <ImportEntry>[];
  final functions = <int>[];
  final memories = <MemDef>[];
  final exports = <ExportEntry>[];
  final codes = <Uint8List>[];

  while (!r.isAtEnd) {
    final sectionId = r.readByte();
    final sectionSize = r.readU32();
    final sectionEnd = r.position + sectionSize;

    switch (sectionId) {
      case 1: // type section
        final count = r.readU32();
        for (var i = 0; i < count; i++) {
          if (r.readByte() != 0x60) {
            throw const FormatException('Expected function type tag 0x60');
          }
          final paramCount = r.readU32();
          final params = [for (var j = 0; j < paramCount; j++) _readValType(r)];
          final resultCount = r.readU32();
          final results = [
            for (var j = 0; j < resultCount; j++) _readValType(r),
          ];
          types.add(FuncType(params, results));
        }

      case 2: // import section
        final count = r.readU32();
        for (var i = 0; i < count; i++) {
          final module = r.readName();
          final name = r.readName();
          final kindByte = r.readByte();
          var typeIndex = 0;
          switch (kindByte) {
            case 0: // function → type index
              typeIndex = r.readU32();
            case 1: // table → ref type + limits
              r.readByte();
              _skipLimits(r);
            case 2: // memory → limits
              _skipLimits(r);
            case 3: // global → val type + mutability
              r.readByte();
              r.readByte();
            case 4: // tag → attribute + type index
              r.readByte();
              typeIndex = r.readU32();
          }
          imports.add(
            ImportEntry(
              module: module,
              name: name,
              kind: _externKind(kindByte),
              typeIndex: typeIndex,
            ),
          );
        }

      case 3: // function section
        final count = r.readU32();
        for (var i = 0; i < count; i++) {
          functions.add(r.readU32());
        }

      case 5: // memory section
        final count = r.readU32();
        for (var i = 0; i < count; i++) {
          final flags = r.readByte();
          final min = r.readU32();
          final max = (flags & 1) != 0 ? r.readU32() : null;
          memories.add(MemDef(min: min, max: max));
        }

      case 7: // export section
        final count = r.readU32();
        for (var i = 0; i < count; i++) {
          final name = r.readName();
          final kindByte = r.readByte();
          final index = r.readU32();
          exports.add(
            ExportEntry(name: name, kind: _externKind(kindByte), index: index),
          );
        }

      case 10: // code section
        final count = r.readU32();
        for (var i = 0; i < count; i++) {
          final bodySize = r.readU32();
          codes.add(r.readBytes(bodySize));
        }
    }

    // Always seek to the section end to handle unknown / skipped sections.
    r.seekTo(sectionEnd);
  }

  return WasmDecoded(
    types: types,
    imports: imports,
    functions: functions,
    memories: memories,
    exports: exports,
    codes: codes,
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

ValType _readValType(_Reader r) {
  final b = r.readByte();
  return switch (b) {
    0x7f => ValType.i32,
    0x7e => ValType.i64,
    0x7d => ValType.f32,
    0x7c => ValType.f64,
    0x70 => ValType.funcRef,
    0x6f => ValType.externRef,
    _ => throw FormatException('Unknown value type: 0x${b.toRadixString(16)}'),
  };
}

ExternKind _externKind(int b) => switch (b) {
  0 => ExternKind.function,
  1 => ExternKind.table,
  2 => ExternKind.memory,
  3 => ExternKind.global,
  4 => ExternKind.tag,
  _ => throw FormatException('Unknown extern kind: $b'),
};

void _skipLimits(_Reader r) {
  final flags = r.readByte();
  r.readU32(); // min
  if ((flags & 1) != 0) r.readU32(); // max
}

// ── Binary reader ─────────────────────────────────────────────────────────────

class _Reader {
  _Reader(this._bytes) : _pos = 0;

  final Uint8List _bytes;
  int _pos;

  bool get isAtEnd => _pos >= _bytes.length;
  int get position => _pos;

  int readByte() {
    if (_pos >= _bytes.length) {
      throw const FormatException('Unexpected end of WebAssembly binary');
    }
    return _bytes[_pos++];
  }

  int readU32() {
    var result = 0;
    var shift = 0;
    for (;;) {
      final b = readByte();
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
    }
    return result;
  }

  String readName() {
    final len = readU32();
    final nameBytes = _bytes.sublist(_pos, _pos + len);
    _pos += len;
    return utf8.decode(nameBytes);
  }

  Uint8List readBytes(int n) {
    final result = _bytes.sublist(_pos, _pos + n);
    _pos += n;
    return result;
  }

  void seekTo(int pos) => _pos = pos;
}
