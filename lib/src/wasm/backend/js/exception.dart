@JS()
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../../exception.dart' as wasm;
import '../../tag.dart';
import 'instance.dart' as js_instance;
import 'module.dart' as js_module;
import 'tag.dart' as backend;
import 'value_codec.dart' as codec;

class Exception implements wasm.Exception {
  Exception(Tag tag, List<Object?> payload, [wasm.ExceptionOptions? options])
    : host = JSImportException(
        (tag as backend.Tag).host,
        encodePayload(tag.type(), payload),
        JSExceptionOptions(traceStack: options?.traceStack ?? false),
      ) {
    _wrappers.set(host, toJSBox);
  }

  factory Exception.fromHost(JSImportException host) {
    final existing = _wrappers.get(host);
    if (existing != null) return existing.toDart as Exception;
    final exception = Exception._(host);
    _wrappers.set(host, exception.toJSBox);
    return exception;
  }

  Exception._(this.host);

  static final _wrappers = _ExceptionWrappers();

  final JSImportException host;

  @override
  bool isTag(Tag tag) => host.isTag((tag as backend.Tag).host);

  @override
  Object? getArg(Tag tag, int index) {
    final raw = host.getArg((tag as backend.Tag).host, index);
    final kind = tag.type().parameters[index];
    return codec.decodeAnyRef(kind, raw);
  }
}

/// Throws the original JS exception without Dart's exception wrapper.
Never throwToHost(Exception error) {
  throwValueToHost(error.host);
}

bool get supportsHostThrow => _jsTag != null;

Never throwValueToHost(JSAny value) {
  _throwJsValue.callAsFunction(null, value);
  throw StateError('The WebAssembly exception thrower returned.');
}

// (module
//   (import "e" "t" (tag (param externref)))
//   (func (export "f") (param externref) local.get 0 throw 0))
// The JS API throws a JSTag payload unchanged. Calling this tiny Wasm function
// avoids both Dart's JS Error wrapper and a CSP-sensitive Function constructor.
final JSFunction _throwJsValue = () {
  final jsTag = _jsTag;
  if (jsTag == null) {
    throw UnsupportedError(
      'Throwing public exceptions from a host callback requires '
      'WebAssembly.JSTag.',
    );
  }
  final bytes = Uint8List.fromList(const [
    ...[0, 97, 115, 109, 1, 0, 0, 0],
    ...[1, 5, 1, 96, 1, 111, 0],
    ...[2, 8, 1, 1, 101, 1, 116, 4, 0, 0],
    ...[3, 2, 1, 0],
    ...[7, 5, 1, 1, 102, 0, 0],
    ...[10, 8, 1, 6, 0, 32, 0, 8, 0, 11],
  ]);
  final imports = JSObject();
  final moduleImports = JSObject();
  moduleImports['t'] = jsTag;
  imports['e'] = moduleImports;
  return js_instance.JSImportInstance(
        js_module.JSImportModule(bytes.buffer.toJS),
        imports,
      ).exports['f']
      as JSFunction;
}();

@JS('WebAssembly.JSTag')
external backend.JSTag? get _jsTag;

@JS('WeakMap')
extension type _ExceptionWrappers._(JSObject _) implements JSObject {
  external factory _ExceptionWrappers();

  external JSBoxedDartObject? get(JSImportException exception);
  external void set(JSImportException exception, JSBoxedDartObject wrapper);
}

JSArray<JSAny?> encodePayload(TagDescriptor tagType, List<Object?> payload) {
  final parameterCount = tagType.parameters.length;
  if (payload.length != parameterCount) {
    throw ArgumentError.value(
      payload,
      'payload',
      'Expected $parameterCount values for tag payload, got ${payload.length}.',
    );
  }
  final encoded = List<JSAny?>.generate(
    parameterCount,
    (index) => codec.encodeAnyRef(tagType.parameters[index], payload[index]),
    growable: false,
  );
  return encoded.toJS;
}

extension type JSExceptionOptions._(JSObject _) implements JSObject {
  external factory JSExceptionOptions({bool? traceStack});
}

@JS('WebAssembly.Exception')
extension type JSImportException._(JSObject _) implements JSObject {
  external factory JSImportException(
    backend.JSTag tag,
    JSArray<JSAny?> values, [
    JSExceptionOptions? options,
  ]);

  @JS('is')
  external bool isTag(backend.JSTag tag);

  external JSAny? getArg(backend.JSTag tag, int index);
}
