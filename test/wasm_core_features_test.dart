import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasm.dart';

import 'support/core_multi_memory_fixtures.dart';
import 'support/runtime_environment.dart';
import 'support/wasm_fixtures.dart';

void main() {
  test('supported explicit options are immutable and backend specific', () {
    expect(
      Module.supportedFeatures,
      hasDartIoRuntime ? {CoreFeature.multiMemory} : isEmpty,
    );
    expect(
      () => Module.supportedFeatures.add(CoreFeature.multiMemory),
      throwsUnsupportedError,
    );
  });

  test('existing default and explicit empty options still execute', () {
    for (final module in [
      Module(simpleAddModuleBytes().buffer),
      Module(simpleAddModuleBytes().buffer, features: {}),
    ]) {
      final add = Instance(module).exports['add']! as FunctionImportExportValue;
      expect(add.ref([20, 22]), 42);
    }
  });

  test('VM default still rejects multiple memories', () {
    expect(
      () => Module(multiMemoryFixture('operations').buffer),
      throwsA(
        isA<CompileError>().having(
          (e) => e.message,
          'message',
          contains('multiple memories are not enabled'),
        ),
      ),
    );
  }, skip: !hasDartIoRuntime);

  test('JS rejects an unsupported explicit option before compilation', () {
    expect(
      () => Module(Uint8List(0).buffer, features: {CoreFeature.multiMemory}),
      throwsA(
        isA<CompileError>().having(
          (e) => e.message,
          'message',
          contains('multiMemory'),
        ),
      ),
    );
  }, skip: hasDartIoRuntime);

  if (!hasDartIoRuntime) return;

  test('different memory indices may share one imported memory', () {
    final shared = Memory(const MemoryDescriptor(initial: 1, maximum: 2));
    final module = Module(
      multiMemoryFixture('operations').buffer,
      features: {CoreFeature.multiMemory},
    );
    final instance = Instance(module, {
      'host': {
        'tick': ImportExportKind.function((_) => null),
        'left': ImportExportKind.memory(shared),
        'right': ImportExportKind.memory(shared),
      },
    });
    final left = (instance.exports['left']! as MemoryImportExportValue).ref;
    expect(left.buffer.asUint8List().sublist(2, 6), [0x11, 0x22, 0x33, 0x44]);
    (instance.exports['store']! as FunctionImportExportValue).ref([6, 42]);
    expect(left.buffer.asByteData().getUint32(6, Endian.little), 42);
    expect(
      (instance.exports['grow']! as FunctionImportExportValue).ref([1]),
      1,
    );
    expect(left.buffer.lengthInBytes, 131072);
  });

  test('opt-in preserves memory import limit checks', () {
    final module = Module(
      multiMemoryFixture('operations').buffer,
      features: {CoreFeature.multiMemory},
    );
    expect(
      () => Instance(module, {
        'host': {
          'tick': ImportExportKind.function((_) => null),
          'left': ImportExportKind.memory(
            Memory(const MemoryDescriptor(initial: 0, maximum: 2)),
          ),
          'right': ImportExportKind.memory(
            Memory(const MemoryDescriptor(initial: 1, maximum: 3)),
          ),
        },
      }),
      throwsA(isA<LinkError>()),
    );
  });

  for (final asyncHost in [false, true]) {
    test(
      'multi-memory operations and imports, async host=$asyncHost',
      () async {
        final options = {CoreFeature.multiMemory};
        final module = Module(
          multiMemoryFixture('operations').buffer,
          features: options,
        );
        options.clear(); // Compilation owns its feature configuration.
        final left = Memory(const MemoryDescriptor(initial: 1, maximum: 2));
        final right = Memory(const MemoryDescriptor(initial: 1, maximum: 3));
        final tick = asyncHost
            ? (List<Object?> _) async => null
            : (List<Object?> _) => null;
        final imports = <String, Map<String, ImportValue>>{
          'host': {
            'tick': ImportExportKind.function(tick),
            'left': ImportExportKind.memory(left),
            'right': ImportExportKind.memory(right),
          },
        };
        final instance = Instance(module, imports);
        final second = Instance(module, imports);
        Memory memory(String name, [Instance? from]) =>
            ((from ?? instance).exports[name]! as MemoryImportExportValue).ref;
        Future<Object?> call(String name, List<Object?> args) async =>
            (instance.exports[name]! as FunctionImportExportValue).ref(args);

        memory('rightAlias').buffer.asUint8List()[20] = 0x55;
        expect(right.buffer.asUint8List()[20], 0x55);
        expect(memory('right').buffer.asUint8List()[20], 0x55);
        expect(memory('right', second).buffer.asUint8List()[20], 0x55);
        memory('left').buffer.asUint8List()[20] = 0x66;
        expect(left.buffer.asUint8List()[20], 0x66);
        expect(await call('load', [2]), 0x44332211);
        await call('store', [6, 0x12345678]);
        expect(
          right.buffer.asByteData().getUint32(6, Endian.little),
          0x12345678,
        );
        expect(left.buffer.asUint8List().take(10), everyElement(0));
        await call('copy', [0, 2, 8]);
        expect(memory('local').buffer.asUint8List().take(8), [
          0x11,
          0x22,
          0x33,
          0x44,
          0x78,
          0x56,
          0x34,
          0x12,
        ]);
        expect(
          memory('local', second).buffer.asUint8List().take(8),
          everyElement(0),
        );
        await call('fill', [2, 0xfe, 2]);
        expect(right.buffer.asUint8List().sublist(2, 4), [0xfe, 0xfe]);
        await call('init', [10, 0, 2]);
        expect(memory('local').buffer.asUint8List().sublist(10, 12), [
          0xab,
          0xcd,
        ]);
        await call('drop', []);
        await expectLater(
          call('init', [0, 0, 1]),
          throwsA(
            predicate<Object>(
              (e) => e
                  .toString()
                  .toLowerCase()
                  .replaceAll('-', ' ')
                  .contains('out of bounds'),
            ),
          ),
        );
        expect(await call('size', []), 1);
        expect(await call('grow', [1]), 1);
        expect(await call('size', []), 2);
        expect(memory('rightAlias').buffer.lengthInBytes, 131072);
        expect(memory('right', second).buffer.lengthInBytes, 131072);
        expect(left.buffer.lengthInBytes, 65536);
        expect(memory('local').buffer.lengthInBytes, 65536);
        expect(await call('grow', [2]), -1);
        await call('copy', [65536, 131072, 0]);
        await expectLater(
          call('copy', [65537, 0, 0]),
          throwsA(
            predicate<Object>(
              (e) => e
                  .toString()
                  .toLowerCase()
                  .replaceAll('-', ' ')
                  .contains('out of bounds'),
            ),
          ),
        );
        await expectLater(
          call('load', [131071]),
          throwsA(
            predicate<Object>(
              (e) => e
                  .toString()
                  .toLowerCase()
                  .replaceAll('-', ' ')
                  .contains('out of bounds'),
            ),
          ),
        );
      },
    );
  }

  for (final name in [
    'invalid_index',
    'invalid_copy',
    'invalid_alignment',
    'invalid_type',
    'simd_combination',
    'table_combination',
    'gc_combination',
  ]) {
    test('opt-in rejects $name', () {
      expect(
        () => Module(
          multiMemoryFixture(name).buffer,
          features: {CoreFeature.multiMemory},
        ),
        throwsA(isA<CompileError>()),
      );
    });
  }

  test('active segment bounds fail at instantiation', () {
    final module = Module(
      multiMemoryFixture('active_bounds').buffer,
      features: {CoreFeature.multiMemory},
    );
    expect(() => Instance(module), throwsA(isA<LinkError>()));
  });
}
