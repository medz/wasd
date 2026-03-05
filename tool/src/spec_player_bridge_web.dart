import 'dart:js_interop';
import 'dart:typed_data';

@JS('globalThis.wasdSpecReadText')
external JSString _readText(JSString path);

@JS('globalThis.wasdSpecReadBinary')
external JSUint8Array _readBinary(JSString path);

@JS('globalThis.wasdSpecSetResult')
external void _setResult(JSString payloadJson);

@JS('globalThis.wasdSpecSetError')
external void _setError(JSString payloadJson);

String specReadText(String path) => _readText(path.toJS).toDart;

Uint8List specReadBinary(String path) => _readBinary(path.toJS).toDart;

void specSetResult(String payloadJson) => _setResult(payloadJson.toJS);

void specSetError(String payloadJson) => _setError(payloadJson.toJS);
