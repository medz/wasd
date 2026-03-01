import 'dart:convert';
import 'dart:typed_data';

import 'int64.dart';
import 'memory.dart';

sealed class WasmCanonicalAbiType {
  const WasmCanonicalAbiType();

  static const WasmCanonicalAbiType s32 = WasmCanonicalAbiPrimitiveType._(
    WasmCanonicalAbiPrimitiveKind.s32,
  );
  static const WasmCanonicalAbiType u32 = WasmCanonicalAbiPrimitiveType._(
    WasmCanonicalAbiPrimitiveKind.u32,
  );
  static const WasmCanonicalAbiType s64 = WasmCanonicalAbiPrimitiveType._(
    WasmCanonicalAbiPrimitiveKind.s64,
  );
  static const WasmCanonicalAbiType u64 = WasmCanonicalAbiPrimitiveType._(
    WasmCanonicalAbiPrimitiveKind.u64,
  );
  static const WasmCanonicalAbiType f32 = WasmCanonicalAbiPrimitiveType._(
    WasmCanonicalAbiPrimitiveKind.f32,
  );
  static const WasmCanonicalAbiType f64 = WasmCanonicalAbiPrimitiveType._(
    WasmCanonicalAbiPrimitiveKind.f64,
  );
  static const WasmCanonicalAbiType boolI32 = WasmCanonicalAbiPrimitiveType._(
    WasmCanonicalAbiPrimitiveKind.boolI32,
  );
  static const WasmCanonicalAbiType stringUtf8 =
      WasmCanonicalAbiPrimitiveType._(WasmCanonicalAbiPrimitiveKind.stringUtf8);
  static const WasmCanonicalAbiType bytes = WasmCanonicalAbiPrimitiveType._(
    WasmCanonicalAbiPrimitiveKind.bytes,
  );

  static WasmCanonicalAbiType list(WasmCanonicalAbiType elementType) =>
      WasmCanonicalAbiListType(elementType);

  static WasmCanonicalAbiType record(
    List<WasmCanonicalAbiRecordField> fields,
  ) => WasmCanonicalAbiRecordType(fields);

  static WasmCanonicalAbiType variant(
    List<WasmCanonicalAbiVariantCase> cases,
  ) => WasmCanonicalAbiVariantType(cases);

  static WasmCanonicalAbiType result({
    WasmCanonicalAbiType? ok,
    WasmCanonicalAbiType? error,
  }) => WasmCanonicalAbiResultType(ok: ok, error: error);

  static WasmCanonicalAbiType resource({String? name}) =>
      WasmCanonicalAbiResourceType(name: name);
}

enum WasmCanonicalAbiPrimitiveKind {
  s32,
  u32,
  s64,
  u64,
  f32,
  f64,
  boolI32,
  stringUtf8,
  bytes,
}

final class WasmCanonicalAbiPrimitiveType extends WasmCanonicalAbiType {
  const WasmCanonicalAbiPrimitiveType._(this.kind);

  final WasmCanonicalAbiPrimitiveKind kind;
}

final class WasmCanonicalAbiListType extends WasmCanonicalAbiType {
  const WasmCanonicalAbiListType(this.elementType);

  final WasmCanonicalAbiType elementType;
}

final class WasmCanonicalAbiRecordField {
  const WasmCanonicalAbiRecordField({required this.name, required this.type});

  final String name;
  final WasmCanonicalAbiType type;
}

final class WasmCanonicalAbiRecordType extends WasmCanonicalAbiType {
  WasmCanonicalAbiRecordType(List<WasmCanonicalAbiRecordField> fields)
    : fields = List<WasmCanonicalAbiRecordField>.unmodifiable(fields) {
    if (this.fields.isEmpty) {
      throw ArgumentError('Canonical ABI record type must contain fields.');
    }
    final names = <String>{};
    for (final field in this.fields) {
      if (!names.add(field.name)) {
        throw ArgumentError(
          'Duplicate canonical ABI record field name: ${field.name}',
        );
      }
    }
  }

