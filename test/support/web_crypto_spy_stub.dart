class WebCryptoSpy {
  int get callCount => 0;

  void restore() {}
}

bool get canSpyOnWebCrypto => false;

WebCryptoSpy installWebCryptoGetRandomValuesSpy() {
  throw UnsupportedError('Web Crypto spy is only available on browser JS.');
}
