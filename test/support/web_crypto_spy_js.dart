import 'dart:js_interop';
import 'dart:js_interop_unsafe';

class WebCryptoSpy {
  WebCryptoSpy._(this._restore);

  final void Function() _restore;
  int _callCount = 0;

  int get callCount => _callCount;

  void restore() => _restore();
}

bool get canSpyOnWebCrypto {
  final process = globalContext.getProperty<JSAny?>('process'.toJS);
  if (process != null) {
    final versions = (process as JSObject).getProperty<JSAny?>('versions'.toJS);
    if (versions != null &&
        (versions as JSObject).getProperty<JSAny?>('node'.toJS) != null) {
      return false;
    }
  }
  return globalContext.getProperty<JSAny?>('crypto'.toJS) != null;
}

WebCryptoSpy installWebCryptoGetRandomValuesSpy() {
  final crypto = globalContext.getProperty<JSAny?>('crypto'.toJS);
  if (crypto == null) {
    throw StateError('Web Crypto is unavailable in this runtime.');
  }

  final cryptoObject = crypto as JSObject;
  final originalGetRandomValues = cryptoObject.getProperty<JSFunction>(
    'getRandomValues'.toJS,
  );
  late final WebCryptoSpy spy;

  JSAny? wrapper(JSAny? array) {
    spy._callCount++;
    return (originalGetRandomValues as JSObject).callMethodVarArgs<JSAny?>(
      'call'.toJS,
      <JSAny?>[cryptoObject, array],
    );
  }

  cryptoObject['getRandomValues'] = wrapper.toJS;
  spy = WebCryptoSpy._(() {
    cryptoObject['getRandomValues'] = originalGetRandomValues;
  });
  return spy;
}