  final List<WasmCanonicalAbiRecordField> fields;
}

final class WasmCanonicalAbiVariantCase {
  const WasmCanonicalAbiVariantCase({required this.name, this.payloadType});

  final String name;
  final WasmCanonicalAbiType? payloadType;
}

final class WasmCanonicalAbiVariantType extends WasmCanonicalAbiType {
  WasmCanonicalAbiVariantType(List<WasmCanonicalAbiVariantCase> cases)
    : cases = List<WasmCanonicalAbiVariantCase>.unmodifiable(cases) {
    if (this.cases.isEmpty) {
      throw ArgumentError('Canonical ABI variant type must contain cases.');
    }
    final names = <String>{};
    for (final variantCase in this.cases) {
      if (!names.add(variantCase.name)) {
        throw ArgumentError(
          'Duplicate canonical ABI variant case name: ${variantCase.name}',
        );
      }
    }
  }

  final List<WasmCanonicalAbiVariantCase> cases;

  WasmCanonicalAbiVariantCase caseByName(String caseName) {
    for (final candidate in cases) {
      if (candidate.name == caseName) {
        return candidate;
      }
    }
    throw ArgumentError('Unknown canonical ABI variant case: $caseName');
  }
}

final class WasmCanonicalAbiResultType extends WasmCanonicalAbiType {
  const WasmCanonicalAbiResultType({this.ok, this.error});

  final WasmCanonicalAbiType? ok;
  final WasmCanonicalAbiType? error;
}

final class WasmCanonicalAbiResourceType extends WasmCanonicalAbiType {
  const WasmCanonicalAbiResourceType({this.name});

  final String? name;
}

final class WasmCanonicalAbiVariantValue {
  const WasmCanonicalAbiVariantValue({required this.caseName, this.payload});

  final String caseName;
  final Object? payload;

  @override
  bool operator ==(Object other) {
    return other is WasmCanonicalAbiVariantValue &&
        other.caseName == caseName &&
        other.payload == payload;
  }

  @override
  int get hashCode => Object.hash(caseName, payload);
}

final class WasmCanonicalAbiResultValue {
  const WasmCanonicalAbiResultValue._({
    required this.isError,
    required this.value,
  });

  factory WasmCanonicalAbiResultValue.ok(Object? value) =>
      WasmCanonicalAbiResultValue._(isError: false, value: value);

  factory WasmCanonicalAbiResultValue.error(Object? value) =>
      WasmCanonicalAbiResultValue._(isError: true, value: value);

  final bool isError;
  final Object? value;

  @override
  bool operator ==(Object other) {
    return other is WasmCanonicalAbiResultValue &&
        other.isError == isError &&
        other.value == value;
  }

  @override
  int get hashCode => Object.hash(isError, value);
}

final class WasmCanonicalAbiResourceHandle {
  const WasmCanonicalAbiResourceHandle(this.raw);

  final int raw;

