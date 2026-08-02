import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/host_control_flow.dart';
import 'package:wasd/wasm.dart';
import 'support/wasm_fixtures.dart';

final _wasmBytes = simpleAddModuleBytes();
final _localSetTeeBytes = localSetTeeModuleBytes();
final _directCallBytes = directCallModuleBytes();
final _loopBranchBytes = loopBranchModuleBytes();
final _importedAndLocalGlobalBytes = importedAndLocalGlobalModuleBytes();
final _loopBackWithoutFunctionResultBytes =
    loopBackWithoutFunctionResultModuleBytes();
final _wasiStartBytes = wasiStartModuleBytes();
final _invalidBranchHintCustomSectionBytes = Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x05,
  0x01,
  0x60,
  0x01,
  0x7f,
  0x00,
  0x03,
  0x02,
  0x01,
  0x00,
  0x05,
  0x04,
  0x01,
  0x01,
  0x01,
  0x01,
  0x00,
  0x20,
  0x19,
  0x6d,
  0x65,
  0x74,
  0x61,
  0x64,
  0x61,
  0x74,
  0x61,
  0x2e,
  0x63,
  0x6f,
  0x64,
  0x65,
  0x2e,
  0x62,
  0x72,
  0x61,
  0x6e,
  0x63,
  0x68,
  0x5f,
  0x68,
  0x69,
  0x6e,
  0x74,
  0x01,
  0x00,
  0x01,
  0x07,
  0x01,
  0x01,
  0x0a,
  0x0c,
  0x01,
  0x0a,
  0x01,
  0x01,
  0x7f,
  0x20,
  0x01,
  0x20,
  0x00,
  0x46,
  0x0f,
  0x0b,
  0x00,
  0x0e,
  0x04,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x01,
  0x07,
  0x01,
  0x00,
  0x04,
  0x74,
  0x65,
  0x73,
  0x74,
]);

final _invalidBytes = Uint8List.fromList([0x00, 0x00, 0x00, 0x00]);

