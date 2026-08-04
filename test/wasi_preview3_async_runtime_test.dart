import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

void main() {
  group('WASI Preview3 async component runtime', () {
    test('executes task.return followed by callback EXIT', () async {
      final component = await _compileComponentWat(
        'async_exit',
        _asyncExitCommandWat,
      );

      final result = await WASIPreview3CommandRunner(
        WASIPreview3ComponentHost(),
      ).run(component);

      expect(result.exitCode, 0);
    });

    test('resumes callback after YIELD and then exits', () async {
      final component = await _compileComponentWat(
        'async_yield',
        _asyncYieldCommandWat,
      );

      final result = await WASIPreview3CommandRunner(
        WASIPreview3ComponentHost(),
      ).run(component);

      expect(result.exitCode, 0);
    });

    test('holds async lift while backpressure is active', () async {
      final component = await _compileComponentWat(
        'async_backpressure',
        _asyncExitCommandWat,
      );
      final host = WASIPreview3ComponentHost();
      final backpressure =
          host.componentHost.canonicalHost.asyncHost.backpressure;
      backpressure.increment();
      var completed = false;
      final pending = WASIPreview3CommandRunner(host).run(component)
        ..then((_) {
          completed = true;
        });

      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      backpressure.decrement();
      final result = await pending;
      expect(result.exitCode, 0);
      expect(completed, isTrue);
    });

    test('resumes WAIT after a pending async lower subtask returns', () async {
      final component = await _compileComponentWat(
        'async_wait',
        _asyncWaitCommandWat,
      );

      final result = await WASIPreview3CommandRunner(
        WASIPreview3ComponentHost(),
      ).run(component);

      expect(result.exitCode, 0);
    });

    test('propagates subtask.cancel to a pending async lower task', () async {
      final component = await _compileComponentWat(
        'async_lower_cancel',
        _asyncLowerCancelCommandWat,
      );

      final result = await WASIPreview3CommandRunner(
        WASIPreview3ComponentHost(),
      ).run(component);

      expect(result.exitCode, 0);
    });

    test(
      'suspends a stackful async lift for synchronous stream cancellation',
      () async {
        final component = await _compileComponentWat(
          'stackful_sync_stream_cancel',
          _stackfulSyncStreamCancelCommandWat,
        );

        final result = await WASIPreview3CommandRunner(
          WASIPreview3ComponentHost(),
        ).run(component);

        expect(result.exitCode, 0);
      },
    );

    test('suspends a stackful async lift in waitable-set.wait', () async {
      final component = await _compileComponentWat(
        'stackful_waitable_set_wait',
        _stackfulWaitableSetWaitCommandWat,
      );

      final result = await WASIPreview3CommandRunner(
        WASIPreview3ComponentHost(),
      ).run(component);

      expect(result.exitCode, 0);
    });

    test(
      'stores a multi-value task.return through an indirect async lower',
      () async {
        final component = await _compileComponentWat(
          'async_multi_value',
          _asyncMultiValueCommandWat,
        );

        final result = await WASIPreview3CommandRunner(
          WASIPreview3ComponentHost(),
        ).run(component);

        expect(result.exitCode, 0);
      },
    );

    test(
      'maps function-scoped async values to canonical type bindings',
      () async {
        final component = await _compileComponentWat(
          'scoped_async_bindings',
          _scopedAsyncBindingsWat,
        );
        final plan = WASIPreview3ComponentHost().prepareComponent(component);

        expect(plan.canBindWithAdapters, isTrue);
        expect(
          plan.componentPlan.asyncValueBindings.map(
            (binding) => binding.componentTypeIndex,
          ),
          [5, 6],
        );
        final lower = plan.adapterPlans.single;
        expect(
          lower.result!.flatLayout!.fields.map(
            (field) => field.value.asyncTypeIndex,
          ),
          [6, 5],
        );
      },
    );

    test(
      'derives aliased HTTP future bindings for every canonical operation',
      () async {
        final component = await _compileComponentWat(
          'aliased_http_future_bindings',
          _aliasedHttpFutureBindingsWat,
        );
        final host = WASIPreview3ComponentHost();
        final plan = host.prepareComponent(component);

        expect(plan.canBind, isTrue);
        expect(plan.bindingErrors, isEmpty);
        expect(
          plan.componentPlan.asyncValueBindings.map(
            (binding) => binding.componentTypeIndex,
          ),
          [6, 8],
        );
        expect(
          plan.componentPlan.asyncValueBindings.every(
            (binding) => binding.memoryLayout != null,
          ),
          isTrue,
        );
        expect(
          component.canonicalDefinitions.map((definition) => definition.kind),
          [
            for (var index = 0; index < 2; index++) ...[
              WasmComponentCanonicalKind.futureCancelWrite,
              WasmComponentCanonicalKind.futureCancelRead,
              WasmComponentCanonicalKind.futureDropWritable,
              WasmComponentCanonicalKind.futureDropReadable,
              WasmComponentCanonicalKind.futureNew,
              WasmComponentCanonicalKind.futureWrite,
              WasmComponentCanonicalKind.futureRead,
            ],
          ],
        );
        expect(plan.bind().asyncValueBindings, hasLength(2));
      },
    );
  });
}

