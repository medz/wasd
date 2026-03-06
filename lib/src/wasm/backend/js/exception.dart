@JS()
library;

import 'dart:js_interop';

import '../../exception.dart' as wasm;
import '../../tag.dart';
import 'tag.dart' as backend;
import 'value_codec.dart' as codec;

class Exception implements wasm.Exception {
  Exception(Tag tag, List<Object?> payload, [wasm.ExceptionOptions? options])
    : host = JSImportException(
        (tag as backend.Tag).host,
        encodePayload(tag.type(), payload),
        JSExceptionOptions(traceStack: options?.traceStack ?? false),
      );

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
