@JS()
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

const int _maxGetRandomValuesLength = 65536;

/// Returns cryptographically secure random bytes on JS runtimes.
Uint8List secureRandomBytes(int length) {
  final bytes = Uint8List(length);
  final crypto = _requireWebCrypto();
  var offset = 0;
  while (offset < length) {
    final chunkLength = math.min(length - offset, _maxGetRandomValuesLength);
    final chunk = Uint8List.sublistView(bytes, offset, offset + chunkLength);
    crypto.callMethodVarArgs<JSAny?>('getRandomValues'.toJS, [chunk.toJS]);
    offset += chunkLength;
  }
  return bytes;
}

@JS('globalThis')
external JSObject get _globalContext;

@JS('require')
external JSAny? _jsRequire(JSString module);

JSObject _requireWebCrypto() {
  if (_isNodeJs()) {
    final crypto = _requireNodeWebCrypto();
    if (crypto != null) {
      return crypto;
    }
  }

  final crypto = _globalContext.getProperty<JSObject?>('crypto'.toJS);
  if (crypto != null) {
    return crypto;
  }

  final nodeCrypto = _requireNodeWebCrypto();
  if (nodeCrypto != null) {
    return nodeCrypto;
  }

  throw UnsupportedError('Web Crypto is unavailable in this runtime.');
}

bool _isNodeJs() {
  final process = _globalContext.getProperty<JSAny?>('process'.toJS);
  if (process == null) {
    return false;
  }
  final versions = (process as JSObject).getProperty<JSAny?>('versions'.toJS);
  if (versions == null) {
    return false;
  }
  return (versions as JSObject).getProperty<JSAny?>('node'.toJS) != null;
}

JSObject? _requireNodeWebCrypto() {
  final require = _globalContext.getProperty<JSAny?>('require'.toJS);
  if (require == null) {
    return null;
  }
  final cryptoModule = _jsRequire('node:crypto'.toJS);
  if (cryptoModule case final JSObject module) {
    return module.getProperty<JSObject?>('webcrypto'.toJS);
  }
  return null;
}
