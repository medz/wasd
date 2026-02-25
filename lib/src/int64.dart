abstract final class WasmI64 {
  static final BigInt _modulus = BigInt.one << 64;
  static final BigInt _mask = _modulus - BigInt.one;
  static final BigInt _signBit = BigInt.one << 63;
  static final BigInt _u32Mask = (BigInt.one << 32) - BigInt.one;

  static final BigInt maxSigned = BigInt.parse('7fffffffffffffff', radix: 16);
  static final BigInt minSigned = -maxSigned - BigInt.one;
  static final BigInt magnitudeMask = maxSigned;
  static final BigInt signBitMask = minSigned;
  static final BigInt allOnesMask = -BigInt.one;

  static BigInt _toBigInt(Object value) {
    if (value is BigInt) {
      return value;
    }
    if (value is int) {
      return BigInt.from(value);
    }
    if (value is String) {
      return BigInt.parse(value);
    }
    throw ArgumentError('Unsupported i64 value type: ${value.runtimeType}');
  }

  static BigInt _toUnsignedBigInt(Object value) {
    return _toBigInt(value) & _mask;
  }

  static BigInt _toSignedBigInt(Object value) {
    var v = _toUnsignedBigInt(value);
    if ((v & _signBit) != BigInt.zero) {
      v -= _modulus;
    }
    return v;
  }

  static BigInt _signedFromBigInt(BigInt value) {
    var v = value & _mask;
    if ((v & _signBit) != BigInt.zero) {
      v -= _modulus;
    }
    return v;
  }

  static BigInt _bitPatternFromBigInt(BigInt value) {
    return value & _mask;
  }

  static BigInt signed(Object value) {
    return _signedFromBigInt(_toBigInt(value));
  }

  static BigInt unsigned(Object value) {
    return _bitPatternFromBigInt(_toBigInt(value));
  }

  static int compareUnsigned(Object lhs, Object rhs) {
    return _toUnsignedBigInt(lhs).compareTo(_toUnsignedBigInt(rhs));
  }

  static BigInt add(Object lhs, Object rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) + _toUnsignedBigInt(rhs));
  }

  static BigInt sub(Object lhs, Object rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) - _toUnsignedBigInt(rhs));
  }

  static BigInt mul(Object lhs, Object rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) * _toUnsignedBigInt(rhs));
  }

  static BigInt divS(Object lhs, Object rhs) {
    final quotient = _toSignedBigInt(lhs) ~/ _toSignedBigInt(rhs);
    return _signedFromBigInt(quotient);
  }

  static BigInt divU(Object lhs, Object rhs) {
    final quotient = _toUnsignedBigInt(lhs) ~/ _toUnsignedBigInt(rhs);
    return _signedFromBigInt(quotient);
  }

  static BigInt remS(Object lhs, Object rhs) {
    final remainder = _toSignedBigInt(lhs).remainder(_toSignedBigInt(rhs));
    return _signedFromBigInt(remainder);
  }

  static BigInt remU(Object lhs, Object rhs) {
    final remainder = _toUnsignedBigInt(lhs).remainder(_toUnsignedBigInt(rhs));
    return _signedFromBigInt(remainder);
  }

  static BigInt and(Object lhs, Object rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) & _toUnsignedBigInt(rhs));
  }

  static BigInt or(Object lhs, Object rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) | _toUnsignedBigInt(rhs));
  }

  static BigInt xor(Object lhs, Object rhs) {
    return _signedFromBigInt(_toUnsignedBigInt(lhs) ^ _toUnsignedBigInt(rhs));
  }

  static BigInt shl(Object value, int shift) {
    return _signedFromBigInt(_toUnsignedBigInt(value) << shift);
  }

  static BigInt shrS(Object value, int shift) {
    return _signedFromBigInt(_toSignedBigInt(value) >> shift);
  }

  static BigInt shrU(Object value, int shift) {
    return _signedFromBigInt(_toUnsignedBigInt(value) >> shift);
  }

  static BigInt rotl(Object value, int shift) {
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

  static BigInt rotr(Object value, int shift) {
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

  static BigInt clz(Object value) {
    final normalized = _toUnsignedBigInt(value);
    if (normalized == BigInt.zero) {
      return BigInt.from(64);
    }
    return BigInt.from(64 - normalized.bitLength);
  }

  static BigInt ctz(Object value) {
    var normalized = _toUnsignedBigInt(value);
    if (normalized == BigInt.zero) {
      return BigInt.from(64);
    }
    var count = 0;
    while ((normalized & BigInt.one) == BigInt.zero) {
      count++;
      normalized >>= 1;
    }
    return BigInt.from(count);
  }

  static BigInt popcnt(Object value) {
    var normalized = _toUnsignedBigInt(value);
    var count = 0;
    while (normalized != BigInt.zero) {
      normalized &= normalized - BigInt.one;
      count++;
    }
    return BigInt.from(count);
  }

  static double unsignedToDouble(Object value) {
    return _toUnsignedBigInt(value).toDouble();
  }

  static BigInt signExtend(Object value, int bits) {
    if (bits <= 0 || bits > 64) {
      throw ArgumentError.value(bits, 'bits', 'must be in 1..64');
    }
    final width = BigInt.one << bits;
    final mask = width - BigInt.one;
    var v = _toBigInt(value) & mask;
    final sign = BigInt.one << (bits - 1);
    if ((v & sign) != BigInt.zero) {
      v -= width;
    }
    return signed(v);
  }

  static int lowU32(Object value) {
    return (_toUnsignedBigInt(value) & _u32Mask).toInt();
  }

  static int highU32(Object value) {
    return ((_toUnsignedBigInt(value) >> 32) & _u32Mask).toInt();
  }

  static BigInt fromU32PairSigned({required int low, required int high}) {
    final lo = BigInt.from(low) & _u32Mask;
    final hi = BigInt.from(high) & _u32Mask;
    return _signedFromBigInt((hi << 32) | lo);
  }

  static BigInt fromU32PairUnsigned({required int low, required int high}) {
    final lo = BigInt.from(low) & _u32Mask;
    final hi = BigInt.from(high) & _u32Mask;
    return _bitPatternFromBigInt((hi << 32) | lo);
  }

  static bool fitsInInt(BigInt value) {
    const maxSafe = 9007199254740991;
    const minSafe = -9007199254740991;
    return value >= BigInt.from(minSafe) && value <= BigInt.from(maxSafe);
  }
}
