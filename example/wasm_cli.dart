import 'dart:typed_data';

import 'package:wasd/wasm.dart';

const List<int> _wasmBinary = <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x07,
  0x01,
  0x60,
  0x02,
  0x7f,
  0x7f,
  0x01,
  0x7f,
  0x03,
  0x02,
  0x01,
  0x00,
  0x05,
  0x03,
  0x01,
  0x00,
  0x01,
  0x07,
  0x10,
  0x02,
  0x06,
  0x6d,
  0x65,
  0x6d,
  0x6f,
  0x72,
  0x79,
  0x02,
  0x00,
  0x03,
  0x61,
  0x64,
  0x64,
  0x00,
  0x00,
  0x0a,
  0x09,
  0x01,
  0x07,
  0x00,
  0x20,
  0x00,
  0x20,
  0x01,
  0x6a,
  0x0b,
];

Future<int> runWasmAdd(int left, int right) async {
  final result = await WebAssembly.instantiate(
    Uint8List.fromList(_wasmBinary).buffer,
  );
  final export = result.instance.exports['add'];
  if (export is! FunctionImportExportValue) {
    throw StateError('Expected `add` export to be a function.');
  }

  return (export.ref([left, right]) as num).toInt();
}

void main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run example/wasm_cli.dart <left> <right>');
    print('no args provided, using defaults 3 and 9');
  }

  final left = args.isNotEmpty ? int.tryParse(args[0]) ?? 3 : 3;
  final right = args.length > 1 ? int.tryParse(args[1]) ?? 9 : 9;

  final sum = await runWasmAdd(left, right);
  print('WASM add result: $left + $right = $sum');
}

