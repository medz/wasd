import 'dart:convert';
import 'dart:io';
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
      final stdout = BytesBuilder();
      final stderr = BytesBuilder();
      final wasi = WASI(
        args: const ['demo'],
        env: const {'FOO': 'bar'},
        stdoutSink: stdout.add,
        stderrSink: stderr.add,
      );
      final runtime = await WebAssembly.instantiate(
        _wasiStartModuleBytes.buffer,
        wasi.imports,
      );
      expect(wasi.start(runtime.instance), 42);
      expect(stdout.toBytes(), isEmpty);
      expect(stderr.toBytes(), isEmpty);
    });

    test('Preview2 command snippet executes a stable component', () async {
      final bytes = File(
        'test/fixtures/wasi_preview2/wasmtime_v47_0_3_hello.component.wasm',
      ).readAsBytesSync();
      final component = WasmComponent.decode(bytes);
      final host = WASI.preview2(args: const ['app.component.wasm']);

      final result = await WASIPreview2CommandRunner(host).run(component);

      expect(result.exitCode, 0);
      expect(utf8.decode(host.cliHost.stdoutBytes), 'Hello, world!\n');
    });

    test('Preview2 proxy snippet executes a stable component', () async {
      final proxyComponent = WasmComponent.decode(
        File(
          'test/fixtures/wasi_preview2/'
          'wasi_http_0_2_12_static_response.component.wasm',
        ).readAsBytesSync(),
      );
      final proxyHost = WASI.preview2();
      final request = WASIPreview2HttpIncomingRequest(
        method: const WASIPreview2HttpMethod.standard('get'),
        headers: WASIPreview2HttpFields(),
        pathWithQuery: '/',
        scheme: const WASIPreview2HttpScheme.standard('HTTP'),
        authority: 'example.test',
      );

      final response = await WASIPreview2ProxyRunner(
        proxyHost,
      ).handle(proxyComponent, request);

      expect(response.response?.isOk, isTrue);
      expect(response.response?.value?.statusCode, 200);
    });
  });
}
