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
      expect(component.imports, isEmpty);
      expect(component.exports, isEmpty);
      final section = component.sections.single;
      expect(section.id, 0);
      expect(section.offset, 8);
      expect(section.payloadOffset, 10);
      expect(section.payloadSize, 5);
      expect(section.customName, 'name');
    });

    test('decodes component imports', () {
      final component = WasmComponent.decode(_importComponentBytes());

      expect(component.imports, hasLength(1));
      expect(component.exports, isEmpty);
      final import = component.imports.single;
      expect(import.name, 'wasi:cli/run@0.3.0');
      expect(import.versionSuffix, isNull);
      expect(import.descriptor.kind, WasmComponentExternKind.function);
      expect(import.descriptor.typeIndex, 0);
    });

    test('decodes component names with version suffixes', () {
      final component = WasmComponent.decode(_versionedImportComponentBytes());

      final import = component.imports.single;
      expect(import.name, 'wasi');
      expect(import.versionSuffix, '0.3.0');
      expect(import.descriptor.kind, WasmComponentExternKind.function);
      expect(import.descriptor.typeIndex, 0);
    });

    test('decodes legacy component import name prefixes', () {
      final component = WasmComponent.decode(
        _legacyPrefixedImportComponentBytes(),
      );

      final import = component.imports.single;
      expect(import.name, 'a');
      expect(import.versionSuffix, isNull);
      expect(import.descriptor.kind, WasmComponentExternKind.function);
      expect(import.descriptor.typeIndex, 0);
    });

    test('decodes component exports without explicit descriptors', () {
      final component = WasmComponent.decode(_exportComponentBytes());

      expect(component.imports, hasLength(1));
      expect(component.exports, hasLength(1));
      final export = component.exports.single;
      expect(export.name, 'host-func');
      expect(export.versionSuffix, isNull);
      expect(export.sort.kind, WasmComponentSortKind.function);
      expect(export.sort.index, 0);
      expect(export.descriptor, isNull);
    });

    test('decodes component exports with explicit descriptors', () {
      final component = WasmComponent.decode(
        _exportWithDescriptorComponentBytes(),
      );

      final export = component.exports.single;
      expect(export.name, 'host-func');
      expect(export.sort.kind, WasmComponentSortKind.function);
      expect(export.sort.index, 0);
      expect(export.descriptor, isNotNull);
      expect(export.descriptor!.kind, WasmComponentExternKind.function);
      expect(export.descriptor!.typeIndex, 0);
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

Uint8List _importComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x05,
  0x01,
  0x40,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x17,
  0x01,
  0x00,
  0x12,
  0x77,
  0x61,
  0x73,
  0x69,
  0x3a,
  0x63,
  0x6c,
  0x69,
  0x2f,
  0x72,
  0x75,
  0x6e,
  0x40,
  0x30,
  0x2e,
  0x33,
  0x2e,
  0x30,
  0x01,
  0x00,
]);

Uint8List _versionedImportComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x0f,
  0x01,
  0x01,
  0x04,
  0x77,
  0x61,
  0x73,
  0x69,
  0x05,
  0x30,
  0x2e,
  0x33,
  0x2e,
  0x30,
  0x01,
  0x00,
]);

Uint8List _legacyPrefixedImportComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x0a,
      0x06,
      0x01,
      0x01,
      0x01,
      0x61,
      0x01,
      0x00,
    ]);

Uint8List _exportComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x05,
  0x01,
  0x40,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x0e,
  0x01,
  0x00,
  0x09,
  0x68,
  0x6f,
  0x73,
  0x74,
  0x2d,
  0x66,
  0x75,
  0x6e,
  0x63,
  0x01,
  0x00,
  0x0b,
  0x0f,
  0x01,
  0x00,
  0x09,
  0x68,
  0x6f,
  0x73,
  0x74,
  0x2d,
  0x66,
  0x75,
  0x6e,
  0x63,
  0x01,
  0x00,
  0x00,
]);

Uint8List _exportWithDescriptorComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x0a,
      0x0e,
      0x01,
      0x00,
      0x09,
      0x68,
      0x6f,
      0x73,
      0x74,
      0x2d,
      0x66,
      0x75,
      0x6e,
      0x63,
      0x01,
      0x00,
      0x0b,
      0x11,
      0x01,
      0x00,
      0x09,
      0x68,
      0x6f,
      0x73,
      0x74,
      0x2d,
      0x66,
      0x75,
      0x6e,
      0x63,
      0x01,
      0x00,
      0x01,
      0x01,
      0x00,
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
