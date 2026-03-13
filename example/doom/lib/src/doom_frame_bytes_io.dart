import 'dart:isolate';
import 'dart:typed_data';

import 'doom_runtime.dart';

Uint8List? frameMessageBytesAsUint8List(Object? value) {
  if (value is TransferableTypedData) {
    return value.materialize().asUint8List();
  }
  return messageBytesAsUint8List(value);
}
