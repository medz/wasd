@JS()
library;

import 'dart:js_interop';

import '../../value.dart';

JSAny? encodeAnyRef(ValueKind kind, Object? ref) => switch (kind) {
  ValueKind<ExternRef, Object?>() => encodeExternRef(ref),
  ValueKind<FuncRef, Function>() => switch (ref) {
    null => null,
    final Function fn => fn.toJS,
    _ => throw ArgumentError.value(
      ref,
      'ref',
      'Expected Function for funcref encoding.',
    ),
  },
  ValueKind<Int32, int>() => (ref as int).toJS,
  ValueKind<Int64, BigInt>() => jsBigInt((ref as BigInt).toString().toJS),
  ValueKind<Float32, double>() => (ref as double).toJS,
  ValueKind<Float64, double>() => (ref as double).toJS,
  ValueKind<Vector128, dynamic>() => throw UnsupportedError(
    'JS backend does not support v128 ref encoding yet.',
  ),
};

Object? decodeAnyRef(ValueKind kind, JSAny? encoded) => switch (kind) {
  ValueKind<ExternRef, Object?>() => encoded?.dartify(),
  ValueKind<FuncRef, Function>() => throw UnsupportedError(
    'JS backend does not support funcref decode to Dart Function yet.',
  ),
  ValueKind<Int32, int>() => (encoded as JSNumber).toDartDouble.toInt(),
  ValueKind<Int64, BigInt>() => BigInt.parse(jsString(encoded).toDart),
  ValueKind<Float32, double>() => (encoded as JSNumber).toDartDouble,
  ValueKind<Float64, double>() => (encoded as JSNumber).toDartDouble,
  ValueKind<Vector128, dynamic>() => throw UnsupportedError(
    'JS backend does not support v128 ref decoding yet.',
  ),
};

JSAny? encodeRef<T extends Value<T, V>, V extends Object?>(
  ValueKind<T, V> kind,
  V ref,
) => encodeAnyRef(kind, ref);

V decodeRef<T extends Value<T, V>, V extends Object?>(
  ValueKind<T, V> kind,
  JSAny? encoded,
) => decodeAnyRef(kind, encoded) as V;

JSAny? encodeExternRef(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value.toJS;
  }
  if (value is BigInt) {
    return jsBigInt(value.toString().toJS);
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
external JSAny jsBigInt(JSString value);

@JS('String')
external JSString jsString(JSAny? value);
