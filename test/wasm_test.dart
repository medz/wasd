import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/byte_reader.dart'
    as native_reader;
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart'
    as native_features;
import 'package:wasd/src/wasm/backend/native/interpreter/module.dart'
    as native_module;
import 'package:wasd/src/wasm/backend/native/interpreter/runtime_function.dart'
    as native_runtime;
import 'package:wasd/src/wasm/backend/native/interpreter/value.dart'
    as native_value;
import 'package:wasd/src/wasm/backend/native/interpreter/validator.dart'
    as native_validator;
import 'package:wasd/src/wasm/backend/native/interpreter/vm.dart' as native_vm;
import 'package:wasd/src/wasm/host_control_flow.dart';
import 'package:wasd/wasm.dart';
import 'support/host_exception_fixtures.dart';
import 'support/wasm_fixtures.dart';

final _wasmBytes = simpleAddModuleBytes();
final _localSetTeeBytes = localSetTeeModuleBytes();
final _directCallBytes = directCallModuleBytes();
final _loopBranchBytes = loopBranchModuleBytes();
final _importedAndLocalGlobalBytes = importedAndLocalGlobalModuleBytes();
final _loopBackWithoutFunctionResultBytes =
    loopBackWithoutFunctionResultModuleBytes();
final _wasiStartBytes = wasiStartModuleBytes();
// run increments entries, calls host.op(41), then increments tail and adds one
// to the host result. Counters distinguish suspension from guest replay.
final _asyncHostValueBytes = base64Decode(
  'AGFzbQEAAAABCgJgAX8Bf2AAAX8CCwEEaG9zdAJvcAAAAwQDAQEBBgsCfwFBAAt/AUEACwcYAwNydW4AAQdlbnRyaWVzAAIEdGFpbAADCikDHQEBfyMAQQFqJABBKRAAIQAjAUEBaiQBIABBAWoLBAAjAAsEACMBCwArBG5hbWUBBQEAAm9wAgsBAQEABnJlc3VsdAcQAgAHZW50cmllcwEEdGFpbA==',
);
// run calls pause then op, before calls op then pause, ordinary only calls op.
// Each export increments tail only after both host calls return.
final _asyncHostMixedBytes = base64Decode(
  'AGFzbQEAAAABDANgAABgAX8AYAABfwIYAgRob3N0BXBhdXNlAAAEaG9zdAJvcAABAwYFAAAAAAIGBgF/AUEACwciBANydW4AAwZiZWZvcmUABAhvcmRpbmFyeQAFBHRhaWwABgovBQkAIwBBAWokAAsKABAAQSkQARACCwoAQSkQARAAEAILCABBKRABEAILBAAjAAsAJARuYW1lARQDAAVwYXVzZQECb3ACBmZpbmlzaAcHAQAEdGFpbA==',
);
// The core start calls ordinary h.op; the declared async h.pause stays unused.
final _syncStartWithAsyncImportBytes = base64Decode(
  'AGFzbQEAAAABCAJgAABgAAF/AhICAWgFcGF1c2UAAAFoAm9wAAADAwIAAQcKAQZhbnN3ZXIAAwgBAgoLAgQAEAELBABBKgsAGgRuYW1lARMDAAVwYXVzZQECb3ACBXN0YXJ0',
);
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
  group('Interpreter u32 decoding', () {
    for (final (bytes, expected) in <(List<int>, int)>[
      ([0], 0),
      ([0x80, 0x80, 0x80, 0x80, 0], 0),
      ([0xff, 0xff, 0xff, 0xff, 0x0f], 4294967295),
    ]) {
      test('accepts in-range encoding $bytes', () {
        expect(
          native_reader.ByteReader(Uint8List.fromList(bytes)).readVarUint32(),
          expected,
        );
      });
    }
    for (final (bytes, expected) in <(List<int>, String)>[
      ([0xff, 0xff, 0xff, 0xff, 0x10], 'integer too large'),
      ([0x80, 0x80, 0x80, 0x80, 0x80, 0], 'integer representation too long'),
    ]) {
      test('distinguishes malformed cause: $expected', () {
        expect(
          () => native_reader.ByteReader(
            Uint8List.fromList(bytes),
          ).readVarUint32(),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains(expected),
            ),
          ),
        );
      });
    }
  });

  group('native GC type validation', () {
    const features = native_features.WasmFeatureSet(gc: true);

    native_module.WasmModule moduleWithSupertypes(List<int> supertypes) {
      // Two non-final empty structs followed by a child with the given parents.
      // Mirrors the frozen Core type-subtyping.wast multiple-supertypes case.
      final types = <int>[
        3,
        0x50,
        0,
        0x5f,
        0,
        0x50,
        0,
        0x5f,
        0,
        0x50,
        supertypes.length,
        ...supertypes,
        0x5f,
        0,
      ];
      return native_module.WasmModule.decode(
        Uint8List.fromList([
          0x00,
          0x61,
          0x73,
          0x6d,
          0x01,
          0x00,
          0x00,
          0x00,
          0x01,
          types.length,
          ...types,
        ]),
        features: features,
      );
    }

    for (final supertypes in <List<int>>[
      [],
      [0],
    ]) {
      test('accepts ${supertypes.length} supertype', () {
        final module = moduleWithSupertypes(supertypes);
        native_validator.WasmValidator.validateModule(
          module,
          features: features,
        );
      });
    }

    test('rejects multiple supertypes after binary decoding', () {
      final module = moduleWithSupertypes([0, 1]);
      expect(module.types.last.superTypeIndices, [0, 1]);
      expect(
        () => native_validator.WasmValidator.validateModule(
          module,
          features: features,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('multiple supertypes'),
          ),
        ),
      );
    });
  });

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

    group('customSections()', () {
      late Module customModule;

      setUp(() async {
        final sections = <(String, List<int>)>[
          ('ascii', [1]),
          ('中文/🦋', [0x00, 0xff, 0x80, 0xef, 0xbb, 0xbf]),
          ('', [2]),
          ('\uFEFFascii', [3]),
          ('\uFEFF\uFEFF', [4]),
          ('nul\u0000name', [5]),
          ('é', [6]),
          ('e\u0301', [7]),
          ('\uFFFD', [8]),
          ('中文/🦋', []),
        ];
        final bytes = <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
        for (final (name, payload) in sections) {
          final nameBytes = utf8.encode(name);
          final section = [nameBytes.length, ...nameBytes, ...payload];
          bytes.addAll([0x00, section.length, ...section]);
        }
        customModule = await WebAssembly.compile(
          Uint8List.fromList(bytes).buffer,
        );
      });

      test('returns UTF-8 named payloads in section order', () {
        expect(
          Module.customSections(
            customModule,
            '中文/🦋',
          ).map((b) => b.asUint8List()),
          [
            [0x00, 0xff, 0x80, 0xef, 0xbb, 0xbf],
            <int>[],
          ],
        );
      });

      test('preserves ASCII, empty, BOM, and NUL names', () {
        for (final (name, payload) in <(String, int)>[
          ('ascii', 1),
          ('', 2),
          ('\uFEFFascii', 3),
          ('\uFEFF\uFEFF', 4),
          ('nul\u0000name', 5),
        ]) {
          expect(
            Module.customSections(customModule, name).single.asUint8List(),
            [payload],
            reason: 'Custom section name: ${name.codeUnits}',
          );
        }
        expect(Module.customSections(customModule, 'nul'), isEmpty);
        expect(Module.customSections(customModule, 'missing'), isEmpty);
      });

      test('compares exact Unicode strings without aliases', () {
        for (final (name, payload) in <(String, int)>[
          ('é', 6),
          ('e\u0301', 7),
          ('\uFFFD', 8),
        ]) {
          expect(
            Module.customSections(customModule, name).single.asUint8List(),
            [payload],
          );
        }
        expect(Module.customSections(customModule, 'Ã©'), isEmpty);
        expect(Module.customSections(customModule, '\uD800'), isEmpty);
        expect(Module.customSections(customModule, '\uDC00'), isEmpty);
      });

      test('returns an independent copy of each matching payload', () {
        final first = Module.customSections(customModule, '中文/🦋');
        first.first.asUint8List().fillRange(0, first.first.lengthInBytes, 0);

        expect(
          Module.customSections(customModule, '中文/🦋').first.asUint8List(),
          [0x00, 0xff, 0x80, 0xef, 0xbb, 0xbf],
        );
      });
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
    WasmFunction function(Instance instance, String name) =>
        (instance.exports[name]! as FunctionImportExportValue).ref;

    for (final creation in ['Instance', 'bytes', 'module', 'streaming']) {
      test('awaits pending typed host results through $creation', () async {
        final pending = Completer<int>();
        addTearDown(() {
          if (!pending.isCompleted) pending.complete(41);
        });
        var calls = 0;
        final imports = {
          'host': {
            'op': ImportExportKind.function((args) async {
              calls++;
              expect(args, [41]);
              return await pending.future;
            }),
          },
        };
        final bytes = _asyncHostValueBytes;
        final instance = switch (creation) {
          'Instance' => Instance(Module(bytes.buffer), imports),
          'module' => await WebAssembly.instantiateModule(
            await WebAssembly.compile(bytes.buffer),
            imports,
          ),
          'streaming' => (await WebAssembly.instantiateStreaming(
            Stream.fromIterable([bytes.sublist(0, 11), bytes.sublist(11)]),
            imports,
          )).instance,
          _ => (await WebAssembly.instantiate(bytes.buffer, imports)).instance,
        };
        final result = function(instance, 'run')(const []);
        expect(result, isA<Future<Object?>>());
        await Future<void>.delayed(Duration.zero);
        expect(calls, 1);
        expect(
          await (function(instance, 'entries')(const []) as Future<Object?>),
          1,
        );
        expect(
          await (function(instance, 'tail')(const []) as Future<Object?>),
          0,
        );
        pending.complete(41);
        expect(await (result as Future<Object?>), 42);
        expect(calls, 1);
        expect(
          await (function(instance, 'entries')(const []) as Future<Object?>),
          1,
        );
        expect(
          await (function(instance, 'tail')(const []) as Future<Object?>),
          1,
        );
      });
    }

    test('keeps ordinary synchronous host results synchronous', () {
      final instance = Instance(Module(_asyncHostValueBytes.buffer), {
        'host': {'op': ImportExportKind.function((args) => args.single)},
      });
      expect(function(instance, 'run')(const []), 42);
      expect(function(instance, 'entries')(const []), 1);
      expect(function(instance, 'tail')(const []), 1);
    });

    test('unused async bindings do not change synchronous exports', () async {
      final instance = (await WebAssembly.instantiate(_wasmBytes.buffer, {
        'unused': {'callback': ImportExportKind.function((_) async => 1)},
      })).instance;
      expect(function(instance, 'add')([20, 22]), 42);
    });

    test('start cannot launch an asynchronous host callback', () async {
      var calls = 0;
      final bytes = hostExceptionFixture('host_start');
      final module = Module(bytes.buffer);
      final imports = {
        'host': {
          'tick': ImportExportKind.function((_) async {
            calls++;
            return null;
          }),
        },
      };
      for (final create in <Object? Function()>[
        () => Instance(module, imports),
        () => WebAssembly.instantiateModule(module, imports),
        () => WebAssembly.instantiate(bytes.buffer, imports),
        () => WebAssembly.instantiateStreaming(Stream.value(bytes), imports),
      ]) {
        await expectLater(Future<Object?>.sync(create), throwsA(anything));
        expect(calls, 0);
      }
    });

    for (final controlFlow in [false, true]) {
      test(
        'synchronous start retains host error controlFlow=$controlFlow',
        () async {
          final bytes = _syncStartWithAsyncImportBytes;
          final module = Module(bytes.buffer);
          var calls = 0;
          var asyncCalls = 0;
          final marker = controlFlow
              ? _TestHostControlFlowException()
              : StateError('synchronous start host marker');
          final stack = StackTrace.fromString('synchronous-start-host-stack');
          Never failStart(List<Object?> _) {
            calls++;
            Error.throwWithStackTrace(marker, stack);
          }

          final imports = {
            'h': {
              'pause': ImportExportKind.function((_) async {
                asyncCalls++;
                return null;
              }),
              'op': ImportExportKind.function(failStart),
            },
          };
          for (final create in <Object? Function()>[
            () => Instance(module, imports),
            () => WebAssembly.instantiateModule(module, imports),
            () => WebAssembly.instantiate(bytes.buffer, imports),
            () =>
                WebAssembly.instantiateStreaming(Stream.value(bytes), imports),
          ]) {
            calls = 0;
            try {
              await Future<Object?>.sync(create);
              fail('Expected the original start host error.');
            } catch (error, sourceStack) {
              expect(error, same(marker));
              expect('$sourceStack', contains('synchronous-start-host-stack'));
            }
            expect(calls, 1);
            expect(asyncCalls, 0);
          }
        },
      );
    }

    for (final futureOr in [false, true]) {
      test('rejects erased Future without replay futureOr=$futureOr', () async {
        var calls = 0;
        final pending = Completer<Object?>();
        addTearDown(() {
          if (!pending.isCompleted) pending.complete(null);
        });
        Object? erased(List<Object?> _) {
          calls++;
          return pending.future;
        }

        FutureOr<Object?> union(List<Object?> _) => erased(const []);
        final instance = Instance(Module(_asyncHostValueBytes.buffer), {
          'host': {'op': ImportExportKind.function(futureOr ? union : erased)},
        });
        final failure = expectLater(
          Future<Object?>.sync(() => function(instance, 'run')(const [])),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => error.message,
              'message',
              contains('async => await'),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        pending.completeError(StateError('observed erased Future'));
        await failure;
        expect(calls, 1);
        expect(function(instance, 'entries')(const []), 1);
        expect(function(instance, 'tail')(const []), 0);
      });
    }

    for (final name in ['run', 'before', 'ordinary']) {
      test('rejects erased Future in async instance export $name', () async {
        var calls = 0;
        final pending = Completer<Object?>();
        addTearDown(() {
          if (!pending.isCompleted) pending.complete(null);
        });
        Object? erased(List<Object?> _) {
          calls++;
          return pending.future;
        }

        final instance = Instance(Module(_asyncHostMixedBytes.buffer), {
          'host': {
            'pause': ImportExportKind.function((_) async => null),
            'op': ImportExportKind.function(erased),
          },
        });
        final failure = expectLater(
          Future<Object?>.sync(() => function(instance, name)(const [])),
          throwsA(isA<UnsupportedError>()),
        );
        await Future<void>.delayed(Duration.zero);
        pending.completeError(StateError('observed mixed erased Future'));
        await failure;
        expect(calls, 1);
        expect(
          await (function(instance, 'tail')(const []) as Future<Object?>),
          0,
        );
      });
    }

    test('preserves a synchronous host failure after suspension', () async {
      final marker = _TestHostControlFlowException();
      final pause = Completer<void>();
      addTearDown(() {
        if (!pause.isCompleted) pause.complete();
      });
      var calls = 0;
      final instance = Instance(Module(_asyncHostMixedBytes.buffer), {
        'host': {
          'pause': ImportExportKind.function((_) => pause.future),
          'op': ImportExportKind.function((_) {
            calls++;
            throw marker;
          }),
        },
      });
      final failure = expectLater(
        Future<Object?>.sync(() => function(instance, 'run')(const [])),
        throwsA(same(marker)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
      expect(
        await (function(instance, 'tail')(const []) as Future<Object?>),
        0,
      );
      pause.complete();
      await failure;
      expect(calls, 1);
      expect(
        await (function(instance, 'tail')(const []) as Future<Object?>),
        0,
      );
    });

    for (final name in ['run', 'before', 'ordinary']) {
      test('preserves host error and stack in async export $name', () async {
        final marker = StateError('ordinary synchronous host error');
        final stack = StackTrace.fromString('original-host-stack-$name');
        var calls = 0;
        final instance = Instance(Module(_asyncHostMixedBytes.buffer), {
          'host': {
            'pause': ImportExportKind.function((_) async => null),
            'op': ImportExportKind.function((_) {
              calls++;
              Error.throwWithStackTrace(marker, stack);
            }),
          },
        });
        try {
          await (function(instance, name)(const []) as Future<Object?>);
          fail('Expected the original host error.');
        } catch (error, sourceStack) {
          expect(error, same(marker));
          expect('$sourceStack', contains('original-host-stack-$name'));
        }
        expect(calls, 1);
        expect(
          await (function(instance, 'tail')(const []) as Future<Object?>),
          0,
        );
      });
    }

    test('keeps concurrent asynchronous failure identities separate', () async {
      final first = Completer<int>();
      final second = Completer<int>();
      addTearDown(() {
        if (!first.isCompleted) first.complete(41);
        if (!second.isCompleted) second.complete(41);
      });
      var calls = 0;
      final instance = Instance(Module(_asyncHostValueBytes.buffer), {
        'host': {
          'op': ImportExportKind.function(
            (_) => (++calls == 1 ? first : second).future,
          ),
        },
      });
      final a = StateError('first asynchronous call');
      final b = _TestHostControlFlowException();
      final one = expectLater(
        Future<Object?>.sync(() => function(instance, 'run')(const [])),
        throwsA(same(a)),
      );
      final two = expectLater(
        Future<Object?>.sync(() => function(instance, 'run')(const [])),
        throwsA(same(b)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      second.completeError(b);
      await two;
      first.completeError(a);
      await one;
      expect(
        await (function(instance, 'entries')(const []) as Future<Object?>),
        2,
      );
      expect(
        await (function(instance, 'tail')(const []) as Future<Object?>),
        0,
      );
    });

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

  group('Interpreter function references', () {
    test('binds one async invoker and invokes matching references', () async {
      final target = _hostFunctionVm((_) => 0);
      var invocationCount = 0;
      target.vm.registerAsyncFunctionRefInvoker((
        functionIndex,
        args,
        depth,
        force,
      ) async {
        invocationCount++;
        expect(functionIndex, 0);
        expect(args.single.asI32(), 41);
        expect(depth, 3);
        expect(force, isTrue);
        return <native_value.WasmValue>[native_value.WasmValue.i32(42)];
      });

      expect(target.vm.functionRefMatchesType(target.reference, 0), isTrue);
      expect(target.vm.functionRefMatchesType(-1, 0), isFalse);
      expect(
        () => target.vm.registerAsyncFunctionRefInvoker(
          (_, _, _, _) async => const <native_value.WasmValue>[],
        ),
        throwsStateError,
      );

      final result = await target.vm.invokeFunctionRefAsync(
        target.reference,
        <native_value.WasmValue>[native_value.WasmValue.i32(41)],
        depth: 3,
        force: true,
      );

      expect(result.single.asI32(), 42);
      expect(invocationCount, 1);
    });

    test('delivers function-reference failures through futures', () async {
      final target = _hostFunctionVm(
        (_) => throw StateError('synchronous host failure'),
      );
      late Future<List<native_value.WasmValue>> invalidReference;
      late Future<List<native_value.WasmValue>> executionFailure;

      expect(
        () => invalidReference = target.vm.invokeFunctionRefAsync(
          -1,
          const <native_value.WasmValue>[],
          depth: 0,
          force: false,
        ),
        returnsNormally,
      );
      expect(
        () => executionFailure = target.vm.invokeFunctionRefAsync(
          target.reference,
          const <native_value.WasmValue>[],
          depth: 0,
          force: false,
        ),
        returnsNormally,
      );

      await expectLater(invalidReference, throwsStateError);
      await expectLater(
        executionFailure,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'synchronous host failure',
          ),
        ),
      );
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

({native_vm.WasmVm vm, int reference}) _hostFunctionVm(
  Object? Function(List<Object?> args) callback,
) {
  const type = native_module.WasmFunctionType(
    params: <native_module.WasmValueType>[],
    results: <native_module.WasmValueType>[],
    kind: native_module.WasmCompositeTypeKind.function,
  );
  final namespace = native_vm.WasmVm.allocateFunctionRefNamespace();
  final vm = native_vm.WasmVm(
    functions: <native_runtime.RuntimeFunction>[
      native_runtime.HostRuntimeFunction(
        type: type,
        declaredTypeIndex: 0,
        runtimeTypeDepth: 0,
        callback: callback,
      ),
    ],
    types: const <native_module.WasmFunctionType>[type],
    tagTypes: const <native_module.WasmFunctionType>[],
    tagNominalTypeKeys: const <String>[],
    tables: const [],
    memories: const [],
    globals: const [],
    functionRefNamespace: namespace,
    memory64ByIndex: const <bool>[],
    table64ByIndex: const <bool>[],
    dataSegments: const <Uint8List?>[],
    elementSegments: const <List<int?>?>[],
    elementSegmentRefTypeCodes: const <int>[],
  );
  return (
    vm: vm,
    reference: native_vm.WasmVm.functionRefIdFor(
      namespace: namespace,
      functionIndex: 0,
    ),
  );
}
