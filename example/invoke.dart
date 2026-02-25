import 'dart:typed_data';

import 'package:wasd/wasd.dart';

void main() {
  final wasmBytes = Uint8List.fromList(const <int>[
    // wasm header
    0x00, 0x61, 0x73, 0x6d,
    0x01, 0x00, 0x00, 0x00,

    // type section
    0x01, 0x07,
    0x01, // one type
    0x60, // functype
    0x02, 0x7f, 0x7f, // (i32, i32)
    0x01, 0x7f, // -> i32
    // function section
    0x03, 0x02,
    0x01, // one function
    0x00, // type index 0
    // export section
    0x07, 0x07,
    0x01, // one export
    0x03, 0x61, 0x64, 0x64, // "add"
    0x00, // function export
    0x00, // function index 0
    // code section
    0x0a, 0x09,
    0x01, // one body
    0x07, // body size
    0x00, // no locals
    0x20, 0x00, // local.get 0
    0x20, 0x01, // local.get 1
    0x6a, // i32.add
    0x0b, // end
  ]);

  final instance = WasmInstance.fromBytes(wasmBytes);
  final result = instance.invokeI32('add', [20, 22]);

  print('add(20, 22) = $result');
}
