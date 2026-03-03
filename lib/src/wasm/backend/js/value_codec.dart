@JS()
library;

import 'dart:js_interop';

import '../../value.dart';

JSAny? encodeRef<T extends Value<T, V>, V extends Object?>(
  ValueKind<T, V> kind,
  V ref,
) => switch (kind) {
  ValueKind<ExternRef, Object?>() => _encodeExternRef(ref),
  ValueKind<FuncRef, Function>() => (ref as Function).toJS,
  ValueKind<Int32, int>() => (ref as int).toJS,
  ValueKind<Int64, BigInt>() => _jsBigInt((ref as BigInt).toString().toJS),
  ValueKind<Float32, double>() => (ref as double).toJS,
  ValueKind<Float64, double>() => (ref as double).toJS,
  ValueKind<Vector128, dynamic>() => throw UnsupportedError(
    'JS backend does not support v128 ref encoding yet.',
  ),
};

V decodeRef<T extends Value<T, V>, V extends Object?>(
  ValueKind<T, V> kind,
  JSAny? encoded,
) => switch (kind) {
  ValueKind<ExternRef, Object?>() => throw UnsupportedError(
    'JS backend does not support externref decode to Dart objects yet.',
  ),
  ValueKind<FuncRef, Function>() => throw UnsupportedError(
    'JS backend does not support funcref decode to Dart Function yet.',
  ),
  ValueKind<Int32, int>() => (encoded as JSNumber).toDartDouble.toInt() as V,
  ValueKind<Int64, BigInt>() => BigInt.parse(_jsString(encoded).toDart) as V,
  ValueKind<Float32, double>() => (encoded as JSNumber).toDartDouble as V,
  ValueKind<Float64, double>() => (encoded as JSNumber).toDartDouble as V,
  ValueKind<Vector128, dynamic>() => throw UnsupportedError(
    'JS backend does not support v128 ref decoding yet.',
  ),
};

JSAny? _encodeExternRef(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value.toJS;
  }
  if (value is BigInt) {
    return _jsBigInt(value.toString().toJS);
  }
  if (value is double) {
    return value.toJS;
  }
  if (value is bool) {
    return value.toJS;
  }
  if (value is String) {
    return value.toJS;
  }
  if (value is Function) {
    return value.toJS;
  }
  throw UnsupportedError(
    'Unsupported externref type for JS backend: ${value.runtimeType}',
  );
}

@JS('BigInt')
external JSAny _jsBigInt(JSString value);

@JS('String')
external JSString _jsString(JSAny? value);
