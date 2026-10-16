@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/imports.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart';

void main() {
  for (final captureAsync in [false, true]) {
    for (final rethrowAsync in [false, true]) {
      test(
        'exnref crosses instances and modes $captureAsync/$rethrowAsync',
        () async {
          const features = WasmFeatureSet(exceptionHandling: true);
          final bytes = File(
            'test/fixtures/host_tags/exception_refs.wasm',
          ).readAsBytesSync();
          final tagProvider = WasmInstance.fromBytes(
            File(
              'test/fixtures/import_keys/tag_provider.wasm',
            ).readAsBytesSync(),
            features: features,
          );
          final tag = tagProvider.exportedTagImport('first');
          WasmInstance instance() => WasmInstance.fromBytes(
            bytes,
            features: features,
            imports: WasmImports(
              functions: {WasmImports.key('host', 'tick'): (_) => null},
              tags: {WasmImports.key('host', 'tag'): tag},
            ),
          );
          final capture = instance();
          final receiver = instance();
          final reference = captureAsync
              ? await capture.invokeAsyncForced('capture', [73])
              : capture.invoke('capture', [73]);
          final payload = rethrowAsync
              ? await receiver.invokeAsyncForced('rethrow', [reference])
              : receiver.invoke('rethrow', [reference]);
          expect(payload, 73);
        },
      );
    }
  }
}
