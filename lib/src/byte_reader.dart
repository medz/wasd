import 'dart:convert';
import 'dart:typed_data';

import 'int64.dart';

final class ByteReader {
  ByteReader(Uint8List bytes) : _bytes = bytes, offset = 0;

  final Uint8List _bytes;
  int offset;

  Uint8List get bytes => _bytes;
  int get remaining => _bytes.length - offset;
  bool get isEOF => remaining == 0;

  int readByte() {
    if (isEOF) {
      throw const FormatException('Unexpected EOF while reading byte.');
    }
    return _bytes[offset++];
  }

  Uint8List readBytes(int length) {
    if (length < 0 || remaining < length) {
      throw FormatException(
        'Unexpected EOF while reading $length bytes. Remaining: $remaining.',
      );
    }

    final start = offset;
    offset += length;
    return Uint8List.fromList(_bytes.sublist(start, offset));
  }

  ByteReader readSubReader(int length) {
    return ByteReader(readBytes(length));
  }

  Uint8List readRemainingBytes() {
    return readBytes(remaining);
  }

  String readName() {
    final length = readVarUint32();
    final bytes = readBytes(length);
    return utf8.decode(bytes);
  }

  int readVarUint32() {
    var result = 0;

    for (var i = 0; i < 5; i++) {
      final byte = readByte();
      result |= (byte & 0x7f) << (i * 7);

      if ((byte & 0x80) == 0) {
        if (i == 4 && (byte & 0xf0) != 0) {
          throw const FormatException('Invalid varuint32 encoding.');
        }
        return result;
      }
    }

    throw const FormatException('Invalid varuint32 encoding.');
  }

  int readVarUint64() {
    var result = BigInt.zero;
    var shift = 0;
    var byteCount = 0;
    final max = (BigInt.one << 64) - BigInt.one;

    while (true) {
      final byte = readByte();
      byteCount++;
      result |= BigInt.from(byte & 0x7f) << shift;

      if ((byte & 0x80) == 0) {
        if (byteCount > 10 || result > max) {
          throw const FormatException('Invalid varuint64 encoding.');
        }
        return result.toInt();
      }

      shift += 7;
      if (byteCount >= 10 || shift > 70) {
        throw const FormatException('Invalid varuint64 encoding.');
      }
    }
  }

  int readVarInt32() {
    var result = 0;
    var shift = 0;
    var byte = 0;

    while (true) {
      byte = readByte();
      result |= (byte & 0x7f) << shift;
      shift += 7;

      if ((byte & 0x80) == 0) {
        break;
      }

      if (shift > 35) {
        throw const FormatException('Invalid varint32 encoding.');
      }
    }

    if (shift < 32 && (byte & 0x40) != 0) {
      result |= -1 << shift;
    }

    return result.toSigned(32);
  }

  int readVarInt64() {
    var result = BigInt.zero;
    var shift = 0;
    var byte = 0;

    while (true) {
      byte = readByte();
      result |= BigInt.from(byte & 0x7f) << shift;
      shift += 7;

      if ((byte & 0x80) == 0) {
        break;
      }

      if (shift > 70) {
        throw const FormatException('Invalid varint64 encoding.');
      }
    }

    if (shift < 64 && (byte & 0x40) != 0) {
      result |= (-BigInt.one) << shift;
    }

    return WasmI64.signed(result.toInt());
  }

  void expectEof() {
    if (!isEOF) {
      throw FormatException('Expected EOF. Remaining bytes: $remaining.');
    }
  }
}
