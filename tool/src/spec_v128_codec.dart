import 'dart:typed_data';

Uint8List parseV128LiteralBytes(Map<String, Object?> raw) {
  final laneType = raw['lane_type'];
  final value = raw['value'];
  if (laneType is! String || laneType.isEmpty || value is! List) {
    throw const FormatException('invalid-v128-value');
  }
  final lanes = value.cast<Object?>();
  switch (laneType) {
    case 'i8':
      return _encodeIntegerLanes(lanes, laneCount: 16, laneBits: 8);
    case 'i16':
      return _encodeIntegerLanes(lanes, laneCount: 8, laneBits: 16);
    case 'i32':
      return _encodeIntegerLanes(lanes, laneCount: 4, laneBits: 32);
    case 'i64':
      return _encodeIntegerLanes(lanes, laneCount: 2, laneBits: 64);
    case 'f32':
      return _encodeFloatingLanes(lanes, laneCount: 4, laneBits: 32);
    case 'f64':
      return _encodeFloatingLanes(lanes, laneCount: 2, laneBits: 64);
    default:
      throw FormatException('unsupported-v128-lane-type:$laneType');
  }
}

Uint8List _encodeIntegerLanes(
  List<Object?> lanes, {
  required int laneCount,
  required int laneBits,
}) {
  if (lanes.length != laneCount) {
    throw const FormatException('invalid-v128-value');
  }
  final bytes = Uint8List(16);
  final laneBytes = laneBits ~/ 8;
  for (var i = 0; i < laneCount; i++) {
    final value = _parseInteger(lanes[i]);
    final normalized = _toUnsignedBits(value, laneBits);
    _writeUnsignedLittleEndian(
      bytes,
      offset: i * laneBytes,
      value: normalized,
      byteWidth: laneBytes,
    );
  }
  return bytes;
}

Uint8List _encodeFloatingLanes(
  List<Object?> lanes, {
  required int laneCount,
  required int laneBits,
}) {
  if (lanes.length != laneCount) {
    throw const FormatException('invalid-v128-value');
  }
  final bytes = Uint8List(16);
  final laneBytes = laneBits ~/ 8;
  for (var i = 0; i < laneCount; i++) {
    final laneBitsValue = _parseFloatingBits(lanes[i], laneBits);
    final normalized = _toUnsignedBits(laneBitsValue, laneBits);
    _writeUnsignedLittleEndian(
      bytes,
      offset: i * laneBytes,
      value: normalized,
      byteWidth: laneBytes,
    );
  }
  return bytes;
}

BigInt _parseInteger(Object? raw) {
  if (raw is BigInt) {
    return raw;
  }
  if (raw is int) {
    return BigInt.from(raw);
  }
  if (raw is num) {
    return BigInt.from(raw.toInt());
  }
  if (raw is String) {
    final parsed = _tryParseInteger(raw);
    if (parsed != null) {
      return parsed;
    }
  }
  throw const FormatException('invalid-v128-value');
}

BigInt _parseFloatingBits(Object? raw, int bits) {
  if (raw is String) {
    final normalized = raw.trim().toLowerCase();
    if (normalized.startsWith('nan:')) {
      return bits == 32
          ? BigInt.from(0x7fc00000)
          : BigInt.parse('7ff8000000000000', radix: 16);
    }
    final integer = _tryParseInteger(raw);
    if (integer != null) {
      return integer;
    }
    final parsed = _parseFloat(raw);
    return bits == 32 ? _f32Bits(parsed) : _f64Bits(parsed);
  }
  if (raw is int || raw is BigInt) {
    return _parseInteger(raw);
  }
  if (raw is num) {
    return bits == 32
        ? _f32Bits(raw.toDouble())
        : _f64Bits(raw.toDouble());
  }
  throw const FormatException('invalid-v128-value');
}

BigInt? _tryParseInteger(String raw) {
  final normalized = raw.replaceAll('_', '').trim();
  if (normalized.isEmpty) {
    return null;
  }
  final sign = normalized.startsWith('-') ? -1 : 1;
  final unsigned = normalized.startsWith('-') || normalized.startsWith('+')
      ? normalized.substring(1)
      : normalized;
  if (unsigned.startsWith('0x') || unsigned.startsWith('0X')) {
    final digits = unsigned.substring(2);
    if (digits.isEmpty) {
      return null;
    }
    final value = BigInt.parse(digits, radix: 16);
    return sign < 0 ? -value : value;
  }
  return BigInt.tryParse(normalized);
}

double _parseFloat(String raw) {
  final normalized = raw.replaceAll('_', '').trim().toLowerCase();
  switch (normalized) {
    case 'nan':
    case '+nan':
    case '-nan':
      return double.nan;
    case 'inf':
    case '+inf':
      return double.infinity;
    case '-inf':
      return double.negativeInfinity;
    default:
      return double.parse(normalized);
  }
}

BigInt _toUnsignedBits(BigInt value, int bits) {
  final width = BigInt.one << bits;
  final mask = width - BigInt.one;
  return value & mask;
}

BigInt _f32Bits(double value) {
  final data = ByteData(4)..setFloat32(0, value, Endian.little);
  return BigInt.from(data.getUint32(0, Endian.little));
}

BigInt _f64Bits(double value) {
  final data = ByteData(8)..setFloat64(0, value, Endian.little);
  final low = BigInt.from(data.getUint32(0, Endian.little));
  final high = BigInt.from(data.getUint32(4, Endian.little));
  return low | (high << 32);
}

void _writeUnsignedLittleEndian(
  Uint8List out, {
  required int offset,
  required BigInt value,
  required int byteWidth,
}) {
  for (var i = 0; i < byteWidth; i++) {
    final byte = (value >> (i * 8)) & BigInt.from(0xff);
    out[offset + i] = byte.toInt();
  }
}