void main() {
  group('WebAssembly.validate', () {
    test('returns true for valid bytes', () {
      expect(WebAssembly.validate(_wasmBytes.buffer), isTrue);
    });

    test('returns false for invalid bytes', () {
      expect(WebAssembly.validate(_invalidBytes.buffer), isFalse);
    });

    test('rejects invalid branch hint custom section targets', () {
      expect(
        WebAssembly.validate(_invalidBranchHintCustomSectionBytes.buffer),
        isFalse,
      );
    });
  });

  group('WebAssembly.compile', () {
    test('returns a Module', () async {
      final module = await WebAssembly.compile(_wasmBytes.buffer);
      expect(module, isA<Module>());
    });

    test('throws CompileError for invalid bytes', () async {
      await expectLater(
        WebAssembly.compile(_invalidBytes.buffer),
        throwsA(isA<CompileError>()),
      );
    });

    test('rejects loop back-edge without enclosing function result', () async {
      await expectLater(
        WebAssembly.compile(_loopBackWithoutFunctionResultBytes.buffer),
        throwsA(isA<CompileError>()),
      );
    });

    test('rejects invalid branch hint custom section targets', () async {
      await expectLater(
        WebAssembly.compile(_invalidBranchHintCustomSectionBytes.buffer),
        throwsA(isA<CompileError>()),
      );
    });

    test('validates imported and local global index spaces', () async {
      final module = await WebAssembly.compile(
        _importedAndLocalGlobalBytes.buffer,
      );

      expect(Module.imports(module), hasLength(1));
      expect(Module.imports(module).single.kind, ImportExportKind.global);
      expect(Module.exports(module).single.name, 'sum_globals');
    });
  });

  group('Module static methods', () {
    late Module module;

    setUp(() async {
      module = await WebAssembly.compile(_wasmBytes.buffer);
    });

    test('constructor rejects invalid branch hint custom section targets', () {
      expect(
        () => Module(_invalidBranchHintCustomSectionBytes.buffer),
        throwsA(isA<CompileError>()),
      );
    });

    test('imports() returns empty list', () {
      expect(Module.imports(module), isEmpty);
    });

    test('exports() returns memory and add', () {
      final exports = Module.exports(module);
      expect(exports, hasLength(2));

      final memory = exports.firstWhere((e) => e.name == 'memory');
      expect(memory.kind, ImportExportKind.memory);

      final add = exports.firstWhere((e) => e.name == 'add');
      expect(add.kind, ImportExportKind.function);
    });

    test('customSections() returns empty for unknown name', () {
      expect(Module.customSections(module, 'name'), isEmpty);
    });
  });

  group('WebAssembly.instantiate', () {
    test('returns a WebAssembly result', () async {
      final result = await WebAssembly.instantiate(_wasmBytes.buffer);
      expect(result.module, isA<Module>());
      expect(result.instance, isA<Instance>());
    });

    test('instance has add and memory exports', () async {
      final result = await WebAssembly.instantiate(_wasmBytes.buffer);
      final exports = result.instance.exports;
      expect(exports.containsKey('add'), isTrue);
      expect(exports.containsKey('memory'), isTrue);
    });

    test('throws CompileError for invalid bytes', () async {
      await expectLater(
        WebAssembly.instantiate(_invalidBytes.buffer),
        throwsA(isA<CompileError>()),
      );
    });

    test('rejects invalid branch hint custom section targets', () async {
      await expectLater(
        WebAssembly.instantiate(_invalidBranchHintCustomSectionBytes.buffer),
        throwsA(isA<CompileError>()),
      );
    });
  });

  group('WebAssembly.instantiateModule', () {
    late Module module;

    setUp(() async {
      module = await WebAssembly.compile(_wasmBytes.buffer);
    });

    test('returns an Instance', () async {
      final instance = await WebAssembly.instantiateModule(module);
      expect(instance, isA<Instance>());
    });

    test('instance exports are consistent with module exports', () async {
      final instance = await WebAssembly.instantiateModule(module);
      final exports = instance.exports;
      final descriptors = Module.exports(module);

      for (final d in descriptors) {
        expect(
          exports.containsKey(d.name),
          isTrue,
          reason: 'missing export: ${d.name}',
        );
      }
    });
  });

  group('Host control flow', () {
    test('preserves synchronous host control-flow exceptions', () async {
      final marker = _TestHostControlFlowException();
      final result = await WebAssembly.instantiate(_wasiStartBytes.buffer, {
        'wasi_snapshot_preview1': {
          'proc_exit': ImportExportKind.function((_) => throw marker),
        },
      });
      final start =
          (result.instance.exports['_start']! as FunctionImportExportValue).ref;

      expect(() => start(const []), throwsA(same(marker)));
    });

    test('preserves async host control-flow exceptions', () async {
      final marker = _TestHostControlFlowException();
      final result = await WebAssembly.instantiate(_wasiStartBytes.buffer, {
        'wasi_snapshot_preview1': {
          'proc_exit': ImportExportKind.function((_) async => throw marker),
        },
      });
      final start =
          (result.instance.exports['_start']! as FunctionImportExportValue).ref;

      await expectLater(
        Future<Object?>.sync(() => start(const [])),
        throwsA(same(marker)),
      );
    });
  });

  group('Instance exports', () {
    late Instance instance;

    setUp(() async {
      final result = await WebAssembly.instantiate(_wasmBytes.buffer);
      instance = result.instance;
    });

    group('add function', () {
      late Function addFn;

      setUp(() {
        addFn = (instance.exports['add']! as FunctionImportExportValue).ref;
      });

      test('2 + 3 = 5', () {
        expect(addFn([2, 3]), 5);
      });

      test('0 + 0 = 0', () {
        expect(addFn([0, 0]), 0);
      });

      test('large values', () {
        expect(addFn([1000000, 2000000]), 3000000);
      });
    });

    group('memory export', () {
      late Memory memory;

      setUp(() {
        memory = (instance.exports['memory']! as MemoryImportExportValue).ref;
      });

      test('initial buffer size is 1 page (64 KiB)', () {
        expect(memory.buffer.lengthInBytes, 65536);
      });

      test('grow increases buffer size', () {
        final prev = memory.grow(1);
        expect(prev, 1); // previous page count
        expect(memory.buffer.lengthInBytes, 65536 * 2);
      });

      test('grow by zero keeps memory size', () {
        final prev = memory.grow(0);
        expect(prev, 1);
        expect(memory.buffer.lengthInBytes, 65536);
      });
    });
  });

  group('Host-created memory and tables', () {
    test('memory can omit maximum pages', () {
      final memory = Memory(const MemoryDescriptor(initial: 1));

      expect(memory.buffer.lengthInBytes, 65536);
      expect(memory.grow(0), 1);
    });

    test('table can omit maximum elements', () {
      final table = Table(
        const TableDescriptor<ExternRef, Object?>(TableKind.externref, 1),
      );

      expect(table.length, 1);
      expect(table.get(0), isNull);
      expect(table.grow(1), 1);
      expect(table.length, 2);
    });
  });

  group('Interpreter local ops', () {
    late Instance instance;

    setUp(() async {
      final result = await WebAssembly.instantiate(_localSetTeeBytes.buffer);
      instance = result.instance;
    });

    test('local.tee keeps the value on stack and writes the local', () {
      final fn =
          (instance.exports['tee_add']! as FunctionImportExportValue).ref;
      expect(fn([5]), 17);
      expect(fn([-3]), 1);
    });

    test('local.set writes the local without leaving an extra stack value', () {
      final fn =
          (instance.exports['set_add']! as FunctionImportExportValue).ref;
      expect(fn([5]), 12);
      expect(fn([-3]), 4);
    });
  });

  group('Interpreter direct call ops', () {
    late Instance instance;

    setUp(() async {
      final result = await WebAssembly.instantiate(_directCallBytes.buffer);
      instance = result.instance;
    });

    test('call executes the direct callee with correct results', () {
      final inc = (instance.exports['inc']! as FunctionImportExportValue).ref;
      final callTwice =
          (instance.exports['call_twice']! as FunctionImportExportValue).ref;

      expect(inc([0]), 1);
      expect(inc([41]), 42);
      expect(callTwice([0]), 2);
      expect(callTwice([41]), 43);
      expect(callTwice([-2]), 0);
    });
  });

  group('Interpreter loop and branch ops', () {
    late Instance instance;

    setUp(() async {
      final result = await WebAssembly.instantiate(_loopBranchBytes.buffer);
      instance = result.instance;
    });

    test('loop_count preserves block and loop branch semantics', () {
      final loopCount =
          (instance.exports['loop_count']! as FunctionImportExportValue).ref;

      expect(loopCount([0]), 0);
      expect(loopCount([1]), 1);
      expect(loopCount([5]), 5);
      expect(loopCount([10]), 10);
    });
  });

  group('WebAssembly.compileStreaming', () {
    test('compiles from a stream', () async {
      final stream = Stream.value(_wasmBytes.toList());
      final module = await WebAssembly.compileStreaming(stream);
      expect(module, isA<Module>());
    });

    test('chunked stream works correctly', () async {
      final half = _wasmBytes.length ~/ 2;
      final stream = Stream.fromIterable([
        _wasmBytes.sublist(0, half).toList(),
        _wasmBytes.sublist(half).toList(),
      ]);
      final module = await WebAssembly.compileStreaming(stream);
      expect(Module.exports(module), hasLength(2));
    });
  });

  group('WebAssembly.instantiateStreaming', () {
    test('instantiates from a stream', () async {
      final stream = Stream.value(_wasmBytes.toList());
      final result = await WebAssembly.instantiateStreaming(stream);
      expect(result.instance.exports.containsKey('add'), isTrue);
    });
  });
}

final class _TestHostControlFlowException
    implements WasmHostControlFlowException {}
