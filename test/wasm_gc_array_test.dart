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
}
