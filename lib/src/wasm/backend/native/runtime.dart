/// WebAssembly runtime: linear memory and stack-machine executor.
library;

import 'dart:typed_data';

import 'decoder.dart';

const int _pageSize = 65536;

// ── Linear memory ─────────────────────────────────────────────────────────────

/// A WebAssembly linear memory backed by a growable [Uint8List].
class LinearMemory {
  /// Creates a linear memory with [minPages] initial pages and an optional
  /// [maxPages] limit.
  LinearMemory({required int minPages, int? maxPages})
    : _maxPages = maxPages,
      _pages = minPages,
      _data = Uint8List(minPages * _pageSize);

  final int? _maxPages;
  int _pages;
  Uint8List _data;

  /// Returns the current memory buffer.
  ByteBuffer get buffer => _data.buffer;

  /// Grows memory by [delta] pages. Returns the previous page count, or `-1`
  /// if the growth would exceed [_maxPages].
  int grow(int delta) {
    final prev = _pages;
    final next = prev + delta;
    if (_maxPages case final max? when next > max) return -1;
    final newData = Uint8List(next * _pageSize);
    newData.setRange(0, _data.length, _data);
    _data = newData;
    _pages = next;
    return prev;
  }
}

// ── Executor ──────────────────────────────────────────────────────────────────

/// A host function callable from WebAssembly.
typedef HostFn = Object? Function(List<Object?>);

/// Executes the WebAssembly function at [globalFuncIdx] with [args].
///
/// [globalFuncIdx] is zero-based and includes imported functions (which are
/// dispatched to [hostFunctions]).
Object? execute(
  WasmDecoded module,
  int globalFuncIdx,
  List<Object?> args,
  List<HostFn> hostFunctions,
  List<LinearMemory> memories,
) {
  final importCount = module.importedFunctionCount;
  if (globalFuncIdx < importCount) {
    return hostFunctions[globalFuncIdx](args);
  }

  final localIdx = globalFuncIdx - importCount;
  final funcType = module.types[module.functions[localIdx]];
  final codeBody = module.codes[localIdx];
  final r = _CodeReader(codeBody);

  // Parse local declarations.
  final groupCount = r.readU32();
  final locals = List<Object?>.of(args);
  for (var g = 0; g < groupCount; g++) {
    final count = r.readU32();
    final type = _readValType(r);
    for (var i = 0; i < count; i++) {
      locals.add(
        switch (type) {
          ValType.i32 || ValType.i64 => 0,
          ValType.f32 || ValType.f64 => 0.0,
          _ => null,
        },
      );
    }
  }

  // Execute instructions.
  final stack = <Object?>[];
  while (!r.isAtEnd) {
    final op = r.readByte();
    switch (op) {
      case 0x0B: // end
        break;
      case 0x10: // call funcIdx
        final callIdx = r.readU32();
        final callType = module.typeOf(callIdx);
        final callArgs = List<Object?>.filled(callType.params.length, null);
        for (var i = callType.params.length - 1; i >= 0; i--) {
          callArgs[i] = stack.removeLast();
        }
        final result = execute(module, callIdx, callArgs, hostFunctions, memories);
        if (callType.results.isNotEmpty) stack.add(result);
      case 0x20: // local.get
        stack.add(locals[r.readU32()]);
      case 0x41: // i32.const
        stack.add(r.readI32());
      case 0x6A: // i32.add
        final b = stack.removeLast() as int;
        final a = stack.removeLast() as int;
        stack.add(a + b);
      default:
        throw UnsupportedError(
          'Unsupported WebAssembly opcode: 0x${op.toRadixString(16)}',
        );
    }
    if (op == 0x0B) break;
  }

  return funcType.results.isEmpty ? null : stack.lastOrNull;
}

// ── Code reader ───────────────────────────────────────────────────────────────

ValType _readValType(_CodeReader r) {
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

class _CodeReader {
  _CodeReader(this._bytes) : _pos = 0;

  final Uint8List _bytes;
  int _pos;

  bool get isAtEnd => _pos >= _bytes.length;

  int readByte() => _bytes[_pos++];

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

  int readI32() {
    var result = 0;
    var shift = 0;
    for (;;) {
      final b = readByte();
      result |= (b & 0x7f) << shift;
      shift += 7;
      if (b & 0x80 == 0) {
        if (shift < 32 && (b & 0x40) != 0) result |= -(1 << shift);
        break;
      }
    }
    return result;
  }
}
