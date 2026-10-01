@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/vm.dart';

void main() {
  late WasmInstance instance;
  setUp(() {
    instance = WasmInstance.fromBytes(
      File('test/fixtures/gc_array_v128.wasm').readAsBytesSync(),
      features: const WasmFeatureSet(gc: true, simd: true),
    );
  });

  List<int> vector(String export, List<Object?> arguments) =>
      WasmVm.v128BytesForValue(instance.invoke(export, arguments) as int)!;

  final memoryTrap = throwsA(
    predicate<Object>(
      (error) => error.toString().contains('out of bounds memory access'),
    ),
  );
  final arrayTrap = throwsA(
    predicate<Object>(
      (error) => error.toString().contains('out of bounds array access'),
    ),
  );

  test('array.new_data copies unaligned v128 elements in byte order', () {
    expect(vector('new', [1, 2, 0]), List.generate(16, (i) => i));
    expect(vector('new', [1, 2, 1]), List.generate(16, (i) => i + 16));
    instance.invoke('drop');
    expect(instance.invoke('new-empty', [0]), 0);
    expect(() => instance.invoke('new', [0, 1, 0]), memoryTrap);
  });

  test('array.init_data copies vectors without changing adjacent elements', () {
    instance.invoke('init', [1, 1, 2]);
    expect(vector('get', [0]), List.filled(16, 0));
    expect(vector('get', [1]), List.generate(16, (i) => i));
    expect(vector('get', [2]), List.generate(16, (i) => i + 16));
    instance.invoke('drop');
    expect(vector('get', [2]), List.generate(16, (i) => i + 16));
  });

  test('v128 initialization checks byte and element bounds before writing', () {
    instance.invoke('init', [0, 1, 1]);
    expect(() => instance.invoke('init', [0, 2, 2]), memoryTrap);
    expect(() => instance.invoke('init', [2, 1, 2]), arrayTrap);
    expect(vector('get', [0]), List.generate(16, (i) => i));
    expect(vector('get', [1]), List.filled(16, 0));
    expect(() => instance.invoke('new', [2, 2, 0]), memoryTrap);
    expect(instance.invoke('new-empty', [33]), 0);
    expect(() => instance.invoke('new-empty', [34]), memoryTrap);
    instance.invoke('init', [3, 33, 0]);
    instance.invoke('drop');
    instance.invoke('init', [3, 0, 0]);
    expect(() => instance.invoke('init', [0, 0, 1]), memoryTrap);
  });

  test('forced async execution initializes the same v128 bytes', () async {
    final value = await instance.invokeAsyncForced('new', [1, 2, 1]) as int;
    expect(WasmVm.v128BytesForValue(value), List.generate(16, (i) => i + 16));
    await instance.invokeAsyncForced('init', [1, 1, 2]);
    expect(vector('get', [0]), List.filled(16, 0));
    expect(vector('get', [1]), List.generate(16, (i) => i));
    expect(vector('get', [2]), List.generate(16, (i) => i + 16));
    await expectLater(
      instance.invokeAsyncForced('init', [0, 2, 2]),
      memoryTrap,
    );
    expect(vector('get', [1]), List.generate(16, (i) => i));
    await instance.invokeAsyncForced('drop');
    await instance.invokeAsyncForced('init', [3, 0, 0]);
    await expectLater(instance.invokeAsyncForced('new', [0, 1, 0]), memoryTrap);
  });

  for (final forceAsync in [false, true]) {
    group(
      forceAsync ? 'forced async GC f32 data bits' : 'GC f32 data bits',
      () {
        late WasmInstance floatInstance;
        setUp(() {
          floatInstance = WasmInstance.fromBytes(
            File('test/fixtures/gc_array_f32.wasm').readAsBytesSync(),
            features: const WasmFeatureSet(gc: true),
          );
        });

        Future<Object?> invoke(
          String name, [
          List<Object?> args = const [],
        ]) async => forceAsync
            ? floatInstance.invokeAsyncForced(name, args)
            : floatInstance.invoke(name, args);

        // Raw little-endian bytes follow one padding byte in the fixture.
        const patterns = [
          0x7f800001, // Positive signaling NaN.
          0xff812345, // Negative signaling NaN with a distinct payload.
          0x7fc12345, // Positive quiet NaN with payload.
          0xffc54321, // Negative quiet NaN with payload.
          0x80000000, // Negative zero.
          0x00000001, // Smallest positive subnormal.
          0x3f800001, // Finite value above one.
          0x7f800000, // Positive infinity.
          0xff800000, // Negative infinity.
        ];

        for (final operation in ['new', 'init', 'copy', 'set']) {
          test(
            '$operation preserves raw f32 bits at unaligned offsets',
            () async {
              for (var i = 0; i < patterns.length; i++) {
                final bits = await invoke('$operation-f32', [1 + i * 4]) as int;
                expect(bits.toUnsigned(32), patterns[i], reason: 'pattern $i');
                if (operation != 'new') {
                  expect(await invoke('get-f32', [0]), 0x3f800000);
                  expect(await invoke('get-f32', [2]), 0x3f800000);
                }
              }
            },
          );
        }

        for (final operation in ['new', 'init']) {
          test(
            '$operation preserves adjacent f64 signaling NaN bits',
            () async {
              final bits = await invoke('$operation-f64');
              final integer = bits is BigInt ? bits : BigInt.from(bits as int);
              expect(
                integer.toUnsigned(64),
                BigInt.parse('7ff0000000000001', radix: 16),
              );
            },
          );
        }

        test('out of bounds f32 data does not change the target', () async {
          await expectLater(invoke('init-f32', [34]), memoryTrap);
          expect(await invoke('get-f32', [1]), 0x3f800000);
          await expectLater(invoke('new-f32', [34]), memoryTrap);
        });
      },
    );
  }
}
