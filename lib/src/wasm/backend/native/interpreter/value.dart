// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import 'int64.dart';
import 'module.dart';

final class WasmF32Bits {
  const WasmF32Bits(this.bits);

  final int bits;
}

final class WasmF64Bits {
  const WasmF64Bits(this.bits);

  final Object bits;
}

final class WasmValue {
  const WasmValue._(this.type, this.raw);

  final WasmValueType type;
  final Object raw;
  static const int _i32CacheMin = -512;
  static const int _i32CacheMax = 4096;
  static final List<WasmValue> _i32Cache = List<WasmValue>.generate(
    _i32CacheMax - _i32CacheMin + 1,
    (index) =>
        WasmValue._(WasmValueType.i32, (_i32CacheMin + index).toSigned(32)),
    growable: false,
  );
  static const WasmValue zeroI32 = WasmValue._(WasmValueType.i32, 0);
  static const WasmValue oneI32 = WasmValue._(WasmValueType.i32, 1);
  static const WasmValue zeroF32 = WasmValue._(WasmValueType.f32, 0);
  static final WasmValue zeroF64 = WasmValue._(WasmValueType.f64, BigInt.zero);

  factory WasmValue.i32(int value) {
    final normalized = value.toSigned(32);
    if (normalized >= _i32CacheMin && normalized <= _i32CacheMax) {
      return _i32Cache[normalized - _i32CacheMin];
    }
    return WasmValue._(WasmValueType.i32, normalized);
  }

  factory WasmValue.i64(Object value) {
    return WasmValue._(WasmValueType.i64, WasmI64.signed(value));
  }

  factory WasmValue.f32(double value) {
    return WasmValue._(WasmValueType.f32, toF32Bits(value));
  }

  factory WasmValue.f64(double value) {
    return WasmValue._(WasmValueType.f64, toF64Bits(value));
  }

  factory WasmValue.f32Bits(int bits) {
    return WasmValue._(WasmValueType.f32, bits.toUnsigned(32));
  }

  factory WasmValue.f64Bits(Object bits) {
    return WasmValue._(WasmValueType.f64, WasmI64.unsigned(bits));
  }

  factory WasmValue.zeroForType(WasmValueType type) {
    switch (type) {
      case WasmValueType.i32:
        return zeroI32;
      case WasmValueType.i64:
        return WasmValue.i64(0);
      case WasmValueType.f32:
        return zeroF32;
      case WasmValueType.f64:
        return zeroF64;
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
        if (value is! int && value is! BigInt && value is! String) {
          throw StateError(
            'Expected i64 value (int/BigInt/string), got `$value`.',
          );
        }
        if (value == null) {
          throw StateError('Expected non-null i64 value.');
        }
        return WasmValue.i64(value);
      case WasmValueType.f32:
        if (value is WasmF32Bits) {
          return WasmValue.f32Bits(value.bits);
        }
        if (value is! num) {
          throw StateError(
            'Expected f32 value (num/$WasmF32Bits), got `$value`.',
          );
        }
        return WasmValue.f32(value.toDouble());
      case WasmValueType.f64:
        if (value is WasmF64Bits) {
          return WasmValue.f64Bits(value.bits);
        }
        if (value is! num) {
          throw StateError(
            'Expected f64 value (num/$WasmF64Bits), got `$value`.',
          );
        }
        return WasmValue.f64(value.toDouble());
    }
  }

  int asI32() {
    _expectType(WasmValueType.i32);
    return raw as int;
  }

  BigInt asI64() {
    _expectType(WasmValueType.i64);
    return WasmI64.signed(raw);
  }

  double asF32() {
    _expectType(WasmValueType.f32);
    return fromF32Bits(raw as int);
  }

  int asF32Bits() {
    _expectType(WasmValueType.f32);
    return raw as int;
  }

  double asF64() {
    _expectType(WasmValueType.f64);
    return fromF64Bits(raw);
  }

  BigInt asF64Bits() {
    _expectType(WasmValueType.f64);
    return WasmI64.unsigned(raw);
  }

  Object toExternal() {
    switch (type) {
      case WasmValueType.i32:
        return raw as int;
      case WasmValueType.i64:
        final value = WasmI64.signed(raw);
        return WasmI64.fitsInInt(value) ? value.toInt() : value;
      case WasmValueType.f32:
      case WasmValueType.f64:
        return type == WasmValueType.f32 ? asF32() : asF64();
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

  static double fromF64Bits(Object bits) {
    final normalized = WasmI64.unsigned(bits);
    final data = ByteData(8)
      ..setUint32(0, WasmI64.lowU32(normalized), Endian.little)
      ..setUint32(4, WasmI64.highU32(normalized), Endian.little);
    return data.getFloat64(0, Endian.little);
  }

  static int toF32Bits(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return data.getUint32(0, Endian.little);
  }

  static BigInt toF64Bits(double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    final low = data.getUint32(0, Endian.little);
    final high = data.getUint32(4, Endian.little);
    return WasmI64.fromU32PairUnsigned(low: low, high: high);
  }
}
