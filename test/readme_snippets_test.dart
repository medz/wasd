import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasd.dart';

import 'support/wasm_fixtures.dart';

final _quickStartModuleBytes = simpleAddModuleBytes();

final _hostImportModuleBytes = Uint8List.fromList([
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
  0x02,
  0x0c,
  0x01,
  0x03,
  0x65,
  0x6e,
  0x76,
  0x04,
  0x70,
  0x6c,
  0x75,
  0x73,
  0x00,
  0x00,
  0x03,
  0x02,
  0x01,
  0x00,
  0x07,
  0x0c,
  0x01,
  0x08,
  0x75,
  0x73,
  0x65,
  0x5f,
  0x70,
  0x6c,
  0x75,
  0x73,
  0x00,
  0x01,
  0x0a,
  0x0a,
  0x01,
  0x08,
  0x00,
  0x20,
  0x00,
  0x20,
  0x01,
  0x10,
  0x00,
  0x0b,
]);

final _wasiStartModuleBytes = wasiStartModuleBytes();

void main() {
  group('README snippets', () {
    test('quick start style instantiate and call export', () async {
      final runtime = await WebAssembly.instantiate(
        _quickStartModuleBytes.buffer,
      );
      final addExport = runtime.instance.exports['add'];
      expect(addExport, isA<FunctionImportExportValue>());
      final result =
          ((addExport as FunctionImportExportValue).ref([20, 22]) as num)
              .toInt();
      expect(result, 42);
    });

    test(
      'host imports style map works with ImportExportKind.function',
      () async {
        final imports = <String, ModuleImports>{
          'env': {
            'plus': ImportExportKind.function((args) {
              final a = (args[0] as num).toInt();
              final b = (args[1] as num).toInt();
              return a + b;
            }),
          },
        };
        final runtime = await WebAssembly.instantiate(
          _hostImportModuleBytes.buffer,
          imports,
        );
        final usePlus = runtime.instance.exports['use_plus'];
        expect(usePlus, isA<FunctionImportExportValue>());
        expect((usePlus as FunctionImportExportValue).ref([4, 5]), 9);
      },
    );

    test('module metadata snippet compiles and lists descriptors', () async {
      final module = await WebAssembly.compile(_hostImportModuleBytes.buffer);
      final imports = Module.imports(module);
      final exports = Module.exports(module);

      expect(imports, hasLength(1));
      expect(imports.single.module, 'env');
      expect(imports.single.name, 'plus');
      expect(imports.single.kind, ImportExportKind.function);

      expect(exports, hasLength(1));
      expect(exports.single.name, 'use_plus');
      expect(exports.single.kind, ImportExportKind.function);
    });

    test('wasi snippet style start returns exit code', () async {
      final wasi = WASI(args: const ['demo'], env: const {'FOO': 'bar'});
      final runtime = await WebAssembly.instantiate(
        _wasiStartModuleBytes.buffer,
        wasi.imports,
      );
      expect(wasi.start(runtime.instance), 42);
    });
  });
}