Future<WasmComponent> _compileComponentWat(String name, String source) async {
  final directory = await Directory.systemTemp.createTemp('wasd_wasip3_async_');
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

const String _asyncExitCommandWat = r'''
(component
  (core module $main
    (import "" "task.return" (func $task_return (param i32)))
    (func (export "run") (result i32)
      i32.const 0
      call $task_return
      i32.const 0)
    (func (export "callback") (param i32 i32 i32) (result i32)
      unreachable))

  (canon task.return (result (result)) (core func $task_return))
  (core instance $builtins
    (export "task.return" (func $task_return)))
  (core instance $main_i
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main_i "run" (core func $run_core))
  (alias core export $main_i "callback" (core func $callback_core))

  (func $run async (result (result))
    (canon lift (core func $run_core)
      async (callback $callback_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run_instance))
)
''';

const String _asyncYieldCommandWat = r'''
(component
  (core module $main
    (import "" "task.return" (func $task_return (param i32)))
    (func (export "run") (result i32)
      i32.const 0
      call $task_return
      i32.const 1)
    (func (export "callback") (param i32 i32 i32) (result i32)
      local.get 0
      if
        unreachable
      end
      local.get 1
      if
        unreachable
      end
      local.get 2
      if
        unreachable
      end
      i32.const 0))

  (canon task.return (result (result)) (core func $task_return))
  (core instance $builtins
    (export "task.return" (func $task_return)))
  (core instance $main_i
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main_i "run" (core func $run_core))
  (alias core export $main_i "callback" (core func $callback_core))

  (func $run async (result (result))
    (canon lift (core func $run_core)
      async (callback $callback_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run_instance))
)
''';

const String _asyncWaitCommandWat = r'''
(component
  (type $wait_for_ty (func async (param "duration" u64)))
  (type $clock_ty (instance
    (export "wait-for" (func (type $wait_for_ty)))))
  (import "wasi:clocks/monotonic-clock@0.3.0"
    (instance $clock (type $clock_ty)))
  (alias export $clock "wait-for" (func $wait_for))
  (core func $wait_for_core (canon lower (func $wait_for) async))

  (core module $main
    (import "" "wait-for" (func $wait_for (param i64) (result i32)))
    (import "" "task.return" (func $task_return (param i32)))
    (import "" "subtask.drop" (func $subtask_drop (param i32)))
    (import "" "waitable.join" (func $waitable_join (param i32 i32)))
    (import "" "waitable-set.new" (func $waitable_set_new (result i32)))
    (import "" "waitable-set.drop" (func $waitable_set_drop (param i32)))
    (global $subtask (mut i32) (i32.const 0))
    (global $waitable_set (mut i32) (i32.const 0))

    (func (export "run") (result i32)
      (local $packed i32)
      i64.const 1000000
      call $wait_for
      local.tee $packed
      i32.const 15
      i32.and
      i32.const 1
      i32.ne
      if
        unreachable
      end
      local.get $packed
      i32.const 4
      i32.shr_u
      global.set $subtask
      call $waitable_set_new
      global.set $waitable_set
      global.get $subtask
      global.get $waitable_set
      call $waitable_join
      global.get $waitable_set
      i32.const 4
      i32.shl
      i32.const 2
      i32.or)

    (func (export "callback")
      (param $event_code i32)
      (param $index i32)
      (param $payload i32)
      (result i32)
      local.get $event_code
      i32.const 1
      i32.ne
      if
        unreachable
      end
      local.get $index
      global.get $subtask
      i32.ne
      if
        unreachable
      end
      local.get $payload
      i32.const 2
      i32.ne
      if
        unreachable
      end
      local.get $index
      i32.const 0
      call $waitable_join
      local.get $index
      call $subtask_drop
      global.get $waitable_set
      call $waitable_set_drop
      i32.const 0
      call $task_return
      i32.const 0))

  (canon task.return (result (result)) (core func $task_return))
  (canon subtask.drop (core func $subtask_drop))
  (canon waitable.join (core func $waitable_join))
  (canon waitable-set.new (core func $waitable_set_new))
  (canon waitable-set.drop (core func $waitable_set_drop))
  (core instance $builtins
    (export "wait-for" (func $wait_for_core))
    (export "task.return" (func $task_return))
    (export "subtask.drop" (func $subtask_drop))
    (export "waitable.join" (func $waitable_join))
    (export "waitable-set.new" (func $waitable_set_new))
    (export "waitable-set.drop" (func $waitable_set_drop)))
  (core instance $main_i
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main_i "run" (core func $run_core))
  (alias core export $main_i "callback" (core func $callback_core))

  (func $run async (result (result))
    (canon lift (core func $run_core)
      async (callback $callback_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run_instance))
)
''';

const String _asyncLowerCancelCommandWat = r'''
(component
  (type $wait_for_ty (func async (param "duration" u64)))
  (type $clock_ty (instance
    (export "wait-for" (func (type $wait_for_ty)))))
  (import "wasi:clocks/monotonic-clock@0.3.0"
    (instance $clock (type $clock_ty)))
  (alias export $clock "wait-for" (func $wait_for))
  (core func $wait_for_core (canon lower (func $wait_for) async))

  (core module $main
    (import "" "wait-for" (func $wait_for (param i64) (result i32)))
    (import "" "subtask.cancel"
      (func $subtask_cancel (param i32) (result i32)))
    (import "" "task.return" (func $task_return (param i32)))

    (func (export "run") (result i32)
      (local $subtask i32)
      i64.const 100000000
      call $wait_for
      i32.const 4
      i32.shr_u
      local.set $subtask
      local.get $subtask
      call $subtask_cancel
      i32.const 4
      i32.ne
      if
        unreachable
      end
      i32.const 0
      call $task_return
      i32.const 0)

    (func (export "callback") (param i32 i32 i32) (result i32)
      i32.const 0))

  (canon subtask.cancel (core func $subtask_cancel))
  (canon task.return (result (result)) (core func $task_return))
  (core instance $builtins
    (export "wait-for" (func $wait_for_core))
    (export "subtask.cancel" (func $subtask_cancel))
    (export "task.return" (func $task_return)))
  (core instance $main_i
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main_i "run" (core func $run_core))
  (alias core export $main_i "callback" (core func $callback_core))

  (func $run async (result (result))
    (canon lift (core func $run_core)
      async (callback $callback_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run_instance))
)
''';

const String _stackfulSyncStreamCancelCommandWat = r'''
(component
  (core module $memory_module
    (memory (export "mem") 1))
  (core instance $memory (instantiate $memory_module))
  (alias core export $memory "mem" (core memory $mem))

  (core module $main
    (import "" "mem" (memory 1))
    (import "" "stream.new" (func $stream_new (result i64)))
    (import "" "stream.write"
      (func $stream_write (param i32 i32 i32) (result i32)))
    (import "" "stream.cancel-write"
      (func $stream_cancel_write (param i32) (result i32)))
    (import "" "stream.drop-readable"
      (func $stream_drop_readable (param i32)))
    (import "" "stream.drop-writable"
      (func $stream_drop_writable (param i32)))

    (func (export "run") (result i32)
      (local $ends i64)
      (local $readable i32)
      (local $writable i32)

      call $stream_new
      local.tee $ends
      i32.wrap_i64
      local.set $readable
      local.get $ends
      i64.const 32
      i64.shr_u
      i32.wrap_i64
      local.set $writable

      i32.const 16
      i32.const 0x01020304
      i32.store
      local.get $writable
      i32.const 16
      i32.const 4
      call $stream_write
      i32.const -1
      i32.ne
      if
        unreachable
      end

      local.get $writable
      call $stream_cancel_write
      i32.const 2
      i32.ne
      if
        unreachable
      end

      local.get $writable
      i32.const 16
      i32.const 4
      call $stream_write
      i32.const -1
      i32.ne
      if
        unreachable
      end

      local.get $writable
      call $stream_cancel_write
      i32.const 2
      i32.ne
      if
        unreachable
      end

      local.get $readable
      call $stream_drop_readable
      local.get $writable
      call $stream_drop_writable
      i32.const 0))

  (type $bytes (stream u8))
  (canon stream.new $bytes (core func $stream_new))
  (canon stream.write $bytes async (memory $mem) (core func $stream_write))
  (canon stream.cancel-write $bytes (core func $stream_cancel_write))
  (canon stream.drop-readable $bytes (core func $stream_drop_readable))
  (canon stream.drop-writable $bytes (core func $stream_drop_writable))
  (core instance $builtins
    (export "mem" (memory $mem))
    (export "stream.new" (func $stream_new))
    (export "stream.write" (func $stream_write))
    (export "stream.cancel-write" (func $stream_cancel_write))
    (export "stream.drop-readable" (func $stream_drop_readable))
    (export "stream.drop-writable" (func $stream_drop_writable)))
  (core instance $main_i
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main_i "run" (core func $run_core))

  (func $run async (result (result))
    (canon lift (core func $run_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run_instance))
)
''';

const String _stackfulWaitableSetWaitCommandWat = r'''
(component
  (type $wait_for_ty (func async (param "duration" u64)))
  (type $clock_ty (instance
    (export "wait-for" (func (type $wait_for_ty)))))
  (import "wasi:clocks/monotonic-clock@0.3.0"
    (instance $clock (type $clock_ty)))
  (alias export $clock "wait-for" (func $wait_for))

  (core module $memory_module
    (memory (export "mem") 1))
  (core instance $memory (instantiate $memory_module))
  (alias core export $memory "mem" (core memory $mem))
  (core func $wait_for_core (canon lower (func $wait_for) async))

  (core module $main
    (import "" "mem" (memory 1))
    (import "" "wait-for" (func $wait_for (param i64) (result i32)))
    (import "" "subtask.drop" (func $subtask_drop (param i32)))
    (import "" "waitable.join" (func $waitable_join (param i32 i32)))
    (import "" "waitable-set.new"
      (func $waitable_set_new (result i32)))
    (import "" "waitable-set.wait"
      (func $waitable_set_wait (param i32 i32) (result i32)))
    (import "" "waitable-set.drop"
      (func $waitable_set_drop (param i32)))

    (func (export "run") (result i32)
      (local $packed i32)
      (local $subtask i32)
      (local $waitable_set i32)

      i64.const 1000000
      call $wait_for
      local.tee $packed
      i32.const 15
      i32.and
      i32.const 1
      i32.ne
      if
        unreachable
      end
      local.get $packed
      i32.const 4
      i32.shr_u
      local.set $subtask

      call $waitable_set_new
      local.set $waitable_set
      local.get $subtask
      local.get $waitable_set
      call $waitable_join

      local.get $waitable_set
      i32.const 0
      call $waitable_set_wait
      i32.const 1
      i32.ne
      if
        unreachable
      end
      i32.const 0
      i32.load
      local.get $subtask
      i32.ne
      if
        unreachable
      end
      i32.const 4
      i32.load
      i32.const 2
      i32.ne
      if
        unreachable
      end

      local.get $subtask
      i32.const 0
      call $waitable_join
      local.get $subtask
      call $subtask_drop
      local.get $waitable_set
      call $waitable_set_drop
      i32.const 0))

  (canon subtask.drop (core func $subtask_drop))
  (canon waitable.join (core func $waitable_join))
  (canon waitable-set.new (core func $waitable_set_new))
  (canon waitable-set.wait (memory $mem) (core func $waitable_set_wait))
  (canon waitable-set.drop (core func $waitable_set_drop))
  (core instance $builtins
    (export "mem" (memory $mem))
    (export "wait-for" (func $wait_for_core))
    (export "subtask.drop" (func $subtask_drop))
    (export "waitable.join" (func $waitable_join))
    (export "waitable-set.new" (func $waitable_set_new))
    (export "waitable-set.wait" (func $waitable_set_wait))
    (export "waitable-set.drop" (func $waitable_set_drop)))
  (core instance $main_i
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main_i "run" (core func $run_core))

  (func $run async (result (result))
    (canon lift (core func $run_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run_instance))
)
''';

const String _asyncMultiValueCommandWat = r'''
(component
  (core module $memory_module
    (memory (export "mem") 1))
  (core instance $memory (instantiate $memory_module))
  (alias core export $memory "mem" (core memory $mem))

  (core module $pair_module
    (import "" "task.return" (func $task_return (param i32 i64)))
    (func (export "pair") (result i32)
      i32.const 7
      i64.const 9
      call $task_return
      i32.const 0)
    (func (export "callback") (param i32 i32 i32) (result i32)
      unreachable))
  (canon task.return (result (tuple u32 u64)) (core func $pair_task_return))
  (core instance $pair_builtins
    (export "task.return" (func $pair_task_return)))
  (core instance $pair_i
    (instantiate $pair_module (with "" (instance $pair_builtins))))
  (alias core export $pair_i "pair" (core func $pair_core))
  (alias core export $pair_i "callback" (core func $pair_callback))
  (func $pair async (result (tuple u32 u64))
    (canon lift (core func $pair_core)
      async (callback $pair_callback)))
  (core func $pair_lower
    (canon lower (func $pair) async (memory $mem)))

  (core module $main
    (import "" "mem" (memory 1))
    (import "" "pair" (func $pair (param i32) (result i32)))
    (import "" "task.return" (func $task_return (param i32)))
    (import "" "subtask.drop" (func $subtask_drop (param i32)))
    (import "" "waitable.join" (func $waitable_join (param i32 i32)))
    (import "" "waitable-set.new" (func $waitable_set_new (result i32)))
    (import "" "waitable-set.drop" (func $waitable_set_drop (param i32)))
    (global $subtask (mut i32) (i32.const 0))
    (global $waitable_set (mut i32) (i32.const 0))

    (func (export "run") (result i32)
      (local $packed i32)
      i32.const 32
      call $pair
      local.tee $packed
      i32.const 15
      i32.and
      i32.const 1
      i32.ne
      if
        unreachable
      end
      local.get $packed
      i32.const 4
      i32.shr_u
      global.set $subtask
      call $waitable_set_new
      global.set $waitable_set
      global.get $subtask
      global.get $waitable_set
      call $waitable_join
      global.get $waitable_set
      i32.const 4
      i32.shl
      i32.const 2
      i32.or)

    (func (export "callback")
      (param $event_code i32)
      (param $index i32)
      (param $payload i32)
      (result i32)
      local.get $event_code
      i32.const 1
      i32.ne
      if
        unreachable
      end
      local.get $index
      global.get $subtask
      i32.ne
      if
        unreachable
      end
      local.get $payload
      i32.const 2
      i32.ne
      if
        unreachable
      end
      i32.const 32
      i32.load
      i32.const 7
      i32.ne
      if
        unreachable
      end
      i32.const 40
      i64.load
      i64.const 9
      i64.ne
      if
        unreachable
      end
      local.get $index
      i32.const 0
      call $waitable_join
      local.get $index
      call $subtask_drop
      global.get $waitable_set
      call $waitable_set_drop
      i32.const 0
      call $task_return
      i32.const 0))

  (canon task.return (result (result)) (core func $run_task_return))
  (canon subtask.drop (core func $subtask_drop))
  (canon waitable.join (core func $waitable_join))
  (canon waitable-set.new (core func $waitable_set_new))
  (canon waitable-set.drop (core func $waitable_set_drop))
  (core instance $builtins
    (export "mem" (memory $mem))
    (export "pair" (func $pair_lower))
    (export "task.return" (func $run_task_return))
    (export "subtask.drop" (func $subtask_drop))
    (export "waitable.join" (func $waitable_join))
    (export "waitable-set.new" (func $waitable_set_new))
    (export "waitable-set.drop" (func $waitable_set_drop)))
  (core instance $main_i
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main_i "run" (core func $run_core))
  (alias core export $main_i "callback" (core func $run_callback))

  (func $run async (result (result))
    (canon lift (core func $run_core)
      async (callback $run_callback)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run_instance))
)
''';

const String _scopedAsyncBindingsWat = r'''
(component
  (type $types-ty
    (instance
      (type (enum "io" "pipe"))
      (export "error-code" (type (eq 0)))))
  (import "types" (instance $types (type $types-ty)))
  (alias export $types "error-code" (type $error-code))

  (type $stdin-ty
    (instance
      (alias outer 1 $error-code (type))
      (export "error-code" (type (eq 0)))
      (type (stream u8))
      (type (result (error 1)))
      (type (future 3))
      (type (tuple 2 4))
      (type (func (result 5)))
      (export "read-via-stream" (func (type 6)))))
  (import "stdin" (instance $stdin (type $stdin-ty)))

  (alias export $types "error-code" (type $root-error-code))
  (type $future-result (result (error $root-error-code)))
  (type $future (future $future-result))
  (core func $future-new (canon future.new $future))
  (type $stream (stream u8))
  (core func $stream-new (canon stream.new $stream))

  (core module $memory-module (memory (export "memory") 1))
  (core instance $memory-instance (instantiate $memory-module))
  (alias core export $memory-instance "memory" (core memory $memory))
  (alias export $stdin "read-via-stream" (func $read-via-stream))
  (core func $read-via-stream-core
    (canon lower (func $read-via-stream) (memory $memory)))
)
''';

const String _aliasedHttpFutureBindingsWat = r'''
(component
  (type $http-ty
    (instance
      (export "trailers" (type (sub resource)))
      (type (record (field "message" string)))
      (export "error-payload" (type (eq 1)))
      (type (variant (case "timeout") (case "failure" 2)))
      (export "error-code" (type (eq 3)))
      (type (own 0))
      (type (option 5))
      (type (result 6 (error 4)))
      (type (future 7))
      (type (result (error 4)))
      (type (future 9))
      (type (func (result 8)))
      (export "trailers-future" (func (type 11)))
      (type (func (result 10)))
      (export "unit-future" (func (type 12)))))
  (import "http" (instance $http (type $http-ty)))

  (core module $memory-module
    (memory (export "memory") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      i32.const 0))
  (core instance $memory-instance (instantiate $memory-module))
  (alias core export $memory-instance "memory" (core memory $memory))
  (alias core export $memory-instance "realloc" (core func $realloc))

  (alias export $http "error-code" (type $error-code))
  (alias export $http "trailers" (type $trailers))
  (type $own-trailers (own $trailers))
  (type $maybe-trailers (option $own-trailers))
  (type $trailers-result (result $maybe-trailers (error $error-code)))
  (type $trailers-future (future $trailers-result))
  (core func $trailers-future-cancel-write
    (canon future.cancel-write $trailers-future))
  (core func $trailers-future-cancel-read
    (canon future.cancel-read $trailers-future))
  (core func $trailers-future-drop-writable
    (canon future.drop-writable $trailers-future))
  (core func $trailers-future-drop-readable
    (canon future.drop-readable $trailers-future))
  (core func $trailers-future-new (canon future.new $trailers-future))
  (core func $trailers-future-write
    (canon future.write $trailers-future
      (memory $memory) string-encoding=utf8 async))
  (core func $trailers-future-read
    (canon future.read $trailers-future
      (memory $memory) (realloc $realloc) string-encoding=utf8 async))

  (type $unit-result (result (error $error-code)))
  (type $unit-future (future $unit-result))
  (core func $unit-future-cancel-write
    (canon future.cancel-write $unit-future))
  (core func $unit-future-cancel-read
    (canon future.cancel-read $unit-future))
  (core func $unit-future-drop-writable
    (canon future.drop-writable $unit-future))
  (core func $unit-future-drop-readable
    (canon future.drop-readable $unit-future))
  (core func $unit-future-new (canon future.new $unit-future))
  (core func $unit-future-write
    (canon future.write $unit-future
      (memory $memory) string-encoding=utf8 async))
  (core func $unit-future-read
    (canon future.read $unit-future
      (memory $memory) (realloc $realloc) string-encoding=utf8 async))

  (alias export $http "trailers-future" (func $trailers-future-func))
  (alias export $http "unit-future" (func $unit-future-func))
)
''';