  @override
  bool operator ==(Object other) =>
      other is WasmCanonicalAbiResourceHandle && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;
}

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
      _lowerSingleValue(
        type: types[i],
        value: values[i],
        flat: flat,
        memory: memory,
        allocator: allocator,
      );
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

    for (final type in types) {
      final decoded = _liftSingleValue(
        type: type,
        flatValues: flatValues,
        cursor: cursor,
        memory: memory,
      );
      values.add(decoded.value);
      cursor = decoded.nextCursor;
    }

    if (cursor != flatValues.length) {
      throw const FormatException('Canonical ABI flat value arity mismatch.');
    }
    return List<Object?>.unmodifiable(values);
  }

  static void _lowerSingleValue({
    required WasmCanonicalAbiType type,
    required Object? value,
    required List<Object> flat,
    required WasmMemory memory,
    required WasmCanonicalAbiAllocator allocator,
  }) {
    if (type is WasmCanonicalAbiPrimitiveType) {
      switch (type.kind) {
        case WasmCanonicalAbiPrimitiveKind.s32:
          flat.add(_coerceInt32(value));
        case WasmCanonicalAbiPrimitiveKind.u32:
          flat.add(_coerceUint32(value));
        case WasmCanonicalAbiPrimitiveKind.s64:
          flat.add(_coerceInt64(value));
        case WasmCanonicalAbiPrimitiveKind.u64:
          flat.add(_coerceUint64(value));
        case WasmCanonicalAbiPrimitiveKind.f32:
          flat.add(_coerceDouble(value));
        case WasmCanonicalAbiPrimitiveKind.f64:
          flat.add(_coerceDouble(value));
        case WasmCanonicalAbiPrimitiveKind.boolI32:
          flat.add(_coerceBoolI32(value));
        case WasmCanonicalAbiPrimitiveKind.stringUtf8:
          _lowerPointerLengthPayload(
            flat: flat,
            memory: memory,
            allocator: allocator,
            payload: Uint8List.fromList(utf8.encode(_coerceString(value))),
          );
        case WasmCanonicalAbiPrimitiveKind.bytes:
          _lowerPointerLengthPayload(
            flat: flat,
            memory: memory,
            allocator: allocator,
            payload: _coerceBytes(value),
          );
      }
      return;
    }

    if (type is WasmCanonicalAbiResourceType) {
      flat.add(_coerceResourceHandle(value));
      return;
    }

    final encoded = _encodeComposite(type, value);
    _lowerPointerLengthPayload(
      flat: flat,
      memory: memory,
      allocator: allocator,
      payload: encoded,
    );
  }

  static _LiftedValue _liftSingleValue({
    required WasmCanonicalAbiType type,
    required List<Object> flatValues,
    required int cursor,
    required WasmMemory memory,
  }) {
    if (type is WasmCanonicalAbiPrimitiveType) {
      switch (type.kind) {
        case WasmCanonicalAbiPrimitiveKind.s32:
          final (value, nextCursor) = _readInt32(flatValues, cursor);
          return _LiftedValue(value, nextCursor);
        case WasmCanonicalAbiPrimitiveKind.u32:
          final (value, nextCursor) = _readUint32(flatValues, cursor);
          return _LiftedValue(value, nextCursor);
        case WasmCanonicalAbiPrimitiveKind.s64:
          final (value, nextCursor) = _readInt64(flatValues, cursor);
          return _LiftedValue(value, nextCursor);
        case WasmCanonicalAbiPrimitiveKind.u64:
          final (value, nextCursor) = _readUint64(flatValues, cursor);
          return _LiftedValue(value, nextCursor);
        case WasmCanonicalAbiPrimitiveKind.f32:
          final (value, nextCursor) = _readDouble(flatValues, cursor);
          return _LiftedValue(value, nextCursor);
        case WasmCanonicalAbiPrimitiveKind.f64:
          final (value, nextCursor) = _readDouble(flatValues, cursor);
          return _LiftedValue(value, nextCursor);
        case WasmCanonicalAbiPrimitiveKind.boolI32:
          final (value, nextCursor) = _readUint32(flatValues, cursor);
          return _LiftedValue(value != 0, nextCursor);
        case WasmCanonicalAbiPrimitiveKind.stringUtf8:
          final (pointer, afterPointer) = _readUint32(flatValues, cursor);
          final (length, nextCursor) = _readUint32(flatValues, afterPointer);
          final bytes = memory.readBytes(pointer, length);
          return _LiftedValue(utf8.decode(bytes), nextCursor);
        case WasmCanonicalAbiPrimitiveKind.bytes:
          final (pointer, afterPointer) = _readUint32(flatValues, cursor);
          final (length, nextCursor) = _readUint32(flatValues, afterPointer);
          return _LiftedValue(memory.readBytes(pointer, length), nextCursor);
      }
    }

    if (type is WasmCanonicalAbiResourceType) {
      final (raw, nextCursor) = _readUint32(flatValues, cursor);
      return _LiftedValue(WasmCanonicalAbiResourceHandle(raw), nextCursor);
    }

    final (pointer, afterPointer) = _readUint32(flatValues, cursor);
    final (length, nextCursor) = _readUint32(flatValues, afterPointer);
    final bytes = memory.readBytes(pointer, length);
    return _LiftedValue(_decodeComposite(type, bytes), nextCursor);
  }

  static void _lowerPointerLengthPayload({
    required List<Object> flat,
    required WasmMemory memory,
    required WasmCanonicalAbiAllocator allocator,
    required Uint8List payload,
  }) {
    final pointer = allocator.allocate(payload.length, alignment: 1);
    memory.writeBytes(pointer, payload);
    flat
      ..add(pointer.toUnsigned(32))
      ..add(payload.length.toUnsigned(32));
  }

  static Uint8List _encodeComposite(WasmCanonicalAbiType type, Object? value) {
    final serialized = _serializeComposite(type, value);
    final encoded = utf8.encode(jsonEncode(serialized));
    return Uint8List.fromList(encoded);
  }

  static Object? _decodeComposite(
    WasmCanonicalAbiType type,
    Uint8List payload,
  ) {
    final decoded = jsonDecode(utf8.decode(payload));
    return _deserializeComposite(type, decoded);
  }

  static Object? _serializeComposite(WasmCanonicalAbiType type, Object? value) {
    if (type is WasmCanonicalAbiPrimitiveType) {
      switch (type.kind) {
        case WasmCanonicalAbiPrimitiveKind.s32:
          return _coerceInt32(value);
        case WasmCanonicalAbiPrimitiveKind.u32:
          return _coerceUint32(value);
        case WasmCanonicalAbiPrimitiveKind.s64:
          return _coerceInt64(value).toString();
        case WasmCanonicalAbiPrimitiveKind.u64:
          return _coerceUint64(value).toString();
        case WasmCanonicalAbiPrimitiveKind.f32:
          return _coerceDouble(value);
        case WasmCanonicalAbiPrimitiveKind.f64:
          return _coerceDouble(value);
        case WasmCanonicalAbiPrimitiveKind.boolI32:
          return _coerceBoolI32(value) != 0;
        case WasmCanonicalAbiPrimitiveKind.stringUtf8:
          return _coerceString(value);
        case WasmCanonicalAbiPrimitiveKind.bytes:
          return base64Encode(_coerceBytes(value));
      }
    }

    if (type is WasmCanonicalAbiResourceType) {
      return _coerceResourceHandle(value);
    }

    if (type is WasmCanonicalAbiListType) {
      final items = _coerceList(value);
      return items
          .map((item) => _serializeComposite(type.elementType, item))
          .toList(growable: false);
    }

    if (type is WasmCanonicalAbiRecordType) {
      final record = _coerceRecord(value);
      final out = <String, Object?>{};
      for (final field in type.fields) {
        if (!record.containsKey(field.name)) {
          throw ArgumentError(
            'Missing canonical ABI record field: ${field.name}',
          );
        }
        out[field.name] = _serializeComposite(field.type, record[field.name]);
      }
      return out;
    }

    if (type is WasmCanonicalAbiVariantType) {
      final variantValue = _coerceVariantValue(value);
      final selectedCase = type.caseByName(variantValue.caseName);
      final payload = selectedCase.payloadType == null
          ? null
          : _serializeComposite(
              selectedCase.payloadType!,
              variantValue.payload,
            );
      return <String, Object?>{'case': selectedCase.name, 'payload': payload};
    }

    if (type is WasmCanonicalAbiResultType) {
      final result = _coerceResultValue(value);
      if (result.isError) {
        return <String, Object?>{
          'kind': 'error',
          'payload': type.error == null
              ? null
              : _serializeComposite(type.error!, result.value),
        };
      }
      return <String, Object?>{
        'kind': 'ok',
        'payload': type.ok == null
            ? null
            : _serializeComposite(type.ok!, result.value),
      };
    }

    throw UnsupportedError('Unsupported canonical ABI composite type.');
  }

  static Object? _deserializeComposite(
    WasmCanonicalAbiType type,
    Object? data,
  ) {
    if (type is WasmCanonicalAbiPrimitiveType) {
      switch (type.kind) {
        case WasmCanonicalAbiPrimitiveKind.s32:
          return _coerceInt32(data);
        case WasmCanonicalAbiPrimitiveKind.u32:
          return _coerceUint32(data);
        case WasmCanonicalAbiPrimitiveKind.s64:
          if (data is! String) {
            throw const FormatException('Malformed canonical ABI s64 payload.');
          }
          return WasmI64.signed(BigInt.parse(data));
        case WasmCanonicalAbiPrimitiveKind.u64:
          if (data is! String) {
            throw const FormatException('Malformed canonical ABI u64 payload.');
          }
          return WasmI64.unsigned(BigInt.parse(data));
        case WasmCanonicalAbiPrimitiveKind.f32:
          return _coerceDouble(data);
        case WasmCanonicalAbiPrimitiveKind.f64:
          return _coerceDouble(data);
        case WasmCanonicalAbiPrimitiveKind.boolI32:
          return _coerceBoolI32(data) != 0;
        case WasmCanonicalAbiPrimitiveKind.stringUtf8:
          return _coerceString(data);
        case WasmCanonicalAbiPrimitiveKind.bytes:
          if (data is! String) {
            throw const FormatException(
              'Malformed canonical ABI bytes payload.',
            );
          }
          return Uint8List.fromList(base64Decode(data));
      }
    }

    if (type is WasmCanonicalAbiResourceType) {
      return WasmCanonicalAbiResourceHandle(_coerceResourceHandle(data));
    }

    if (type is WasmCanonicalAbiListType) {
      if (data is! List<Object?>) {
        throw const FormatException('Malformed canonical ABI list payload.');
      }
      return data
          .map((item) => _deserializeComposite(type.elementType, item))
          .toList(growable: false);
    }

    if (type is WasmCanonicalAbiRecordType) {
      if (data is! Map<String, Object?>) {
        throw const FormatException('Malformed canonical ABI record payload.');
      }
      final out = <String, Object?>{};
      for (final field in type.fields) {
        if (!data.containsKey(field.name)) {
          throw FormatException(
            'Malformed canonical ABI record payload: missing ${field.name}',
          );
        }
        out[field.name] = _deserializeComposite(field.type, data[field.name]);
      }
      return out;
    }

    if (type is WasmCanonicalAbiVariantType) {
      if (data is! Map<String, Object?>) {
        throw const FormatException('Malformed canonical ABI variant payload.');
      }
      final caseName = data['case'];
      if (caseName is! String) {
        throw const FormatException(
          'Malformed canonical ABI variant payload: case.',
        );
      }
      final selectedCase = type.caseByName(caseName);
      final payload = selectedCase.payloadType == null
          ? null
          : _deserializeComposite(selectedCase.payloadType!, data['payload']);
      return WasmCanonicalAbiVariantValue(caseName: caseName, payload: payload);
    }

    if (type is WasmCanonicalAbiResultType) {
      if (data is! Map<String, Object?>) {
        throw const FormatException('Malformed canonical ABI result payload.');
      }
      final kind = data['kind'];
      if (kind == 'error') {
        final payload = type.error == null
            ? null
            : _deserializeComposite(type.error!, data['payload']);
        return WasmCanonicalAbiResultValue.error(payload);
      }
      if (kind == 'ok') {
        final payload = type.ok == null
            ? null
            : _deserializeComposite(type.ok!, data['payload']);
        return WasmCanonicalAbiResultValue.ok(payload);
      }
      throw const FormatException('Malformed canonical ABI result kind.');
    }

    throw UnsupportedError('Unsupported canonical ABI composite type.');
  }

  static (int, int) _readInt32(List<Object> flatValues, int cursor) {
    if (cursor >= flatValues.length) {
      throw const FormatException('Canonical ABI flat value underflow.');
    }
    final raw = flatValues[cursor];
    if (raw is! num) {
      throw const FormatException('Canonical ABI expected integer flat value.');
    }
    return (raw.toInt().toSigned(32), cursor + 1);
  }

  static (int, int) _readUint32(List<Object> flatValues, int cursor) {
    final (value, nextCursor) = _readInt32(flatValues, cursor);
    return (value.toUnsigned(32), nextCursor);
  }

  static (BigInt, int) _readInt64(List<Object> flatValues, int cursor) {
    if (cursor >= flatValues.length) {
      throw const FormatException('Canonical ABI flat value underflow.');
    }
    final raw = flatValues[cursor];
    return (WasmI64.signed(raw), cursor + 1);
  }

  static (BigInt, int) _readUint64(List<Object> flatValues, int cursor) {
    if (cursor >= flatValues.length) {
      throw const FormatException('Canonical ABI flat value underflow.');
    }
    final raw = flatValues[cursor];
    return (WasmI64.unsigned(raw), cursor + 1);
  }

  static (double, int) _readDouble(List<Object> flatValues, int cursor) {
    if (cursor >= flatValues.length) {
      throw const FormatException('Canonical ABI flat value underflow.');
    }
    final raw = flatValues[cursor];
    if (raw is! num) {
      throw const FormatException('Canonical ABI expected numeric flat value.');
    }
    return (raw.toDouble(), cursor + 1);
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

  static String _coerceString(Object? value) {
    if (value is! String) {
      throw ArgumentError('Expected String for canonical ABI value.');
    }
    return value;
  }

  static Uint8List _coerceBytes(Object? value) {
    if (value is Uint8List) {
      return Uint8List.fromList(value);
    }
    if (value is List<int>) {
      return Uint8List.fromList(value);
    }
    throw ArgumentError('Expected bytes-compatible value for canonical ABI.');
  }

  static int _coerceResourceHandle(Object? value) {
    if (value is WasmCanonicalAbiResourceHandle) {
      return value.raw.toUnsigned(32);
    }
    if (value is num) {
      return value.toInt().toUnsigned(32);
    }
    throw ArgumentError('Expected resource-handle compatible value.');
  }

  static List<Object?> _coerceList(Object? value) {
    if (value is List<Object?>) {
      return value;
    }
    if (value is List) {
      return value.cast<Object?>();
    }
    throw ArgumentError('Expected list value for canonical ABI list type.');
  }

  static Map<String, Object?> _coerceRecord(Object? value) {
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map) {
      final out = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw ArgumentError('Canonical ABI record keys must be strings.');
        }
        out[key] = entry.value;
      }
      return out;
    }
    throw ArgumentError('Expected map value for canonical ABI record type.');
  }

  static WasmCanonicalAbiVariantValue _coerceVariantValue(Object? value) {
    if (value is WasmCanonicalAbiVariantValue) {
      return value;
    }
    if (value is Map) {
      final caseName = value['case'];
      if (caseName is! String) {
        throw ArgumentError('Variant value map must include string `case`.');
      }
      return WasmCanonicalAbiVariantValue(
        caseName: caseName,
        payload: value['payload'],
      );
    }
    throw ArgumentError(
      'Expected WasmCanonicalAbiVariantValue for variant canonical ABI type.',
    );
  }

  static WasmCanonicalAbiResultValue _coerceResultValue(Object? value) {
    if (value is WasmCanonicalAbiResultValue) {
      return value;
    }
    if (value is Map) {
      final hasOk = value.containsKey('ok');
      final hasError = value.containsKey('error');
      if (hasOk == hasError) {
        throw ArgumentError(
          'Result map must contain exactly one of `ok` or `error`.',
        );
      }
      if (hasOk) {
        return WasmCanonicalAbiResultValue.ok(value['ok']);
      }
      return WasmCanonicalAbiResultValue.error(value['error']);
    }
    throw ArgumentError(
      'Expected WasmCanonicalAbiResultValue for result canonical ABI type.',
    );
  }
}

final class _LiftedValue {
  const _LiftedValue(this.value, this.nextCursor);

  final Object? value;
  final int nextCursor;
}
