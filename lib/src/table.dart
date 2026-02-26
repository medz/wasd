import 'module.dart';

final class WasmTable {
  WasmTable({
    required this.refType,
    required this.min,
    this.max,
    this.isTable64 = false,
    this.refTypeSignature,
  }) : _entries = List<int?>.filled(
         _validatedMin(min, max),
         null,
         growable: true,
       );

  final WasmRefType refType;
  final int min;
  final int? max;
  final bool isTable64;
  final String? refTypeSignature;
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
    if (newLength > 0x7fffffff) {
      return -1;
    }
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
    initializeRange(
      offset,
      functionIndices,
      sourceOffset: 0,
      length: functionIndices.length,
    );
  }

  void initializeRange(
    int offset,
    List<int?> functionIndices, {
    int sourceOffset = 0,
    int? length,
  }) {
    final writeLength = length ?? (functionIndices.length - sourceOffset);
    if (sourceOffset < 0 ||
        writeLength < 0 ||
        sourceOffset > functionIndices.length ||
        writeLength > functionIndices.length - sourceOffset) {
      throw RangeError('Invalid source range for table initialization.');
    }
    if (offset < 0 || offset + writeLength > _entries.length) {
      throw RangeError(
        'Element initialization out of bounds: offset=$offset, '
        'length=$writeLength, table=${_entries.length}.',
      );
    }

    for (var i = 0; i < writeLength; i++) {
      _entries[offset + i] = functionIndices[sourceOffset + i];
    }
  }

  void copyEntries({
    required WasmTable source,
    required int destinationOffset,
    required int sourceOffset,
    required int length,
  }) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length');
    }
    if (sourceOffset < 0 || sourceOffset + length > source._entries.length) {
      throw RangeError(
        'Table copy source out of bounds: offset=$sourceOffset, '
        'length=$length, table=${source._entries.length}.',
      );
    }
    if (destinationOffset < 0 || destinationOffset + length > _entries.length) {
      throw RangeError(
        'Table copy destination out of bounds: offset=$destinationOffset, '
        'length=$length, table=${_entries.length}.',
      );
    }
    if (length == 0) {
      return;
    }
    if (identical(this, source) && destinationOffset > sourceOffset) {
      for (var i = length - 1; i >= 0; i--) {
        _entries[destinationOffset + i] = _entries[sourceOffset + i];
      }
      return;
    }
    for (var i = 0; i < length; i++) {
      _entries[destinationOffset + i] = source._entries[sourceOffset + i];
    }
  }

  void fillRange(int offset, int length, int? value) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length');
    }
    if (offset < 0 || offset + length > _entries.length) {
      throw RangeError(
        'Table fill out of bounds: offset=$offset, length=$length, '
        'table=${_entries.length}.',
      );
    }
    _entries.fillRange(offset, offset + length, value);
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
