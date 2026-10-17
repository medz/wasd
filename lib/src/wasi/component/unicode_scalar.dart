/// Invalid Core bit pattern lifted as a Component Unicode scalar.
final class WASIComponentInvalidCharException extends StateError {
  /// Retains the canonical adapter's diagnostic [message].
  WASIComponentInvalidCharException(super.message);
}

/// Returns whether [value] is a Unicode scalar value.
bool isWASIComponentUnicodeScalar(int value) =>
    value >= 0 && value <= 0x10ffff && (value < 0xd800 || value > 0xdfff);

/// Returns the single Unicode scalar represented by [value], or `null`.
int? singleWASIComponentUnicodeScalar(Object? value) {
  if (value is! String) {
    return null;
  }
  final iterator = value.runes.iterator;
  if (!iterator.moveNext()) {
    return null;
  }
  final scalar = iterator.current;
  if (iterator.moveNext() || !isWASIComponentUnicodeScalar(scalar)) {
    return null;
  }
  return scalar;
}
