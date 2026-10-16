@JS()
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'errors.dart' as js_errors;

// dart2wasm catches Dart/JSTag exceptions, but not foreign Wasm exception tags.
// The optional static JS adapter catches those before they enter the Dart module.
const isDart2Wasm = !bool.fromEnvironment('dart.library.js');

_ExceptionBridge? get _bridge => isDart2Wasm
    ? globalContext.getProperty<_ExceptionBridge?>(
        JSSymbol.forKey('wasd.wasm.exceptionBridge'),
      )
    : null;

bool get isInstalled => _bridge != null;

JSAny? invoke(JSFunction function, List<JSAny?> args) {
  final bridge = _bridge;
  if (bridge == null) {
    return (function as JSObject).callMethodVarArgs<JSAny?>('call'.toJS, [
      null,
      ...args,
    ]);
  }
  return _unwrap(bridge.invoke(function, args.toJS));
}

JSObject construct(JSFunction constructor, List<JSAny?> args) =>
    _unwrap(_bridge!.construct(constructor, args.toJS)) as JSObject;

JSAny? _unwrap(_CallResult result) {
  if (result.ok) return result.value;
  final error = result.error;
  if (error == null) throw StateError('JavaScript threw a null value.');
  js_errors.translateJsError(error, StackTrace.current);
}

extension type _ExceptionBridge._(JSObject _) implements JSObject {
  external _CallResult invoke(JSFunction function, JSArray<JSAny?> args);
  external _CallResult construct(JSFunction constructor, JSArray<JSAny?> args);
}

extension type _CallResult._(JSObject _) implements JSObject {
  external bool get ok;
  external JSAny? get value;
  external JSAny? get error;
}
