/// Returns whether [value] is an integer in the signed canonical `i64` range.
bool wasiComponentIsI64Int(Object? value) {
  if (value is! int) {
    return false;
  }
  return _isBigIntInRange(BigInt.from(value), _i64Min, _i64Max);
}

/// Returns whether [value] is an integer in the unsigned canonical `u64` range.
bool wasiComponentIsU64Int(Object? value) {
  if (value is! int || value < 0) {
    return false;
  }
  return BigInt.from(value) <= _u64Max;
}

bool _isBigIntInRange(BigInt value, BigInt min, BigInt max) =>
    value >= min && value <= max;

final BigInt _i64Min = -(BigInt.one << 63);
final BigInt _i64Max = (BigInt.one << 63) - BigInt.one;
final BigInt _u64Max = (BigInt.one << 64) - BigInt.one;
