import 'dart:convert';
import 'dart:typed_data';

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
    var leadingBomBytes = 0;
    while (leadingBomBytes + 2 < bytes.length &&
        bytes[leadingBomBytes] == 0xef &&
        bytes[leadingBomBytes + 1] == 0xbb &&
        bytes[leadingBomBytes + 2] == 0xbf) {
      leadingBomBytes += 3;
    }
    if (leadingBomBytes == 0) {
      return utf8.decode(bytes);
    }
    final suffix = utf8.decode(bytes.sublist(leadingBomBytes));
    final bomCount = leadingBomBytes ~/ 3;
    return '${'\uFEFF' * bomCount}$suffix';
  }

  int readVarUint32() {
    var result = 0;
    var multiplier = 1;

    for (var i = 0; i < 5; i++) {
      final byte = readByte();
      result += (byte & 0x7f) * multiplier;

      if ((byte & 0x80) == 0) {
        if (i == 4 && (byte & 0xf0) != 0) {
          throw const FormatException('Invalid varuint32 encoding.');
        }
        return result;
      }

      multiplier *= 128;
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
    var multiplier = 1;
    var byteCount = 0;
    var terminalByte = 0;

    for (var i = 0; i < 5; i++) {
      final byte = readByte();
      byteCount = i + 1;
      terminalByte = byte;
      result += (byte & 0x7f) * multiplier;
      multiplier *= 128;

      if ((byte & 0x80) == 0) {
        if (i == 4) {
          final payload = byte & 0x7f;
          if (payload > 0x07 && payload < 0x78) {
            throw const FormatException('Invalid varint32 encoding.');
          }
        }

        final shift = byteCount * 7;
        if (shift < 32 && (terminalByte & 0x40) != 0) {
          result -= 1 << shift;
        }
        return result.toSigned(32);
      }

      if (i == 4) {
        throw const FormatException('Invalid varint32 encoding.');
      }
    }

    throw const FormatException('Invalid varint32 encoding.');
  }

  Object readVarInt64Value() {
    final signed = _readVarInt64BigInt();
    const maxSafe = 9007199254740991;
    const minSafe = -9007199254740991;
    if (signed >= BigInt.from(minSafe) && signed <= BigInt.from(maxSafe)) {
      return signed.toInt();
    }
    return signed;
  }

  int readVarInt64() {
    final value = readVarInt64Value();
    if (value is int) {
      return value;
    }
    return (value as BigInt).toInt();
  }

  BigInt _readVarInt64BigInt() {
    var result = BigInt.zero;
    var shift = 0;
    var byte = 0;
    var byteCount = 0;
    const maxBytes = 10;
    final min = -(BigInt.one << 63);
    final max = (BigInt.one << 63) - BigInt.one;

    while (true) {
      byte = readByte();
      byteCount++;
      result |= BigInt.from(byte & 0x7f) << shift;
      shift += 7;

      if ((byte & 0x80) == 0) {
        break;
      }

      if (byteCount >= maxBytes) {
        throw const FormatException('Invalid varint64 encoding.');
      }
    }

    if (byteCount > maxBytes) {
      throw const FormatException('Invalid varint64 encoding.');
    }
    if (byteCount == maxBytes) {
      final payload = byte & 0x7f;
      if (payload != 0x00 && payload != 0x7f) {
        throw const FormatException('Invalid varint64 encoding.');
      }
    }

    if (shift < 64 && (byte & 0x40) != 0) {
      result |= (-BigInt.one) << shift;
    }

    // Canonicalize to 64-bit two's-complement first, then map to signed.
    // This avoids `BigInt.toInt()` saturation for values with bit 63 set.
    final normalized = result & ((BigInt.one << 64) - BigInt.one);
    var signed = normalized;
    if ((normalized & (BigInt.one << 63)) != BigInt.zero) {
      signed -= BigInt.one << 64;
    }
    if (signed < min || signed > max) {
      throw const FormatException('Invalid varint64 encoding.');
    }
    return signed;
  }

  void expectEof() {
    if (!isEOF) {
      throw FormatException('Expected EOF. Remaining bytes: $remaining.');
    }
  }
}
