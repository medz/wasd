import 'dart:convert';
import 'dart:typed_data';

import 'int64.dart';
import 'memory.dart';

enum WasmCanonicalAbiType { s32, u32, s64, u64, f32, f64, boolI32, stringUtf8 }

final class WasmCanonicalAbiAllocator {
  WasmCanonicalAbiAllocator({this.cursor = 0, this.maxOffset});

  int cursor;
  final int? maxOffset;

  int allocate(int length, {int alignment = 1}) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'must be >= 0');
    }
    if (alignment <= 0) {
      throw ArgumentError.value(alignment, 'alignment', 'must be > 0');
    }
    final start = _alignUp(cursor, alignment);
    final end = start + length;
    final limit = maxOffset;
    if (limit != null && end > limit) {
      throw RangeError(
        'Canonical ABI allocation exceeds limit: $end > $limit.',
      );
    }
    cursor = end;
    return start;
  }

  static int _alignUp(int value, int alignment) {
    final remainder = value % alignment;
    if (remainder == 0) {
      return value;
    }
    return value + (alignment - remainder);
  }
}

abstract final class WasmCanonicalAbi {
  static List<Object> lowerValues({
    required List<WasmCanonicalAbiType> types,
    required List<Object?> values,
    required WasmMemory memory,
    required WasmCanonicalAbiAllocator allocator,
  }) {
    if (types.length != values.length) {
      throw ArgumentError(
        'types (${types.length}) and values (${values.length}) length mismatch.',
      );
    }

    final flat = <Object>[];
    for (var i = 0; i < types.length; i++) {
      final type = types[i];
      final value = values[i];
      switch (type) {
        case WasmCanonicalAbiType.s32:
          flat.add(_coerceInt32(value));
        case WasmCanonicalAbiType.u32:
          flat.add(_coerceUint32(value));
        case WasmCanonicalAbiType.s64:
          flat.add(_coerceInt64(value));
        case WasmCanonicalAbiType.u64:
          flat.add(_coerceUint64(value));
        case WasmCanonicalAbiType.f32:
          flat.add(_coerceDouble(value));
        case WasmCanonicalAbiType.f64:
          flat.add(_coerceDouble(value));
        case WasmCanonicalAbiType.boolI32:
          flat.add(_coerceBoolI32(value));
        case WasmCanonicalAbiType.stringUtf8:
          if (value is! String) {
            throw ArgumentError(
              'Expected String for canonical ABI string value.',
            );
          }
          final bytes = Uint8List.fromList(utf8.encode(value));
          final pointer = allocator.allocate(bytes.length, alignment: 1);
          memory.writeBytes(pointer, bytes);
          flat
            ..add(pointer.toUnsigned(32))
            ..add(bytes.length.toUnsigned(32));
      }
    }
    return List<Object>.unmodifiable(flat);
  }

  static List<Object?> liftValues({
    required List<WasmCanonicalAbiType> types,
    required List<Object> flatValues,
    required WasmMemory memory,
  }) {
    final values = <Object?>[];
    var cursor = 0;

    int readInt32() {
      if (cursor >= flatValues.length) {
        throw const FormatException('Canonical ABI flat value underflow.');
      }
      final raw = flatValues[cursor++];
      if (raw is! num) {
        throw const FormatException(
          'Canonical ABI expected integer flat value.',
        );
      }
      return raw.toInt().toSigned(32);
    }

    int readUint32() => readInt32().toUnsigned(32);

    BigInt readInt64() {
      if (cursor >= flatValues.length) {
        throw const FormatException('Canonical ABI flat value underflow.');
      }
      final raw = flatValues[cursor++];
      return WasmI64.signed(raw);
    }

    BigInt readUint64() {
      if (cursor >= flatValues.length) {
        throw const FormatException('Canonical ABI flat value underflow.');
      }
      final raw = flatValues[cursor++];
      return WasmI64.unsigned(raw);
    }

    double readDouble() {
      if (cursor >= flatValues.length) {
        throw const FormatException('Canonical ABI flat value underflow.');
      }
      final raw = flatValues[cursor++];
      if (raw is! num) {
        throw const FormatException(
          'Canonical ABI expected numeric flat value.',
        );
      }
      return raw.toDouble();
    }

    for (final type in types) {
      switch (type) {
        case WasmCanonicalAbiType.s32:
          values.add(readInt32());
        case WasmCanonicalAbiType.u32:
          values.add(readUint32());
        case WasmCanonicalAbiType.s64:
          values.add(readInt64());
        case WasmCanonicalAbiType.u64:
          values.add(readUint64());
        case WasmCanonicalAbiType.f32:
          values.add(readDouble());
        case WasmCanonicalAbiType.f64:
          values.add(readDouble());
        case WasmCanonicalAbiType.boolI32:
          values.add(readUint32() != 0);
        case WasmCanonicalAbiType.stringUtf8:
          final pointer = readUint32();
          final length = readUint32();
          final bytes = memory.readBytes(pointer, length);
          values.add(utf8.decode(bytes));
      }
    }

    if (cursor != flatValues.length) {
      throw const FormatException('Canonical ABI flat value arity mismatch.');
    }
    return List<Object?>.unmodifiable(values);
  }

  static int _coerceInt32(Object? value) {
    if (value is! num) {
      throw ArgumentError('Expected numeric i32 value for canonical ABI.');
    }
    return value.toInt().toSigned(32);
  }

  static int _coerceUint32(Object? value) {
    if (value is! num) {
      throw ArgumentError('Expected numeric u32 value for canonical ABI.');
    }
    return value.toInt().toUnsigned(32);
  }

  static BigInt _coerceInt64(Object? value) {
    if (value == null) {
      throw ArgumentError('Expected i64 value for canonical ABI.');
    }
    return WasmI64.signed(value);
  }

  static BigInt _coerceUint64(Object? value) {
    if (value == null) {
      throw ArgumentError('Expected u64 value for canonical ABI.');
    }
    return WasmI64.unsigned(value);
  }

  static double _coerceDouble(Object? value) {
    if (value is! num) {
      throw ArgumentError('Expected floating-point value for canonical ABI.');
    }
    return value.toDouble();
  }

  static int _coerceBoolI32(Object? value) {
    if (value is bool) {
      return value ? 1 : 0;
    }
    if (value is num) {
      return value.toInt() == 0 ? 0 : 1;
    }
    throw ArgumentError('Expected bool-compatible value for canonical ABI.');
  }
}
