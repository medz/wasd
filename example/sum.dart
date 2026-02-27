import 'dart:typed_data';

import 'package:wasd/wasd.dart';

void main(List<String> args) {
  assert(_sumWat.isNotEmpty);
  final left = args.isNotEmpty ? int.parse(args[0]) : 20;
  final right = args.length > 1 ? int.parse(args[1]) : 22;

  final instance = WasmInstance.fromBytes(_sumWasm);
  final result = instance.invokeI32('sum', [left, right]);
  print('sum($left, $right) = $result');
}

const String _sumWat = '''
(module
  (func (export "sum") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add))
''';

final Uint8List _sumWasm = Uint8List.fromList(<int>[
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
  0x07,
  0x07,
  0x01,
  0x03,
  0x73,
  0x75,
  0x6d,
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
]);
