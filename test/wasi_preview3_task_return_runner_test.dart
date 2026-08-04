import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

void main() {
  group('WASI Preview3 task.return runner ABI', () {
    test(
      'resolves nested types in an imported instance export scope',
      () async {
        final component = await _compileComponentWat(
          'imported_instance_type_scope',
          _importedInstanceTypeScopeWat,
        );

        final plan = componentCanonicalAdapterPlans(component).single;

        expect(plan.result!.flatLength, 4);
      },
    );

    test('keeps a 16-scalar result flat when memory is present', () async {
      final component = await _compileComponentWat(
        'task_return_16_flat',
        _flatTaskReturnWat(payloadFields: 15),
      );

      final result = await WASIPreview3CommandRunner(
        WASIPreview3ComponentHost(),
      ).run(component);

      expect(result.exitCode, 0);
    });

    test('loads a 17-scalar result through its result pointer', () async {
      final component = await _compileComponentWat(
        'task_return_17_indirect',
        _flatTaskReturnWat(payloadFields: 16),
      );

      final result = await WASIPreview3CommandRunner(
        WASIPreview3ComponentHost(),
      ).run(component);

      expect(result.exitCode, 0);
    });

    test('lifts a flat string result exactly once', () async {
      final component = await _compileComponentWat(
        'task_return_string',
        _stringTaskReturnWat,
      );

      final result = await WASIPreview3CommandRunner(
        WASIPreview3ComponentHost(),
      ).run(component);

      expect(result.exitCode, 0);
    });
  });
}

Future<WasmComponent> _compileComponentWat(String name, String source) async {
  final directory = await Directory.systemTemp.createTemp(
    'wasd_wasip3_task_return_',
  );
  addTearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
  final wat = File('${directory.path}/$name.wat');
  final wasm = File('${directory.path}/$name.wasm');
  await wat.writeAsString(source);
  final wasmTools = File(
    '.toolchains/bin/${Platform.isWindows ? 'wasm-tools.exe' : 'wasm-tools'}',
  );
  if (!wasmTools.existsSync()) {
    fail('Missing wasm-tools at ${wasmTools.path}.');
  }
  final parse = await Process.run(wasmTools.path, <String>[
    'parse',
    wat.path,
    '-o',
    wasm.path,
  ]);
  expect(parse.exitCode, 0, reason: '${parse.stdout}\n${parse.stderr}');
  final validation = await Process.run(wasmTools.path, <String>[
    'validate',
    '--features',
    'component-model',
    wasm.path,
  ]);
  expect(
    validation.exitCode,
    0,
    reason: '${validation.stdout}\n${validation.stderr}',
  );
  return WasmComponent.decode(await wasm.readAsBytes());
}

String _flatTaskReturnWat({required int payloadFields}) {
  final flatLength = payloadFields + 1;
  final coreParams = flatLength > 16
      ? 'i32'
      : List<String>.filled(flatLength, 'i32').join(' ');
  final coreArgs = flatLength > 16
      ? 'i32.const 0'
      : List<String>.filled(flatLength, 'i32.const 0').join('\n      ');
  return _flatTaskReturnTemplate
      .replaceFirst(
        ';; PAYLOAD_TYPES',
        List<String>.filled(payloadFields, 'u32').join(' '),
      )
      .replaceFirst(';; CORE_PARAMS', coreParams)
      .replaceFirst(';; CORE_ARGS', coreArgs);
}

const String _flatTaskReturnTemplate = r'''
(component
  (core module $memory-module
    (memory (export "memory") 1))
  (core instance $memory-instance (instantiate $memory-module))
  (alias core export $memory-instance "memory" (core memory $memory))

  (type $payload (tuple ;; PAYLOAD_TYPES))
  (type $run-result (result $payload))
  (core module $main
    (import "" "memory" (memory 1))
    (import "" "task.return" (func $task-return (param ;; CORE_PARAMS)))
    (func (export "run") (result i32)
      ;; CORE_ARGS
      call $task-return
      i32.const 0)
    (func (export "callback") (param i32 i32 i32) (result i32)
      unreachable))

  (canon task.return (result $run-result) (memory $memory)
    (core func $task-return))
  (core instance $builtins
    (export "memory" (memory $memory))
    (export "task.return" (func $task-return)))
  (core instance $main-instance
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main-instance "run" (core func $run-core))
  (alias core export $main-instance "callback" (core func $callback-core))

  (func $run async (result $run-result)
    (canon lift (core func $run-core) (memory $memory)
      async (callback $callback-core)))
  (instance $run-instance (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run-instance)))
''';

const String _stringTaskReturnWat = r'''
(component
  (core module $memory-module
    (memory (export "memory") 1))
  (core instance $memory-instance (instantiate $memory-module))
  (alias core export $memory-instance "memory" (core memory $memory))

  (type $run-result (result string))
  (core module $main
    (import "" "memory" (memory 1))
    (import "" "task.return" (func $task-return (param i32 i32 i32)))
    (data (i32.const 32) "ok")
    (func (export "run") (result i32)
      i32.const 0
      i32.const 32
      i32.const 2
      call $task-return
      i32.const 0)
    (func (export "callback") (param i32 i32 i32) (result i32)
      unreachable))

  (canon task.return (result $run-result) (memory $memory)
    (core func $task-return))
  (core instance $builtins
    (export "memory" (memory $memory))
    (export "task.return" (func $task-return)))
  (core instance $main-instance
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main-instance "run" (core func $run-core))
  (alias core export $main-instance "callback" (core func $callback-core))

  (func $run async (result $run-result)
    (canon lift (core func $run-core) (memory $memory)
      async (callback $callback-core)))
  (instance $run-instance (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run-instance)))
''';

const String _importedInstanceTypeScopeWat = r'''
(component
  (type $types (instance
    (type $element (tuple u32 u64))
    (type $payload (option $element))
    (export "payload" (type (eq $payload)))))
  (import "types" (instance $types-instance (type $types)))
  (alias export $types-instance "payload" (type $payload))
  (type $run-result (result $payload))

  (core module $main
    (memory (export "memory") 1)
    (func (export "run") (result i32)
      i32.const 0))
  (core instance $main-instance (instantiate $main))
  (alias core export $main-instance "memory" (core memory $memory))
  (alias core export $main-instance "run" (core func $run-core))

  (type $run-type (func (result $run-result)))
  (func $run (type $run-type)
    (canon lift (core func $run-core) (memory $memory)))
  (export "run" (func $run)))
''';
