import 'dart:typed_data';

String specReadText(String path) {
  throw UnsupportedError(
    'spec player JS bridge is unavailable on this runtime (readText: $path)',
  );
}

Uint8List specReadBinary(String path) {
  throw UnsupportedError(
    'spec player JS bridge is unavailable on this runtime (readBinary: $path)',
  );
}

void specSetResult(String payloadJson) {
  throw UnsupportedError(
    'spec player JS bridge is unavailable on this runtime (setResult)',
  );
}

void specSetError(String payloadJson) {
  throw UnsupportedError(
    'spec player JS bridge is unavailable on this runtime (setError)',
  );
}
