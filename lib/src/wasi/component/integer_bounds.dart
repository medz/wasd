/// Returns whether [value] is an integer in the signed canonical `i64` range.
bool wasiComponentIsI64Int(Object? value) {
  if (value is int) {
    return _isBigIntInRange(BigInt.from(value), _i64Min, _i64Max);
  }
  if (value is BigInt) {
    return _isBigIntInRange(value, _i64Min, _i64Max);
  }
  return false;
}

/// Returns whether [value] is an integer in the unsigned canonical `u64` range.
bool wasiComponentIsU64Int(Object? value) {
  if (value is int) {
    if (value < 0) {
      return false;
    }
    return BigInt.from(value) <= _u64Max;
  }
  if (value is BigInt) {
    return value >= BigInt.zero && value <= _u64Max;
  }
  return false;
}

/// Converts a checked canonical 64-bit integer value to a Dart [int].
int wasiComponentI64ToInt(Object value) {
  if (!wasiComponentIsI64Int(value)) {
    throw StateError('Value is outside the canonical i64 range.');
  }
  return value is BigInt ? value.toInt() : value as int;
}

/// Converts a checked canonical 64-bit unsigned integer value to a Dart [int].
int wasiComponentU64ToInt(Object value) {
  if (!wasiComponentIsU64Int(value)) {
    throw StateError('Value is outside the canonical u64 range.');
  }
  return value is BigInt ? value.toInt() : value as int;
}

bool _isBigIntInRange(BigInt value, BigInt min, BigInt max) =>
    value >= min && value <= max;

final BigInt _i64Min = -(BigInt.one << 63);
final BigInt _i64Max = (BigInt.one << 63) - BigInt.one;
final BigInt _u64Max = (BigInt.one << 64) - BigInt.one;
