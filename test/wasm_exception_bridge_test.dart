@TestOn('vm')
library;

import 'dart:io';
import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/imports.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart';
import 'package:wasd/wasm.dart' as wasm;

import 'support/host_tag_fixtures.dart';

int _referencePeerCount(wasm.Instance instance) {
  final mirror = reflect(instance);
  final library = mirror.type.owner as LibraryMirror;
  final references = mirror.getField(
    MirrorSystem.getSymbol('_references', library),
  );
  final referenceLibrary = references.type.owner as LibraryMirror;
  return (references
              .getField(MirrorSystem.getSymbol('_peers', referenceLibrary))
              .reflectee
          as Set)
      .length;
}

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

  for (final asyncHost in [false, true]) {
    for (final caughtInGuest in [false, true]) {
      test(
        'numeric host exceptions do not retain stores $asyncHost/$caughtInGuest',
        () async {
          final tag = wasm.Tag(
            const wasm.TagDescriptor(parameters: [wasm.ValueKind.i32]),
          );
          wasm.Exception? latest;
          Never fail(List<Object?> _) {
            latest = wasm.Exception(tag, [42]);
            throw latest!;
          }

          final instance = wasm.Instance(
            wasm.Module(
              hostTagFixture('i32').buffer,
              features: {wasm.CoreFeature.exceptionHandling},
            ),
            {
              'host': {
                'tick': wasm.ImportExportKind.function(
                  asyncHost ? (args) async => fail(args) : fail,
                ),
                'tag': wasm.ImportExportKind.tag(
                  caughtInGuest
                      ? tag
                      : wasm.Tag(
                          const wasm.TagDescriptor(
                            parameters: [wasm.ValueKind.i32],
                          ),
                        ),
                ),
              },
            },
          );
          final run =
              (instance.exports['catch']! as wasm.FunctionImportExportValue)
                  .ref;
          final before = _referencePeerCount(instance);
          for (var i = 0; i < 128; i++) {
            if (caughtInGuest) {
              expect(await Future<Object?>.sync(() => run([0])), 42);
            } else {
              await expectLater(
                Future<Object?>.sync(() => run([0])),
                throwsA(
                  isA<wasm.Exception>().having(
                    (error) => identical(error, latest),
                    'original exception',
                    isTrue,
                  ),
                ),
              );
            }
            latest = null;
          }
          // Numeric payloads need no store transfer, whether the guest catches
          // them or they pass through the public exception conversion path.
          expect(_referencePeerCount(instance), before);
        },
      );
    }
  }
}
