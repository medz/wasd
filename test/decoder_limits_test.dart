import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasd.dart';

void main() {
  test('rejects varuint32 overflow in table limits', () {
    const moduleHeader = <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
    const tableSection = <int>[
      0x04, // table section
      0x08, // section size
      0x01, // table count
      0x70, // funcref
      0x00, // limits: min only
      0x82, 0x80, 0x80, 0x80, 0x10, // invalid varuint32 (> u32::MAX)
    ];

    final bytes = Uint8List.fromList(<int>[...moduleHeader, ...tableSection]);
    expect(() => WasmModule.decode(bytes), throwsFormatException);
  });

  test('rejects malformed table limits flags encoded as leb128', () {
    const moduleHeader = <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
    const tableSection = <int>[
      0x04, // table section
      0x06, // section size
      0x01, // table count
      0x70, // funcref
      0x81, 0x00, // malformed limits flags encoding for 0x01
      0x00, 0x00, // min/max payload
    ];

    final bytes = Uint8List.fromList(<int>[...moduleHeader, ...tableSection]);
    expect(() => WasmModule.decode(bytes), throwsA(isA<UnsupportedError>()));
  });
}
