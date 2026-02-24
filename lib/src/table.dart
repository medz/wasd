import 'module.dart';

final class WasmTable {
  WasmTable({required this.refType, required this.min, this.max})
    : _entries = List<int?>.filled(
        _validatedMin(min, max),
        null,
        growable: true,
      );

  final WasmRefType refType;
  final int min;
  final int? max;
  final List<int?> _entries;

  int get length => _entries.length;

  int? operator [](int index) {
    _checkIndex(index);
    return _entries[index];
  }

  void operator []=(int index, int? functionIndex) {
    _checkIndex(index);
    _entries[index] = functionIndex;
  }

  int grow(int delta, [int? fill]) {
    if (delta < 0) {
      throw ArgumentError.value(delta, 'delta');
    }

    final oldLength = _entries.length;
    final newLength = oldLength + delta;
    if (max != null && newLength > max!) {
      return -1;
    }

    _entries.length = newLength;
    for (var i = oldLength; i < newLength; i++) {
      _entries[i] = fill;
    }

    return oldLength;
  }

  void initialize(int offset, List<int?> functionIndices) {
    if (offset < 0 || offset + functionIndices.length > _entries.length) {
      throw RangeError(
        'Element initialization out of bounds: offset=$offset, '
        'length=${functionIndices.length}, table=${_entries.length}.',
      );
    }

    for (var i = 0; i < functionIndices.length; i++) {
      _entries[offset + i] = functionIndices[i];
    }
  }

  List<int?> snapshot() => List<int?>.unmodifiable(_entries);

  void _checkIndex(int index) {
    if (index < 0 || index >= _entries.length) {
      throw RangeError(
        'Table index out of range: $index (len=${_entries.length})',
      );
    }
  }

  static int _validatedMin(int min, int? max) {
    if (min < 0) {
      throw ArgumentError.value(min, 'min');
    }
    if (max != null && max < min) {
      throw ArgumentError.value(max, 'max', 'must be >= min ($min)');
    }
    return min;
  }
}
