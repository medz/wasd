abstract final class WasmHash {
  static final int _fnvOffsetBasis64 = BigInt.parse(
    '1469598103934665603',
  ).toInt();
  static final int _fnvPrime64 = BigInt.parse('1099511628211').toInt();
  static final int _positiveI64Mask = BigInt.parse(
    '7fffffffffffffff',
    radix: 16,
  ).toInt();

  static int fnv1a64Positive(String value) {
    var hash = _fnvOffsetBasis64;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * _fnvPrime64) & _positiveI64Mask;
    }
    return hash;
  }
}
