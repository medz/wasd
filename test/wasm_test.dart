import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasm.dart';

// Inline fixture: (memory (export "memory") 1)
//                 (func (export "add") (param i32 i32) (result i32) ...)
// No imports. Generated from simple.wasm.
final _wasmBytes = Uint8List.fromList([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
  0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32,i32)->i32
  0x03, 0x02, 0x01, 0x00, // function: type 0
  0x05, 0x03, 0x01, 0x00, 0x01, // memory: min=1 page
  0x07, 0x10, 0x02, // export section: 2 exports
  0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, // "memory", mem 0
  0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // "add", func 0
  0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code
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
  });

  group('Module static methods', () {
    late Module module;

    setUp(() async {
      module = await WebAssembly.compile(_wasmBytes.buffer);
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
