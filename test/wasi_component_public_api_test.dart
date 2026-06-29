import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

void main() {
  group('public WASI component API', () {
    test('decodes components and prepares fixed Preview2/Preview3 hosts', () {
      final component = WasmComponent.decode(_emptyComponentBytes());
      final preview2 = WASIPreview2ComponentHost();
      final preview3 = WASIPreview3ComponentHost();

      expect(component.validate(), isEmpty);
      expect(preview2.profile, same(WASIComponentVersionProfile.preview2));
      expect(preview3.profile, same(WASIComponentVersionProfile.preview3));
      expect(preview2.prepareComponent(component).canBind, isTrue);
      expect(preview3.prepareComponent(component).canBind, isTrue);
    });

    test(
      'exposes WIT world ingestion through versioned Preview2/3 profiles',
      () {
        const source = '''
package wasi:cli@0.3.0;

interface run {
  run: async func() -> result;
}

interface stdout {
  write-via-stream: func(data: stream<u8>) -> future<result>;
}

world command {
  import run;
  include wasi:filesystem/imports@0.3.0;
  export stdout;
}
''';
        final document = WASIComponentWitDocument.parse(source);

        final preview2 = WASIPreview2ComponentHost().prepareWitWorld(
          document,
          worldName: 'command',
        );
        final preview3 = WASIPreview3ComponentHost().prepareWitWorld(
          document,
          worldName: 'command',
        );

        expect(preview2.canIngest, isFalse);
        expect(
          preview2.versionErrors.map((error) => error.targetName),
          containsAll(<String>[
            'run.run',
            'stdout.write-via-stream',
            'wasi:filesystem/imports@0.3.0',
          ]),
        );
        expect(preview3.canIngest, isTrue);
        expect(preview3.versionErrors, isEmpty);
        expect(preview3.canBindAdapters, isTrue);
        expect(preview3.bindingErrors, isEmpty);
        expect(preview3.world.name, 'command');
      },
    );

    test('binds standard Preview3 random imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world random-test {
  include wasi:random/imports@0.3.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview3ComponentHost();
      final program = host.bindWitWorld(document, worldName: 'random-test');
      final bytes =
          program.invokeImport('wasi:random/random@0.3.0.get-random-bytes', [
                BigInt.from(4),
              ])
              as WasmComponentValueData;

      expect(bytes.kind, WasmComponentValueDataKind.list);
      expect(bytes.items, hasLength(4));
      expect(
        host.standardImports,
        contains('wasi:random/insecure-seed@0.3.0.get-insecure-seed'),
      );
    });

    test('binds standard Preview3 clocks imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world clocks-test {
  include wasi:clocks/imports@0.3.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview3ComponentHost();
      final program = host.bindWitWorld(document, worldName: 'clocks-test');
      final now = program.invokeImport(
        'wasi:clocks/monotonic-clock@0.3.0.now',
        const [],
      );

      expect(now, isA<BigInt>());
      expect(
        host.standardImports,
        contains('wasi:clocks/system-clock@0.3.0.now'),
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
