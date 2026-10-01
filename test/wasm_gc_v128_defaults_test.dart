@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/vm.dart';

void main() {
  for (final forceAsync in [false, true]) {
    group(
      forceAsync ? 'forced async GC v128 defaults' : 'GC v128 defaults',
      () {
        late WasmInstance instance;
        setUp(() {
          instance = WasmInstance.fromBytes(
            File('test/fixtures/gc_v128_defaults.wasm').readAsBytesSync(),
            features: const WasmFeatureSet(gc: true, simd: true),
          );
        });

        Future<Object?> invoke(
          String name, [
          List<Object?> arguments = const [],
        ]) async => forceAsync
            ? instance.invokeAsyncForced(name, arguments)
            : instance.invoke(name, arguments);

        for (final name in [
          'struct',
          'array',
          'global-struct',
          'global-array',
          'default-after-write',
          'element-array',
          'passive-element-array',
        ]) {
          test('$name contains sixteen zero bytes', () async {
            final arguments =
                name.endsWith('array') || name == 'default-after-write'
                ? <Object?>[1]
                : <Object?>[];
            final value = await invoke(name, arguments) as int;
            expect(WasmVm.v128BytesForValue(value), List.filled(16, 0));
            if (name == 'default-after-write') {
              final written = await invoke(name, [0]) as int;
              expect(WasmVm.v128BytesForValue(written), [
                1,
                0,
                0,
                0,
                2,
                0,
                0,
                0,
                3,
                0,
                0,
                0,
                4,
                0,
                0,
                0,
              ]);
            }
          });
        }

        for (final name in [
          'array-any-true',
          'element-any-true',
          'passive-element-any-true',
        ]) {
          test('$name default vector is a valid SIMD operand', () async {
            expect(await invoke(name), 0);
          });
        }
      },
    );
  }
}
