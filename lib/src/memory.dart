import 'dart:typed_data';

import 'int64.dart';

const int wasmPageSize = 64 * 1024;
const int wasmMaxPages = 65536;

final class WasmMemory {
  WasmMemory({required this.minPages, this.maxPages, this.shared = false})
    : _buffer = Uint8List(
        _validatedInitialPageCount(minPages, maxPages) * wasmPageSize,
      ) {
    _view = ByteData.sublistView(_buffer);
  }

  final int minPages;
  final int? maxPages;
  final bool shared;
  Uint8List _buffer;
  late ByteData _view;

  int get lengthInBytes => _buffer.length;
  int get pageCount => _buffer.length ~/ wasmPageSize;

  int loadI8(int address) {
    _checkBounds(address, 1);
    return _view.getInt8(address);
  }

  int loadU8(int address) {
    _checkBounds(address, 1);
    return _view.getUint8(address);
  }

  int loadI16(int address) {
    _checkBounds(address, 2);
    return _view.getInt16(address, Endian.little);
  }

  int loadU16(int address) {
    _checkBounds(address, 2);
    return _view.getUint16(address, Endian.little);
  }

  int loadI32(int address) {
    _checkBounds(address, 4);
    return _view.getInt32(address, Endian.little);
  }

  int loadU32(int address) {
    _checkBounds(address, 4);
    return _view.getUint32(address, Endian.little);
  }

  int loadI64(int address) {
    _checkBounds(address, 8);
    final low = _view.getUint32(address, Endian.little);
    final high = _view.getUint32(address + 4, Endian.little);
    return WasmI64.fromU32PairSigned(low: low, high: high);
  }

  int loadU64(int address) {
    _checkBounds(address, 8);
    final low = _view.getUint32(address, Endian.little);
    final high = _view.getUint32(address + 4, Endian.little);
    return WasmI64.fromU32PairUnsigned(low: low, high: high);
  }

  double loadF32(int address) {
    _checkBounds(address, 4);
    return _view.getFloat32(address, Endian.little);
  }

  double loadF64(int address) {
    _checkBounds(address, 8);
    return _view.getFloat64(address, Endian.little);
  }

  void storeI8(int address, int value) {
    _checkBounds(address, 1);
    _view.setInt8(address, value.toSigned(8));
  }

  void storeI16(int address, int value) {
    _checkBounds(address, 2);
    _view.setInt16(address, value.toSigned(16), Endian.little);
  }

  void storeI32(int address, int value) {
    _checkBounds(address, 4);
    _view.setInt32(address, value.toSigned(32), Endian.little);
  }

  void storeI64(int address, int value) {
    _checkBounds(address, 8);
    final normalized = WasmI64.signed(value);
    final low = WasmI64.lowU32(normalized);
    final high = WasmI64.highU32(normalized);
    _view.setUint32(address, low, Endian.little);
    _view.setUint32(address + 4, high, Endian.little);
  }

  void storeF32(int address, double value) {
    _checkBounds(address, 4);
    _view.setFloat32(address, value, Endian.little);
  }

  void storeF64(int address, double value) {
    _checkBounds(address, 8);
    _view.setFloat64(address, value, Endian.little);
  }

  Uint8List readBytes(int address, int length) {
    _checkBounds(address, length);
    return Uint8List.fromList(_buffer.sublist(address, address + length));
  }

  void writeBytes(int address, Uint8List bytes) {
    _checkBounds(address, bytes.length);
    _buffer.setRange(address, address + bytes.length, bytes);
  }

  void copyBytes(int destination, int source, int length) {
    _checkBounds(source, length);
    _checkBounds(destination, length);
    _buffer.setRange(destination, destination + length, _buffer, source);
  }

  void fillBytes(int destination, int value, int length) {
    _checkBounds(destination, length);
    _buffer.fillRange(destination, destination + length, value.toUnsigned(8));
  }

  int grow(int additionalPages) {
    if (additionalPages < 0) {
      throw ArgumentError.value(additionalPages, 'additionalPages');
    }

    final oldPages = pageCount;
    final newPages = oldPages + additionalPages;
    final maxLimit = maxPages ?? wasmMaxPages;

    if (newPages > maxLimit) {
      return -1;
    }

    final grown = Uint8List(newPages * wasmPageSize);
    grown.setRange(0, _buffer.length, _buffer);
    _buffer = grown;
    _view = ByteData.sublistView(_buffer);

    return oldPages;
  }

  Uint8List snapshot() => Uint8List.fromList(_buffer);

  void _checkBounds(int address, int width) {
    if (address < 0 || width < 0 || address + width > _buffer.length) {
      throw RangeError(
        'Out-of-bounds memory access at $address (width=$width, '
        'length=${_buffer.length}).',
      );
    }
  }

  static int _validatedInitialPageCount(int minPages, int? maxPages) {
    if (minPages < 0) {
      throw ArgumentError.value(minPages, 'minPages');
    }
    if (minPages > wasmMaxPages) {
      throw ArgumentError.value(
        minPages,
        'minPages',
        'must be <= $wasmMaxPages',
      );
    }
    if (maxPages != null) {
      if (maxPages < minPages) {
        throw ArgumentError.value(
          maxPages,
          'maxPages',
          'must be >= minPages ($minPages)',
        );
      }
      if (maxPages > wasmMaxPages) {
        throw ArgumentError.value(
          maxPages,
          'maxPages',
          'must be <= $wasmMaxPages',
        );
      }
    }
    return minPages;
  }
}
