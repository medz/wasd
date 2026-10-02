@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/imports.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/module.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/runtime_global.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/value.dart';

void main() {
  const features = WasmFeatureSet(gc: true, additionalEnabled: {'multi-table'});
  final patterns =
      {
        'f32': [
          '7f800001',
          'ff812345',
          '7fc12345',
          'ffc54321',
          '80000000',
          '00000001',
          '3f800001',
          '7f800000',
          'ff800000',
        ],
        'f64': [
          '7ff0000000000001',
          'fff0123456789abc',
          '7ff8123456789abc',
          'fff8fedcba987654',
          '8000000000000000',
          '0000000000000001',
          '3ff0000000000001',
          '7ff0000000000000',
          'fff0000000000000',
        ],
      }.map(
        (kind, values) => MapEntry(
          kind,
          values.map((value) => BigInt.parse(value, radix: 16)).toList(),
        ),
      );
  WasmModule compiled() => WasmModule.decode(
    File('test/fixtures/gc_element_global_floats.wasm').readAsBytesSync(),
    features: features,
  );
  WasmInstance instantiate(
    WasmModule module, {
    int seed32 = 0x7f800001,
    BigInt? seed64,
  }) => WasmInstance.fromModule(
    module,
    features: features,
    imports: WasmImports(
      globalBindings: {
        WasmImports.key('env', 'seed32'): RuntimeGlobal(
          valueType: WasmValueType.f32,
          mutable: false,
          value: WasmValue.f32Bits(seed32),
        ),
        WasmImports.key('env', 'seed64'): RuntimeGlobal(
          valueType: WasmValueType.f64,
          mutable: false,
          value: WasmValue.f64Bits(seed64 ?? patterns['f64']!.first),
        ),
      },
    ),
  );
  BigInt bits(Object? value, String kind) =>
      (value is BigInt ? value : BigInt.from(value as int)).toUnsigned(
        kind == 'f32' ? 32 : 64,
      );

  for (final forceAsync in [false, true]) {
    Future<Object?> invoke(
      WasmInstance instance,
      String name, [
      List<Object?> args = const [],
    ]) async => forceAsync
        ? instance.invokeAsyncForced(name, args)
        : instance.invoke(name, args);
    group(
      forceAsync ? 'forced async GC element globals' : 'GC element globals',
      () {
        for (final kind in ['f32', 'f64']) {
          for (final path in [
            'active-new',
            'active-fixed',
            'passive-new',
            'passive-fixed',
          ]) {
            test(
              '$kind $path retains immutable local global seed bits',
              () async {
                final instance = instantiate(compiled());
                for (var i = 0; i < patterns[kind]!.length; i++) {
                  expect(
                    bits(await invoke(instance, '$kind-$path', [i]), kind),
                    patterns[kind]![i],
                    reason: '$kind $path pattern=$i async=$forceAsync',
                  );
                }
              },
            );
          }
          for (final path in ['active', 'passive']) {
            test(
              '$kind $path nested arrays isolate instances and preserve aliases',
              () async {
                final module = compiled();
                final first = instantiate(module);
                final second = instantiate(module);
                final changed = kind == 'f32'
                    ? BigInt.from(0x3f800000)
                    : BigInt.parse('3ff0000000000000', radix: 16);
                await invoke(first, '$kind-write-$path', [
                  0,
                  kind == 'f32' ? changed.toInt() : changed,
                ]);
                expect(
                  bits(await invoke(first, '$kind-read-$path', [1]), kind),
                  changed,
                );
                expect(
                  bits(await invoke(second, '$kind-read-$path', [0]), kind),
                  patterns[kind]!.first,
                );
                expect(
                  bits(await invoke(second, '$kind-read-$path', [1]), kind),
                  patterns[kind]!.first,
                );
                expect(
                  bits(
                    await invoke(instantiate(module), '$kind-read-$path', [0]),
                    kind,
                  ),
                  patterns[kind]!.first,
                );
              },
            );
          }
        }
        test(
          'one compiled module uses each instance immutable float imports',
          () async {
            final module = compiled();
            final first = instantiate(module);
            final second = instantiate(
              module,
              seed32: patterns['f32']![1].toInt(),
              seed64: patterns['f64']![1],
            );
            for (final kind in ['f32', 'f64']) {
              for (final path in ['active', 'passive']) {
                expect(
                  bits(await invoke(first, '$kind-import-$path'), kind),
                  patterns[kind]!.first,
                );
                expect(
                  bits(await invoke(second, '$kind-import-$path'), kind),
                  patterns[kind]![1],
                );
              }
            }
          },
        );
      },
    );
  }
  group('GC element global validation', () {
    for (final invalid in [
      'mutable',
      'wrong_seed_type',
      'wrong_result_type',
      'invalid_global_index',
    ]) {
      test('rejects $invalid before instantiation', () {
        final bytes = File(
          'test/fixtures/gc_element_global_invalid_$invalid.wasm',
        ).readAsBytesSync();
        expect(
          () => WasmInstance.fromBytes(bytes, features: features),
          throwsFormatException,
        );
      });
    }
  });
}
