import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';

void main() {
  group('WasmComponent.decode', () {
    test('decodes an empty component', () {
      final component = WasmComponent.decode(_emptyComponentBytes());

      expect(component.sections, isEmpty);
    });

    test('decodes component section framing and custom section names', () {
      final component = WasmComponent.decode(_customSectionComponentBytes());

      expect(component.sections, hasLength(1));
      final section = component.sections.single;
      expect(section.id, 0);
      expect(section.offset, 8);
      expect(section.payloadOffset, 10);
      expect(section.payloadSize, 5);
      expect(section.customName, 'name');
    });

    test('rejects component decoding when the feature is disabled', () {
      expect(
        () => WasmComponent.decode(
          _emptyComponentBytes(),
          features: const WasmFeatureSet(),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('rejects core module binaries as components', () {
      expect(
        () => WasmComponent.decode(_emptyCoreModuleBytes()),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects truncated component sections', () {
      expect(
        () => WasmComponent.decode(_truncatedSectionComponentBytes()),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

Uint8List _emptyComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
]);

Uint8List _customSectionComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x04,
  0x6e,
  0x61,
  0x6d,
  0x65,
]);

Uint8List _truncatedSectionComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x04,
  0x6e,
]);

Uint8List _emptyCoreModuleBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
]);
