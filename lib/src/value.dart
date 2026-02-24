import 'dart:typed_data';

import 'module.dart';

final class WasmValue {
  const WasmValue._(this.type, this.raw);

  final WasmValueType type;
  final Object raw;

  factory WasmValue.i32(int value) {
    return WasmValue._(WasmValueType.i32, value.toSigned(32));
  }

  factory WasmValue.i64(int value) {
    return WasmValue._(WasmValueType.i64, value.toSigned(64));
  }

  factory WasmValue.f32(double value) {
    return WasmValue._(WasmValueType.f32, _toF32(value));
  }

  factory WasmValue.f64(double value) {
    return WasmValue._(WasmValueType.f64, value);
  }

  factory WasmValue.zeroForType(WasmValueType type) {
    switch (type) {
      case WasmValueType.i32:
        return WasmValue.i32(0);
      case WasmValueType.i64:
        return WasmValue.i64(0);
      case WasmValueType.f32:
        return WasmValue.f32(0.0);
      case WasmValueType.f64:
        return WasmValue.f64(0.0);
    }
  }

  factory WasmValue.fromExternal(WasmValueType type, Object? value) {
    switch (type) {
      case WasmValueType.i32:
        if (value is! int) {
          throw StateError('Expected i32 value (int), got `$value`.');
        }
        return WasmValue.i32(value);
      case WasmValueType.i64:
        if (value is! int) {
          throw StateError('Expected i64 value (int), got `$value`.');
        }
        return WasmValue.i64(value);
      case WasmValueType.f32:
        if (value is! num) {
          throw StateError('Expected f32 value (num), got `$value`.');
        }
        return WasmValue.f32(value.toDouble());
      case WasmValueType.f64:
        if (value is! num) {
          throw StateError('Expected f64 value (num), got `$value`.');
        }
        return WasmValue.f64(value.toDouble());
    }
  }

  int asI32() {
    _expectType(WasmValueType.i32);
    return (raw as int).toSigned(32);
  }

  int asI64() {
    _expectType(WasmValueType.i64);
    return (raw as int).toSigned(64);
  }

  double asF32() {
    _expectType(WasmValueType.f32);
    return raw as double;
  }

  double asF64() {
    _expectType(WasmValueType.f64);
    return raw as double;
  }

  Object toExternal() {
    switch (type) {
      case WasmValueType.i32:
      case WasmValueType.i64:
        return raw as int;
      case WasmValueType.f32:
      case WasmValueType.f64:
        return raw as double;
    }
  }

  WasmValue castTo(WasmValueType targetType) {
    if (type == targetType) {
      return this;
    }

    throw StateError('Type mismatch: expected $targetType but got $type.');
  }

  void _expectType(WasmValueType expected) {
    if (type != expected) {
      throw StateError('Expected $expected but got $type.');
    }
  }

  static List<WasmValue> decodeResults(
    List<WasmValueType> resultTypes,
    Object? externalResult,
  ) {
    if (resultTypes.isEmpty) {
      return const [];
    }

    if (resultTypes.length == 1) {
      return [WasmValue.fromExternal(resultTypes[0], externalResult)];
    }

    if (externalResult is! List) {
      throw StateError(
        'Expected list of ${resultTypes.length} values for multi-result host call.',
      );
    }

    if (externalResult.length != resultTypes.length) {
      throw StateError(
        'Multi-result length mismatch. expected=${resultTypes.length} '
        'actual=${externalResult.length}.',
      );
    }

    final values = <WasmValue>[];
    for (var i = 0; i < resultTypes.length; i++) {
      values.add(WasmValue.fromExternal(resultTypes[i], externalResult[i]));
    }
    return values;
  }

  static List<Object?> encodeResults(List<WasmValue> values) {
    return values.map((value) => value.toExternal()).toList(growable: false);
  }

  static double fromF32Bits(int bits) {
    final data = ByteData(4)..setUint32(0, bits.toUnsigned(32), Endian.little);
    return data.getFloat32(0, Endian.little);
  }

  static double fromF64Bits(int bits) {
    final data = ByteData(8)..setUint64(0, bits.toUnsigned(64), Endian.little);
    return data.getFloat64(0, Endian.little);
  }

  static int toF32Bits(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return data.getUint32(0, Endian.little);
  }

  static int toF64Bits(double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    return data.getUint64(0, Endian.little);
  }

  static double _toF32(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return data.getFloat32(0, Endian.little);
  }
}
