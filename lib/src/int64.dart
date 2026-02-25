abstract final class WasmI64 {
  static final BigInt _modulus = BigInt.one << 64;
  static final BigInt _mask = _modulus - BigInt.one;
  static final BigInt _signBit = BigInt.one << 63;
  static final BigInt _u32Mask = (BigInt.one << 32) - BigInt.one;

  static final int maxSigned = BigInt.parse(
    '7fffffffffffffff',
    radix: 16,
  ).toInt();
  static final int minSigned = -maxSigned - 1;
  static final int magnitudeMask = maxSigned;
  static final int signBitMask = minSigned;
  static const int allOnesMask = -1;

  static BigInt _toUnsignedBigInt(int value) {
    return BigInt.from(value) & _mask;
  }

  static BigInt _toSignedBigInt(int value) {
    var v = _toUnsignedBigInt(value);
    if ((v & _signBit) != BigInt.zero) {
      v -= _modulus;
    }
    return v;
  }

  static int _signedFromBigInt(BigInt value) {
    var v = value & _mask;
    if ((v & _signBit) != BigInt.zero) {
      v -= _modulus;
    }
    return v.toInt();
  }

  static int _bitPatternFromBigInt(BigInt value) {
    // Dart `int` cannot represent unsigned 64-bit values >= 2^63 as positive
    // integers, so keep the canonical two's-complement bit pattern instead.
    return _signedFromBigInt(value);
  }

  static int signed(int value) {
    return _signedFromBigInt(BigInt.from(value));
  }

  static int unsigned(int value) {
    return _bitPatternFromBigInt(BigInt.from(value));
  }

  static int compareUnsigned(int lhs, int rhs) {
    return _toUnsignedBigInt(lhs).compareTo(_toUnsignedBigInt(rhs));
  }

  static int add(int lhs, int rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) + _toUnsignedBigInt(rhs));
  }

  static int sub(int lhs, int rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) - _toUnsignedBigInt(rhs));
  }

  static int mul(int lhs, int rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) * _toUnsignedBigInt(rhs));
  }

  static int divS(int lhs, int rhs) {
    final quotient = _toSignedBigInt(lhs) ~/ _toSignedBigInt(rhs);
    return _signedFromBigInt(quotient);
  }

  static int divU(int lhs, int rhs) {
    final quotient = _toUnsignedBigInt(lhs) ~/ _toUnsignedBigInt(rhs);
    return _signedFromBigInt(quotient);
  }

  static int remS(int lhs, int rhs) {
    final remainder = _toSignedBigInt(lhs).remainder(_toSignedBigInt(rhs));
    return _signedFromBigInt(remainder);
  }

  static int remU(int lhs, int rhs) {
    final remainder = _toUnsignedBigInt(lhs).remainder(_toUnsignedBigInt(rhs));
    return _signedFromBigInt(remainder);
  }

  static int and(int lhs, int rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) & _toUnsignedBigInt(rhs));
  }

  static int or(int lhs, int rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) | _toUnsignedBigInt(rhs));
  }

  static int xor(int lhs, int rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) ^ _toUnsignedBigInt(rhs));
  }

  static int shl(int value, int shift) {
    return _signedFromBigInt(_toUnsignedBigInt(value) << shift);
  }

  static int shrS(int value, int shift) {
    return _signedFromBigInt(_toSignedBigInt(value) >> shift);
  }

  static int shrU(int value, int shift) {
    return _signedFromBigInt(_toUnsignedBigInt(value) >> shift);
  }

  static int rotl(int value, int shift) {
    final normalizedShift = shift & 63;
    if (normalizedShift == 0) {
      return signed(value);
    }
    final unsignedValue = _toUnsignedBigInt(value);
    final rotated =
        ((unsignedValue << normalizedShift) |
            (unsignedValue >> (64 - normalizedShift))) &
        _mask;
    return _signedFromBigInt(rotated);
  }

  static int rotr(int value, int shift) {
    final normalizedShift = shift & 63;
    if (normalizedShift == 0) {
      return signed(value);
    }
    final unsignedValue = _toUnsignedBigInt(value);
    final rotated =
        ((unsignedValue >> normalizedShift) |
            (unsignedValue << (64 - normalizedShift))) &
        _mask;
    return _signedFromBigInt(rotated);
  }

  static int clz(int value) {
    final normalized = _toUnsignedBigInt(value);
    if (normalized == BigInt.zero) {
      return 64;
    }
    return 64 - normalized.bitLength;
  }

  static int ctz(int value) {
    var normalized = _toUnsignedBigInt(value);
    if (normalized == BigInt.zero) {
      return 64;
    }
    var count = 0;
    while ((normalized & BigInt.one) == BigInt.zero) {
      count++;
      normalized >>= 1;
    }
    return count;
  }

  static int popcnt(int value) {
    var normalized = _toUnsignedBigInt(value);
    var count = 0;
    while (normalized != BigInt.zero) {
      normalized &= normalized - BigInt.one;
      count++;
    }
    return count;
  }

  static double unsignedToDouble(int value) {
    return _toUnsignedBigInt(value).toDouble();
  }

  static int signExtend(int value, int bits) {
    if (bits <= 0 || bits > 64) {
      throw ArgumentError.value(bits, 'bits', 'must be in 1..64');
    }
    final width = BigInt.one << bits;
    final mask = width - BigInt.one;
    var v = BigInt.from(value) & mask;
    final sign = BigInt.one << (bits - 1);
    if ((v & sign) != BigInt.zero) {
      v -= width;
    }
    return signed(v.toInt());
  }

  static int lowU32(int value) {
    return (_toUnsignedBigInt(value) & _u32Mask).toInt();
  }

  static int highU32(int value) {
    return ((_toUnsignedBigInt(value) >> 32) & _u32Mask).toInt();
  }

  static int fromU32PairSigned({required int low, required int high}) {
    final lo = BigInt.from(low) & _u32Mask;
    final hi = BigInt.from(high) & _u32Mask;
    return _signedFromBigInt((hi << 32) | lo);
  }

  static int fromU32PairUnsigned({required int low, required int high}) {
    final lo = BigInt.from(low) & _u32Mask;
    final hi = BigInt.from(high) & _u32Mask;
    return _bitPatternFromBigInt((hi << 32) | lo);
  }
}
