@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/preview2/component_runner.dart';
import 'package:wasd/src/wasi/component/unicode_scalar.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/execution_error.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart' hide Exception;

void main() {
  group('execution trap origin', () {
    for (final duringStart in [true, false]) {
      test('unreachable has a dedicated cause (start: $duringStart)', () async {
        final component = await _encodeComponent(
          duringStart
              ? '(component (core module \$m (func \$f unreachable) (start \$f)) '
                    '(core instance (instantiate \$m)))'
              : '(component (core module \$m (func (export "trap") unreachable)) '
                    '(core instance \$i (instantiate \$m)) '
                    '(func (export "trap") (canon lift (core func \$i "trap"))))',
        );
        final host = WASIComponentHost();
        Object? observed;
        await host.table.runScoped(() async {
          final runtime = WASIComponentNativeRuntime.component(
            component: component,
            host: host,
          );
          try {
            if (duringStart) {
              await runtime.initialize();
            } else {
              await runtime.invokeExport('trap', []);
            }
          } catch (error) {
            observed = error;
          }
        });
        expect(observed, isA<WasmExecutionErrorContext>());
        while (observed is WasmExecutionErrorContext) {
          observed = (observed as WasmExecutionErrorContext).cause;
        }
        expect(observed.runtimeType.toString(), 'WasmUnreachableTrap');
        expect(observed, isA<StateError>());
        expect(host.table.activeCount, 0);
      });
    }

    test('host StateError with matching text retains its origin', () async {
      final component = await _encodeComponent('''
        (component
          (import "notify" (func \$notify))
          (core func \$notify (canon lower (func \$notify)))
          (core module \$m
            (import "" "notify" (func \$notify))
            (func (export "trap") call \$notify))
          (core instance \$i (instantiate \$m
            (with "" (instance (export "notify" (func \$notify))))))
          (func (export "trap") (canon lift (core func \$i "trap"))))
      ''');
      final host = WASIComponentHost();
      Object? observed;
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
          imports: {'notify': (_) => throw StateError('unreachable trap')},
        );
        try {
          await runtime.invokeExport('trap', []);
        } catch (error) {
          observed = error;
        }
      });
      expect(observed, isA<WasmExecutionErrorContext>());
      while (observed is WasmExecutionErrorContext) {
        observed = (observed as WasmExecutionErrorContext).cause;
      }
      expect(observed.runtimeType.toString(), 'StateError');
      expect((observed as StateError).message, 'unreachable trap');
      expect(host.table.activeCount, 0);
    });
  });

  for (final (future, owned) in [
    (false, false),
    (false, true),
    (true, false),
    (true, true),
  ]) {
    test(
      'canonical same-instance ${future ? 'future' : 'stream'} ${owned ? 'owned' : 'numeric'} copy respects the fixed ABI restriction',
      () async {
        final element = owned ? '(own \$exported)' : 'u32';
        final kind = future ? 'future' : 'stream';
        final count = future ? '' : 'i32.const 1';
        final channel = owned ? '(own \$r)' : 'u32';
        final component = await _encodeComponent('''
(component
  (core module \$memory (memory (export "mem") 1)) (core instance \$memory (instantiate \$memory))
  (type \$r (resource (rep i32))) (export \$exported "r" (type \$r)) (type \$s ($kind $channel))
  (core func \$rnew (canon resource.new \$r)) (core func \$rep (canon resource.rep \$r)) (core func \$rdrop (canon resource.drop \$r))
  (core func \$new (canon $kind.new \$s))
  (core func \$read (canon $kind.read \$s async (memory (core memory \$memory "mem"))))
  (core func \$write (canon $kind.write \$s async (memory (core memory \$memory "mem"))))
  (core func \$cancel (canon $kind.cancel-write \$s))
  (core func \$rclose (canon $kind.drop-readable \$s)) (core func \$wclose (canon $kind.drop-writable \$s))
  (core module \$m
    (import "h" "mem" (memory 1)) (import "h" "rnew" (func \$rnew (param i32) (result i32)))
    (import "h" "rep" (func \$rep (param i32) (result i32))) (import "h" "rdrop" (func \$rdrop (param i32)))
    (import "h" "new" (func \$new (result i64))) (import "h" "read" (func \$read (param i32 i32${future ? '' : ' i32'}) (result i32)))
    (import "h" "write" (func \$write (param i32 i32${future ? '' : ' i32'}) (result i32))) (import "h" "cancel" (func \$cancel (param i32) (result i32)))
    (import "h" "rclose" (func \$rclose (param i32))) (import "h" "wclose" (func \$wclose (param i32)))
    (global \$owner (mut i32) (i32.const 0)) (global \$reader (mut i32) (i32.const 0)) (global \$writer (mut i32) (i32.const 0))
    (func (export "start") (result i32) (local \$pair i64)
      call \$new local.tee \$pair i64.const 32 i64.shr_u i32.wrap_i64 global.set \$writer
      i32.const 50 call \$rnew global.set \$owner
      i32.const 16 ${owned ? 'global.get \$owner' : 'i32.const 50'} i32.store
      global.get \$writer i32.const 16 $count call \$write drop local.get \$pair i32.wrap_i64)
    (func (export "read") (param i32) (result i32) local.get 0 global.set \$reader local.get 0 i32.const 32 $count call \$read)
    (func (export "value") (result i32) i32.const 32 i32.load)
    (func (export "owner") (result i32) global.get \$owner call \$rep)
    (func (export "drop-owner") global.get \$owner call \$rdrop)
    (func (export "cancel") (result i32) global.get \$writer call \$cancel)
    (func (export "close") global.get \$reader call \$rclose global.get \$writer call \$wclose))
  (core instance \$h (export "mem" (memory \$memory "mem")) (export "rnew" (func \$rnew)) (export "rep" (func \$rep)) (export "rdrop" (func \$rdrop))
    (export "new" (func \$new)) (export "read" (func \$read)) (export "write" (func \$write)) (export "cancel" (func \$cancel)) (export "rclose" (func \$rclose)) (export "wclose" (func \$wclose)))
  (core instance \$m (instantiate \$m (with "h" (instance \$h))))
  (func (export "start") (result ($kind $element)) (canon lift (core func \$m "start")))
  (func (export "read") (param "channel" ($kind $element)) (result u32) (canon lift (core func \$m "read")))
  (func (export "value") (result u32) (canon lift (core func \$m "value")))
  (func (export "owner") (result u32) (canon lift (core func \$m "owner")))
  (func (export "drop-owner") (canon lift (core func \$m "drop-owner")))
  (func (export "cancel") (result u32) (canon lift (core func \$m "cancel")))
  (func (export "close") (canon lift (core func \$m "close"))))
''');
        expect(component.validate(), isEmpty);
        final host = WASIComponentHost();
        await host.table.runScoped(() async {
          final runtime = WASIComponentNativeRuntime.component(
            component: component,
            host: host,
          );
          final endpoint = await runtime.invokeExport('start', []);
          try {
            if (owned) {
              await expectLater(
                runtime.invokeExport('read', [endpoint]),
                throwsA(
                  predicate<Object>(
                    (error) => error.toString().contains('non-numeric'),
                  ),
                ),
              );
            } else {
              expect(
                await runtime.invokeExport('read', [endpoint]),
                future ? 0 : 16,
              );
              expect(await runtime.invokeExport('value', []), 50);
            }
            expect(await runtime.invokeExport('owner', []), 50);
            await runtime.invokeExport('drop-owner', []);
          } finally {
            try {
              await runtime.invokeExport('cancel', []);
            } catch (error) {
              if (!owned || !error.toString().contains('non-numeric')) rethrow;
            }
            await runtime.invokeExport('close', []);
          }
        });
        expect(host.table.activeCount, 0);
      },
    );
  }

  test(
    'canonical component error-context carriers are released after each internal call',
    () async {
      final component = await _encodeComponent(r'''
(component
  (component $producer
    (core module $memory (memory (export "mem") 1) (data (i32.const 0) "kept"))
    (core instance $memory (instantiate $memory))
    (core func $new (canon error-context.new (memory (core memory $memory "mem"))))
    (core func $drop (canon error-context.drop))
    (core module $m
      (import "h" "new" (func $new (param i32 i32) (result i32)))
      (import "h" "drop" (func $drop (param i32)))
      (global $source (mut i32) (i32.const 0))
      (func (export "make") (result i32) i32.const 0 i32.const 4 call $new global.set $source global.get $source)
      (func (export "drop-source") global.get $source call $drop)
      (func (export "consume") (param i32) local.get 0 call $drop))
    (core instance $h (export "new" (func $new)) (export "drop" (func $drop)))
    (core instance $m (instantiate $m (with "h" (instance $h))))
    (func (export "make") (result error-context) (canon lift (core func $m "make")))
    (func (export "drop-source") (canon lift (core func $m "drop-source")))
    (func (export "consume") (param "error" error-context) (canon lift (core func $m "consume"))))
  (component $consumer
    (import "producer" (instance $p
      (export "make" (func (result error-context)))
      (export "drop-source" (func))
      (export "consume" (func (param "error" error-context)))))
    (core func $make (canon lower (func $p "make")))
    (core func $clear (canon lower (func $p "drop-source")))
    (core func $consume (canon lower (func $p "consume")))
    (core func $drop (canon error-context.drop))
    (core module $m
      (import "h" "make" (func $make (result i32)))
      (import "h" "clear" (func $clear))
      (import "h" "consume" (func $consume (param i32)))
      (import "h" "drop" (func $drop (param i32)))
      (func (export "run") call $make call $drop call $clear)
      (func (export "run-param") (local $copy i32) call $make local.tee $copy call $consume local.get $copy call $drop call $clear))
    (core instance $h (export "make" (func $make)) (export "clear" (func $clear)) (export "consume" (func $consume)) (export "drop" (func $drop)))
    (core instance $m (instantiate $m (with "h" (instance $h))))
    (func (export "run") (canon lift (core func $m "run")))
    (func (export "run-param") (canon lift (core func $m "run-param"))))
  (instance $p (instantiate $producer))
  (instance $c (instantiate $consumer (with "producer" (instance $p))))
  (export "run" (func $c "run")) (export "run-param" (func $c "run-param")))

''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        for (var call = 0; call < 4; call++) {
          for (final function in ['run', 'run-param']) {
            await runtime.invokeExport(function, []);
            expect(
              host.table.activeCount,
              0,
              reason:
                  'no unreachable internal carrier after $function call $call',
            );
          }
        }
      });
      expect(host.table.activeCount, 0);
    },
  );

  test(
    'canonical immediate async lowering failure releases its parameter loans',
    () async {
      final component = await _encodeComponent(_canonicalBorrowCancellation);
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
          imports: {'hold': (args) => 0},
        );
        await expectLater(runtime.invokeExport('begin', []), throwsA(anything));
        await runtime.invokeExport('drop-owner', []);
        expect(await runtime.invokeExport('sum', []), 100);
      });
      expect(host.table.activeCount, 0);
    },
  );

  test(
    'canonical borrow cancellation waits for the host callback to stop using its loan',
    () async {
      final component = await _encodeComponent(_canonicalBorrowCancellation);
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      final hold = Completer<void>();
      var loan = 0;
      var liveAtHostReturn = false;
      await host.table.runScoped(() async {
        late WASIComponentNativeRuntime runtime;
        runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
          imports: {
            'hold': (args) async {
              loan = args.single as int;
              final abandonedOwner = await runtime.invokeExport('make-extra', [
                7,
              ]);
              await hold.future;
              liveAtHostReturn = host.table.contains(loan);
              return abandonedOwner;
            },
          },
        );
        try {
          expect(await runtime.invokeExport('begin', []), 33);
          expect(loan, greaterThan(0));
          expect(
            await runtime.invokeExport('cancel', []),
            wasiComponentSubtaskBlocked,
          );
          await Future<void>.delayed(Duration.zero);
          expect(
            await runtime.invokeExport('poll', []),
            0,
            reason: 'callback still owns the loan',
          );
          await expectLater(
            runtime.invokeExport('drop-owner', []),
            throwsA(anything),
          );
          expect(host.table.contains(loan), isTrue);
          hold.complete();
          for (var retry = 0; retry < 100; retry++) {
            final waitables = [
              for (var h = 1; h <= 32; h++)
                ?host.canonicalHost.subtaskHost.waitableForHandle(h),
            ];
            if (waitables.single.hasPendingEvent) break;
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(liveAtHostReturn, isTrue);
          await expectLater(
            runtime.invokeExport('drop-owner', []),
            throwsA(anything),
          );
          expect(await runtime.invokeExport('poll', []), 1);
          expect(await runtime.invokeExport('event-state', []), 4);
          expect(
            await runtime.invokeExport('sum', []),
            7,
            reason: 'cancelled owned result is discarded exactly once',
          );
          expect(host.table.contains(loan), isFalse);
          await runtime.invokeExport('finish', []);
          await runtime.invokeExport('drop-owner', []);
          expect(await runtime.invokeExport('sum', []), 107);
        } finally {
          if (!hold.isCompleted) hold.complete();
          await Future<void>.delayed(Duration.zero);
        }
      });
      expect(host.table.activeCount, 0);
    },
  );

  test(
    'canonical error-context copies have independent G and host references',
    () async {
      final component = await _encodeComponent(r'''
(component
  (core module $memory
    (memory (export "mem") 1) (data (i32.const 0) "kept")
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) i32.const 64))
  (core instance $memory (instantiate $memory))
  (core func $new (canon error-context.new (memory (core memory $memory "mem"))))
  (core func $debug (canon error-context.debug-message (memory (core memory $memory "mem")) (realloc (core func $memory "realloc"))))
  (core func $drop (canon error-context.drop))
  (core module $m
    (import "h" "mem" (memory 1))
    (import "h" "new" (func $new (param i32 i32) (result i32)))
    (import "h" "debug" (func $debug (param i32 i32)))
    (import "h" "drop" (func $drop (param i32)))
    (global $source (mut i32) (i32.const 0)) (global $copy (mut i32) (i32.const 0))
    (func (export "make") (result i32) i32.const 0 i32.const 4 call $new global.set $source global.get $source)
    (func (export "receive") (param i32) (result i32) local.get 0 global.set $copy local.get 0)
    (func (export "length") (result i32) global.get $copy i32.const 16 call $debug i32.const 20 i32.load)
    (func (export "drop-source") global.get $source call $drop)
    (func (export "drop-copy") global.get $copy call $drop))
  (core instance $h (export "mem" (memory $memory "mem")) (export "new" (func $new)) (export "debug" (func $debug)) (export "drop" (func $drop)))
  (core instance $m (instantiate $m (with "h" (instance $h))))
  (func (export "make") (result error-context) (canon lift (core func $m "make")))
  (func (export "receive") (param "error" error-context) (result u32) (canon lift (core func $m "receive")))
  (func (export "length") (result u32) (canon lift (core func $m "length")))
  (func (export "drop-source") (canon lift (core func $m "drop-source")))
  (func (export "drop-copy") (canon lift (core func $m "drop-copy"))))
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final noise = host.table.defineType<Object>('host noise');
        host.table.insert(noise, Object());
        final first = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        final second = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        final reference = await first.invokeExport('make', []) as int;
        expect(await second.invokeExport('receive', [reference]), 1);
        host.canonicalHost.errorContextHost.drop(reference);
        await first.invokeExport('drop-source', []);
        expect(await second.invokeExport('length', []), 4);
        await second.invokeExport('drop-copy', []);
        await expectLater(second.invokeExport('length', []), throwsA(anything));
      });
      expect(host.table.activeCount, 0);
    },
  );

  group('canonical typed owners', () {
    for (final width in [2, 17]) {
      for (final asynchronous in [false, true]) {
        test(
          '${asynchronous ? 'task.return' : 'lift'} tuple $width transfers through ${width > 16 ? 'indirect' : 'flat'} arguments',
          () async {
            final component = await _encodeComponent(
              _canonicalOwnedTuple(width, asynchronous: asynchronous),
            );
            expect(component.validate(), isEmpty);
            final host = WASIComponentHost();
            await host.table.runScoped(() async {
              final first = WASIComponentNativeRuntime.component(
                component: component,
                host: host,
              );
              final second = WASIComponentNativeRuntime.component(
                component: component,
                host: host,
              );
              final owners = await first.invokeExport('make', []);
              await expectLater(
                second.invokeExport('take', [owners]),
                throwsA(anything),
              );
              expect(await second.invokeExport('hits', []), 0);
              expect(await first.invokeExport('sum', []), 0);
              expect(
                await first.invokeExport('take', [owners]),
                width * (width + 1) ~/ 2,
              );
              expect(
                await first.invokeExport('sum', []),
                width * (width + 1) ~/ 2,
              );
              expect(await first.invokeExport('hits', []), 1);
              await expectLater(
                first.invokeExport('take', [owners]),
                throwsA(anything),
              );
              expect(await first.invokeExport('hits', []), 1);
            });
            expect(host.table.activeCount, 0);
          },
        );
      }
    }
  });

  group('canonical captured resources', () {
    for (final depth in [1, 2]) {
      test(
        'rejects resource outer $depth crossing a component boundary',
        () async {
          final dropper =
              '''
(component \$dropper (alias outer $depth \$r (type \$outer))
  (core func \$drop (canon resource.drop \$outer))
  (func (export "drop") (param "owner" (own \$outer)) (canon lift (core func \$drop))))
''';
          final nested = depth == 1
              ? dropper
              : '''
(component \$wrapper $dropper
  (instance \$dropper (instantiate \$dropper))
  (func (export "drop") (alias export \$dropper "drop")))
''';
          final target = depth == 1 ? 'dropper' : 'wrapper';
          final component = await _encodeComponent('''
(component
  (core module \$state
    (global \$sum (mut i32) (i32.const 0))
    (func (export "dtor") (param i32) global.get \$sum local.get 0 i32.add global.set \$sum)
    (func (export "sum") (result i32) global.get \$sum))
  (core instance \$state (instantiate \$state))
  (type \$r (resource (rep i32) (dtor (core func \$state "dtor"))))
  (export \$exported "r" (type \$r))
  (core func \$new (canon resource.new \$r))
  (func (export "make") (param "rep" u32) (result (own \$exported)) (canon lift (core func \$new)))
  $nested
  (instance \$target (instantiate \$$target))
  (func (export "drop") (alias export \$target "drop"))
  (func (export "sum") (result u32) (canon lift (core func \$state "sum"))))
''');
          expect(component.validate(), isNotEmpty);
          final host = WASIComponentHost();
          await expectLater(
            WASIComponentNativeRuntime.component(
              component: component,
              host: host,
            ).initialize(),
            throwsA(isA<WASIPreview2ComponentExecutionException>()),
          );
          expect(host.table.activeCount, 0);
        },
      );
    }
  });

  test(
    'canonical standard host rejects a manually defined same-name token',
    () async {
      final component = await _encodeComponent(r'''
(component
  (import "wasi:io/streams@0.2.0" (instance $streams
    (export "input-stream" (type $input (sub resource)))))
  (alias export $streams "input-stream" (type $input))
  (core func $drop (canon resource.drop $input))
  (func (export "drop") (param "input" (own $input)) (canon lift (core func $drop))))
''');
      expect(component.validate(), isEmpty);
      final host = WASIPreview2ComponentHost();
      final table = host.componentHost.table;
      await table.runScoped(() async {
        var fakeDrops = 0;
        final fake = table.defineType<Object>(
          'wasi:io/streams@0.2.0.input-stream',
          onDrop: (_) => fakeDrops++,
        );
        final fakeHandle = table.insert(fake, Object());
        final runtime = WASIComponentNativeRuntime.preview2(
          component: component,
          host: host,
        );
        await expectLater(
          runtime.invokeExport('drop', [fakeHandle]),
          throwsStateError,
        );
        expect(fakeDrops, 0);
        expect(table.contains(fakeHandle), isTrue);
        final actual = host.streamsHost.insertInputStream(
          WASIPreview2InputStream(),
        );
        await runtime.invokeExport('drop', [actual]);
        expect(table.contains(actual), isFalse);
        table.drop(fake, fakeHandle);
        expect(fakeDrops, 1);
      });
      expect(table.activeCount, 0);
    },
  );

  group('canonical borrow lifetime', () {
    for (final asynchronous in [false, true]) {
      test(
        asynchronous
            ? 'loan survives callee resolution until subtask delivery'
            : 'failed drop preserves a lent owner until call return',
        () async {
          final component = await _encodeComponent(
            asynchronous ? _canonicalAsyncBorrow : _canonicalSyncBorrow,
          );
          expect(component.validate(), isEmpty);
          final host = WASIComponentHost();
          final hold = Completer<void>();
          final entered = Completer<void>();
          late WASIComponentNativeRuntime runtime;
          await host.table.runScoped(() async {
            runtime = WASIComponentNativeRuntime.component(
              component: component,
              host: host,
              imports: {
                asynchronous ? 'hold' : 'visit': (args) async {
                  expect(args.single, 100);
                  entered.complete();
                  if (asynchronous) {
                    await hold.future;
                  } else {
                    await expectLater(
                      runtime.invokeExport('drop-owner', []),
                      throwsA(anything),
                    );
                    expect(await runtime.invokeExport('sum', []), 0);
                  }
                  return null;
                },
              },
            );
            try {
              expect(
                await runtime.invokeExport('begin', []),
                asynchronous ? 33 : null,
              );
              await entered.future;
              if (asynchronous) {
                await expectLater(
                  runtime.invokeExport('drop-owner', []),
                  throwsA(anything),
                );
                expect(await runtime.invokeExport('sum', []), 0);
                hold.complete();
                var ready = false;
                for (var retry = 0; retry < 100 && !ready; retry++) {
                  final waitables = [
                    for (var h = 1; h <= 64; h++)
                      ?host.canonicalHost.subtaskHost.waitableForHandle(h),
                  ];
                  ready =
                      waitables.length == 1 && waitables.single.hasPendingEvent;
                  if (!ready) {
                    await Future<void>.delayed(const Duration(milliseconds: 1));
                  }
                }
                expect(
                  ready,
                  isTrue,
                  reason: 'callee resolved without delivering the caller event',
                );
                await expectLater(
                  runtime.invokeExport('drop-owner', []),
                  throwsA(anything),
                );
                expect(await runtime.invokeExport('sum', []), 0);
                expect(await runtime.invokeExport('poll', []), 1);
                expect(await runtime.invokeExport('event-index', []), 2);
                expect(await runtime.invokeExport('event-state', []), 2);
                await runtime.invokeExport('finish', []);
              }
              await runtime.invokeExport('drop-owner', []);
              expect(await runtime.invokeExport('sum', []), 100);
            } finally {
              if (!hold.isCompleted) hold.complete();
              await Future<void>.delayed(Duration.zero);
            }
          });
          expect(host.table.activeCount, 0);
        },
      );
    }
  });

  group('canonical implicit threads', () {
    for (final concurrent in [false, true]) {
      test(
        concurrent
            ? 'overlapping callbacks keep their TLS and reuse T'
            : 'callback events expose G and a live T',
        () async {
          final component = await _encodeComponent(_canonicalThreadEvents);
          expect(component.validate(), isEmpty);
          final host = WASIComponentHost();
          final holds = <int, Completer<void>>{};
          final entered = <int, Completer<void>>{};
          final threads = <int>[];
          final pending = <Future<Object?>>[];
          await host.table.runScoped(() async {
            final noiseType = host.table.defineType<Object>('host noise');
            host.table.insert(noiseType, Object());
            final runtime = WASIComponentNativeRuntime.component(
              component: component,
              host: host,
              imports: {
                'hold': (args) {
                  final id = args[0] as int;
                  threads.add(args[1] as int);
                  final hold = holds.putIfAbsent(id, Completer<void>.new);
                  final entry = entered.putIfAbsent(id, Completer<void>.new);
                  if (!entry.isCompleted) entry.complete();
                  return hold.future;
                },
              },
            );
            await runtime.initialize();
            expect(await runtime.invokeExport('seed', []), 1);
            Future<Object?> start(int id) {
              final future = runtime.invokeExport('run', [id]);
              pending.add(future);
              return future;
            }

            Future<void> entry(int id) =>
                entered.putIfAbsent(id, Completer<void>.new).future;
            try {
              final first = start(1);
              await entry(1);
              if (concurrent) {
                final second = start(2);
                await entry(2);
                holds[2]!.complete();
                expect(await second, 2);
                final third = start(3);
                await entry(3);
                holds[3]!.complete();
                expect(await third, 2);
                holds[1]!.complete();
                expect(await first, 1);
                final fourth = start(4);
                await entry(4);
                holds[4]!.complete();
                expect(await fourth, 1);
                expect(threads, [1, 2, 2, 1]);
              } else {
                holds[1]!.complete();
                expect(await first, 1);
                for (final event in <(String, int)>[
                  ('packed', 33),
                  ('wait', 50),
                  ('event', 1),
                  ('index', 2),
                  ('state', 2),
                ]) {
                  expect(
                    await runtime.invokeExport(event.$1, []),
                    event.$2,
                    reason: event.$1,
                  );
                }
                expect(threads, [1]);
              }
            } finally {
              for (final hold in holds.values) {
                if (!hold.isCompleted) hold.complete();
              }
              for (final future in pending) {
                try {
                  await future;
                } catch (_) {}
              }
            }
          });
          expect(host.table.activeCount, 0);
        },
      );
    }
  });

  test(
    'canonical pending stream write transfers two prefixes before event delivery',
    () async {
      final component = await _encodeComponent(_ownStreamAcceptance);
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        try {
          expect(await runtime.invokeExport('open', []), 1);
          expect(
            await runtime.invokeExport('write-status', []),
            wasiComponentAsyncBlocked,
          );
          expect(await runtime.invokeExport('receive', []), 16);
          await runtime.invokeExport('drop-received', []);
          expect(await runtime.invokeExport('sum', []), 50);
          expect(await runtime.invokeExport('second', []), 51);
          expect(await runtime.invokeExport('receive', []), 16);
          await expectLater(
            runtime.invokeExport('second', []),
            throwsA(anything),
          );
          expect(await runtime.invokeExport('cancel', []), 34);
          expect(await runtime.invokeExport('sum', []), 50);
          await runtime.invokeExport('drop-received', []);
          expect(await runtime.invokeExport('sum', []), 101);
        } finally {
          for (final cleanup in [
            'abort-read',
            'cancel',
            'close-reader',
            'close',
          ]) {
            try {
              await runtime.invokeExport(cleanup, []);
            } catch (_) {
              /* Preserve the behavior assertion. */
            }
          }
          await Future<void>.delayed(Duration.zero);
        }
      });
      expect(host.table.activeCount, 0);
    },
  );

  group('canonical async ownership', () {
    for (final scenario in _canonicalOwnershipScenarios) {
      test(scenario.$1, () async {
        final component = await _encodeComponent(scenario.$2);
        expect(component.validate(), isEmpty);
        final host = WASIComponentHost();
        await host.table.runScoped(() async {
          final noiseType = host.table.defineType<Object>('host noise');
          host.table.insert(noiseType, Object());
          final runtime = WASIComponentNativeRuntime.component(
            component: component,
            host: host,
          );
          await runtime.initialize();
          for (final call in scenario.$3) {
            if (call.$3 == 'trap') {
              await expectLater(
                runtime.invokeExport(call.$1, call.$2),
                throwsA(anything),
                reason: call.$1,
              );
            } else {
              expect(
                await runtime.invokeExport(call.$1, call.$2),
                call.$3,
                reason: call.$1,
              );
            }
            await Future<void>.delayed(Duration.zero);
          }
        });
        expect(host.table.activeCount, 0);
      });
    }
  });

  group('instance canonical handles', () {
    test('per-instance', () async {
      final component = await _encodeComponent(r'''
(component
  (component $C
    (type $R (resource (rep i32)))
    (core func $new (canon resource.new $R))
    (core module $M
      (import "canon" "new" (func $new (param i32) (result i32)))
      (func (export "make") (result i32) (call $new (i32.const 0))))
    (core instance $m (instantiate $M
      (with "canon" (instance (export "new" (func $new))))))
    (func (export "make") (result u32) (canon lift (core func $m "make"))))
  (instance $c1 (instantiate $C))
  (instance $c2 (instantiate $C))
  (func (export "make-1") (alias export $c1 "make"))
  (func (export "make-2") (alias export $c2 "make"))
)
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        await runtime.initialize();
        expect(await runtime.invokeExport('make-1', []), 1);
        expect(await runtime.invokeExport('make-1', []), 2);
        expect(await runtime.invokeExport('make-2', []), 1);
        expect(await runtime.invokeExport('make-1', []), 3);
        expect(await runtime.invokeExport('make-2', []), 2);
      });
      expect(host.table.activeCount, 0);
    });
    test('official-lifo', () async {
      final component = await _encodeComponent(r'''
(component
  (type $R (resource (rep i32)))
  (canon resource.new $R (core func $R.resource.new))
  (canon resource.drop $R (core func $R.resource.drop))
  (canon resource.rep $R (core func $R.resource.rep))
  (core module $M
    (import "" "new" (func $new (param i32) (result i32)))
    (import "" "drop" (func $drop (param i32)))
    (import "" "rep" (func $rep (param i32) (result i32)))
    (func (export "run") (result i32)
      (if (i32.ne (i32.const 1) (call $new (i32.const 100))) (then unreachable))
      (if (i32.ne (i32.const 2) (call $new (i32.const 200))) (then unreachable))
      (if (i32.ne (i32.const 3) (call $new (i32.const 300))) (then unreachable))

      (call $drop (i32.const 2))
      (if (i32.ne (i32.const 2) (call $new (i32.const 400))) (then unreachable))
      (if (i32.ne (i32.const 100) (call $rep (i32.const 1))) (then unreachable))
      (if (i32.ne (i32.const 400) (call $rep (i32.const 2))) (then unreachable))
      (if (i32.ne (i32.const 300) (call $rep (i32.const 3))) (then unreachable))

      (call $drop (i32.const 1))
      (call $drop (i32.const 2))
      (call $drop (i32.const 3))
      (if (i32.ne (i32.const 3) (call $new (i32.const 500))) (then unreachable))
      (if (i32.ne (i32.const 2) (call $new (i32.const 600))) (then unreachable))
      (if (i32.ne (i32.const 1) (call $new (i32.const 700))) (then unreachable))
      (if (i32.ne (i32.const 500) (call $rep (i32.const 3))) (then unreachable))
      (if (i32.ne (i32.const 600) (call $rep (i32.const 2))) (then unreachable))
      (if (i32.ne (i32.const 700) (call $rep (i32.const 1))) (then unreachable))

      (if (i32.ne (i32.const 4) (call $new (i32.const 800))) (then unreachable))

      (i32.const 42)
    )
  )
  (core instance $m (instantiate $M (with "" (instance
    (export "new" (func $R.resource.new))
    (export "drop" (func $R.resource.drop))
    (export "rep" (func $R.resource.rep))
  ))))
  (func (export "run") (result u32) (canon lift (core func $m "run")))
)
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        await runtime.initialize();
        expect(await runtime.invokeExport('run', []), 42);
      });
      expect(host.table.activeCount, 0);
    });
    test('official-own-transfer', () async {
      final component = await _encodeComponent(r'''
(component
  (component $C
    (type $R' (resource (rep i32)))
    (export $R "R" (type $R'))
    (canon resource.new $R' (core func $R.resource.new))
    (canon resource.drop $R' (core func $R.resource.drop))
    (core module $CM
      (import "" "new" (func $new (param i32) (result i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "make") (param $rep i32) (result i32) (call $new (local.get $rep)))
      (func (export "take") (param $h i32) (call $drop (local.get $h)))
    )
    (core instance $cm (instantiate $CM (with "" (instance
      (export "new" (func $R.resource.new))
      (export "drop" (func $R.resource.drop))
    ))))
    (func (export "make") (param "rep" u32) (result (own $R)) (canon lift (core func $cm "make")))
    (func (export "take") (param "r" (own $R)) (canon lift (core func $cm "take")))
  )
  (component $D
    (import "c" (instance $c
      (export "R" (type $R (sub resource)))
      (export "make" (func (param "rep" u32) (result (own $R))))
      (export "take" (func (param "r" (own $R))))
    ))
    (alias export $c "R" (type $R))
    (canon resource.drop $R (core func $R.resource.drop))
    (canon lower (func $c "make") (core func $make'))
    (canon lower (func $c "take") (core func $take'))
    (core module $DM
      (import "" "make" (func $make (param i32) (result i32)))
      (import "" "take" (func $take (param i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "run") (result i32)
        (if (i32.ne (i32.const 1) (call $make (i32.const 100))) (then unreachable))
        (if (i32.ne (i32.const 2) (call $make (i32.const 200))) (then unreachable))
        (call $drop (i32.const 2))
        (call $take (i32.const 1))
        (if (i32.ne (i32.const 1) (call $make (i32.const 300))) (then unreachable))
        (i32.const 43)
      )
    )
    (core instance $dm (instantiate $DM (with "" (instance
      (export "make" (func $make'))
      (export "take" (func $take'))
      (export "drop" (func $R.resource.drop))
    ))))
    (func (export "run") (result u32) (canon lift (core func $dm "run")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "run") (alias export $d "run"))
)
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        await runtime.initialize();
        expect(await runtime.invokeExport('run', []), 43);
      });
      expect(host.table.activeCount, 0);
    });
    test('wrong-type-own-return', () async {
      final component = await _encodeComponent(r'''
(component
  (type $R1 (resource (rep i32)))
  (type $R2 (resource (rep i32)))
  (canon resource.new $R1 (core func $R1.resource.new))
  (canon resource.drop $R2 (core func $R2.resource.drop))
  (core module $M
    (import "" "R1.new" (func $R1.new (param i32) (result i32)))
    (import "" "R2.drop" (func $R2.drop (param i32)))
    (func (export "drop-R1-as-R2")
      (if (i32.ne (i32.const 1) (call $R1.new (i32.const 100))) (then unreachable))
      (call $R2.drop (i32.const 1))
    )
    (func (export "return-R1-as-R2") (result i32)
      (call $R1.new (i32.const 100))
    )
  )
  (core instance $m (instantiate $M (with "" (instance
    (export "R1.new" (func $R1.resource.new))
    (export "R2.drop" (func $R2.resource.drop))
  ))))
  (export $R2' "R2" (type $R2))
  (func (export "drop-R1-as-R2") (canon lift (core func $m "drop-R1-as-R2")))
  (func (export "return-R1-as-R2") (result (own $R2')) (canon lift (core func $m "return-R1-as-R2")))
)
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        await runtime.initialize();
        await expectLater(
          runtime.invokeExport('return-R1-as-R2', []),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('does not contain'),
            ),
          ),
        );
      });
      expect(host.table.activeCount, 0);
    });
    test('wrong-type-drop', () async {
      final component = await _encodeComponent(r'''
(component
  (type $R1 (resource (rep i32)))
  (type $R2 (resource (rep i32)))
  (canon resource.new $R1 (core func $R1.resource.new))
  (canon resource.drop $R2 (core func $R2.resource.drop))
  (core module $M
    (import "" "R1.new" (func $R1.new (param i32) (result i32)))
    (import "" "R2.drop" (func $R2.drop (param i32)))
    (func (export "drop-R1-as-R2")
      (if (i32.ne (i32.const 1) (call $R1.new (i32.const 100))) (then unreachable))
      (call $R2.drop (i32.const 1))
    )
    (func (export "return-R1-as-R2") (result i32)
      (call $R1.new (i32.const 100))
    )
  )
  (core instance $m (instantiate $M (with "" (instance
    (export "R1.new" (func $R1.resource.new))
    (export "R2.drop" (func $R2.resource.drop))
  ))))
  (export $R2' "R2" (type $R2))
  (func (export "drop-R1-as-R2") (canon lift (core func $m "drop-R1-as-R2")))
  (func (export "return-R1-as-R2") (result (own $R2')) (canon lift (core func $m "return-R1-as-R2")))
)
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        await runtime.initialize();
        await expectLater(
          runtime.invokeExport('drop-R1-as-R2', []),
          throwsA(
            isA<WasmExecutionErrorContext>().having(
              (error) => error.cause,
              'cause',
              isA<StateError>(),
            ),
          ),
        );
      });
      expect(host.table.activeCount, 0);
    });
    test('lifo-observed', () async {
      final component = await _encodeComponent(r'''
(component
 (type $R (resource (rep i32)))
 (core func $new (canon resource.new $R))
 (core func $drop (canon resource.drop $R))
 (core module $M
  (import "h" "new" (func $new (param i32) (result i32)))
  (import "h" "drop" (func $drop (param i32)))
  (func (export "reuse") (result i32)
   i32.const 100 call $new drop
   i32.const 200 call $new drop
   i32.const 300 call $new drop
   i32.const 2 call $drop
   i32.const 400 call $new))
 (core instance $h (export "new" (func $new)) (export "drop" (func $drop)))
 (core instance $m (instantiate $M (with "h" (instance $h))))
 (func (export "reuse") (result u32) (canon lift (core func $m "reuse"))))
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        await runtime.initialize();
        expect(await runtime.invokeExport('reuse', []), 2);
      });
      expect(host.table.activeCount, 0);
    });
    test('stream-lowered-index', () async {
      final component = await _encodeComponent(r'''
(component
 (component $producer
  (type $value (stream u32))
  (core func $new (canon stream.new $value))
  (core module $M
   (import "h" "new" (func $new (result i64)))
   (func (export "make") (result i32) call $new i32.wrap_i64))
  (core instance $h (export "new" (func $new)))
  (core instance $m (instantiate $M (with "h" (instance $h))))
  (func (export "make") (result (stream u32)) (canon lift (core func $m "make"))))
 (component $consumer
  (import "p" (instance $p (export "make" (func (result (stream u32))))))
  (core func $make (canon lower (func $p "make")))
  (core module $M
   (import "h" "make" (func $make (result i32)))
   (func (export "received") (result i32) call $make))
  (core instance $h (export "make" (func $make)))
  (core instance $m (instantiate $M (with "h" (instance $h))))
  (func (export "received") (result u32) (canon lift (core func $m "received"))))
 (instance $p (instantiate $producer))
 (instance $c (instantiate $consumer (with "p" (instance $p))))
 (func (export "received") (alias export $c "received")))
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        await runtime.initialize();
        expect(await runtime.invokeExport('received', []), 1);
      });
      expect(host.table.activeCount, 0);
    });
    test('future-lowered-index', () async {
      final component = await _encodeComponent(r'''
(component
 (component $producer
  (type $value (future u32))
  (core func $new (canon future.new $value))
  (core module $M
   (import "h" "new" (func $new (result i64)))
   (func (export "make") (result i32) call $new i32.wrap_i64))
  (core instance $h (export "new" (func $new)))
  (core instance $m (instantiate $M (with "h" (instance $h))))
  (func (export "make") (result (future u32)) (canon lift (core func $m "make"))))
 (component $consumer
  (import "p" (instance $p (export "make" (func (result (future u32))))))
  (core func $make (canon lower (func $p "make")))
  (core module $M
   (import "h" "make" (func $make (result i32)))
   (func (export "received") (result i32) call $make))
  (core instance $h (export "make" (func $make)))
  (core instance $m (instantiate $M (with "h" (instance $h))))
  (func (export "received") (result u32) (canon lift (core func $m "received"))))
 (instance $p (instantiate $producer))
 (instance $c (instantiate $consumer (with "p" (instance $p))))
 (func (export "received") (alias export $c "received")))
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        await runtime.initialize();
        expect(await runtime.invokeExport('received', []), 1);
      });
      expect(host.table.activeCount, 0);
    });
    test('borrow-to-implementor', () async {
      final component = await _encodeComponent(r'''
(component
 (component $Def
  (type $R (resource (rep i32)))
  (export $Re "r" (type $R))
  (core func $new (canon resource.new $R))
  (core module $M
   (import "h" "new" (func $new (param i32) (result i32)))
   (func (export "make") (result i32) i32.const 100 call $new)
   (func (export "inspect") (param i32) (result i32) local.get 0))
  (core instance $h (export "new" (func $new)))
  (core instance $m (instantiate $M (with "h" (instance $h))))
  (func (export "make") (result (own $Re)) (canon lift (core func $m "make")))
  (func (export "inspect") (param "r" (borrow $Re)) (result u32) (canon lift (core func $m "inspect"))))
 (component $User
  (import "def" (instance $def
   (export "r" (type $R (sub resource)))
   (export "make" (func (result (own $R))))
   (export "inspect" (func (param "r" (borrow $R)) (result u32)))))
  (core func $make (canon lower (func $def "make")))
  (core func $inspect (canon lower (func $def "inspect")))
  (core module $M
   (import "h" "make" (func $make (result i32)))
   (import "h" "inspect" (func $inspect (param i32) (result i32)))
   (func (export "run") (result i32) call $make call $inspect))
  (core instance $h (export "make" (func $make)) (export "inspect" (func $inspect)))
  (core instance $m (instantiate $M (with "h" (instance $h))))
  (func (export "run") (result u32) (canon lift (core func $m "run"))))
 (instance $def (instantiate $Def))
 (instance $user (instantiate $User (with "def" (instance $def))))
 (func (export "run") (alias export $user "run")))
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        await runtime.initialize();
        expect(await runtime.invokeExport('run', []), 100);
      });
      expect(host.table.activeCount, 0);
    });
  });

  group('resource destructors', () {
    test(
      'rejects draft async destructors before allocating host state',
      () async {
        final component = _asyncResourceDestructorComponent();
        expect(component.validate(), isEmpty);
        final host = WASIComponentHost();
        await expectLater(
          WASIComponentNativeRuntime.component(
            component: component,
            host: host,
          ).initialize(),
          throwsA(
            isA<WASIPreview2ComponentExecutionException>().having(
              (error) => error.message,
              'message',
              contains('Asynchronous resource destructors are not executable'),
            ),
          ),
        );
        expect(host.table.activeCount, 0);
      },
    );

    for (final external in [false, true]) {
      test(
        'synchronous destructor reentry (external callback: $external)',
        () async {
          final component = await _encodeComponent(
            '(component ${_resourceDestructorSourceBody(reenter: true, external: external)})',
          );
          expect(component.validate(), isEmpty);
          final host = WASIComponentHost();
          var callbacks = 0;
          final unhandled = <Object>[];
          Object? observedError;
          Object? count;
          await runZonedGuarded(() async {
            try {
              await host.table.runScoped(() async {
                final runtime = WASIComponentNativeRuntime.component(
                  component: component,
                  host: host,
                  imports: {
                    'blocked': (_) async {
                      callbacks++;
                      await Future<void>.delayed(Duration.zero);
                      return 42;
                    },
                  },
                );
                final handle = await runtime.invokeExport('new', [7]);
                try {
                  await runtime.invokeExport('drop', [handle]);
                } catch (error) {
                  observedError = error;
                }
                count = await runtime.invokeExport('count', []);
              });
            } catch (error) {
              observedError ??= error;
            }
            await Future<void>.delayed(Duration.zero);
          }, (error, stack) => unhandled.add(error));
          expect(observedError, external ? isNotNull : isNull);
          expect(count, 7);
          expect(host.table.activeCount, 0);
          expect(callbacks, 0);
          expect(unhandled, isEmpty);
        },
      );
    }

    for (final trigger in ['post-return', 'realloc']) {
      for (final operation in ['new', 'rep', 'drop']) {
        for (final nested in operation == 'drop' ? [false, true] : [false]) {
          test(
            'blocks resource.$operation during $trigger before side effects (nested: $nested)',
            () async {
              final component = await _encodeComponent(
                _resourceMayLeaveSource(trigger, operation, nested: nested),
              );
              expect(component.validate(), isEmpty);
              final host = WASIComponentHost();
              final runtime = WASIComponentNativeRuntime.component(
                component: component,
                host: host,
              );
              await host.table.runScoped(() async {
                if (trigger == 'realloc') {
                  await runtime.invokeExport('seed', [11]);
                }
                await expectLater(
                  runtime.invokeExport(
                    trigger == 'realloc' ? 'accept' : 'run',
                    trigger == 'realloc' ? ['abc'] : [],
                  ),
                  throwsA(
                    isA<WasmExecutionErrorContext>().having(
                      (error) => error.cause,
                      'cause',
                      isA<StateError>().having(
                        (error) => error.message,
                        'message',
                        contains('cannot leave'),
                      ),
                    ),
                  ),
                );
                expect(host.table.activeCount, 1);
                expect(await runtime.invokeExport('count', []), 0);
              });
              expect(host.table.activeCount, 0);
              expect(
                await runtime.invokeExport('count', []),
                trigger == 'realloc' ? 11 : 7,
              );
            },
          );
        }
      }
    }

    test('dropping a borrow does not invoke the owned destructor', () async {
      final component = await _encodeComponent(r'''
(component
  (component $Def
    (core module $M
      (global $count (mut i32) (i32.const 0))
      (func (export "dtor") (param i32) local.get 0 global.get $count i32.add global.set $count)
      (func (export "count") (result i32) global.get $count))
    (core instance $m (instantiate $M))
    (type $R (resource (rep i32) (dtor (core func $m "dtor"))))
    (export $Re "r" (type $R))
    (core func $new (canon resource.new $R))
    (core func $drop (canon resource.drop $R))
    (func (export "new") (param "rep" u32) (result (own $Re)) (canon lift (core func $new)))
    (func (export "drop") (param "r" (own $Re)) (canon lift (core func $drop)))
    (func (export "count") (result u32) (canon lift (core func $m "count"))))
  (component $User
    (import "def" (instance $def (export "r" (type $R (sub resource)))))
    (alias export $def "r" (type $R))
    (core func $drop (canon resource.drop $R))
    (func (export "drop-borrow") (param "r" (borrow $R)) (canon lift (core func $drop))))
  (instance $def (instantiate $Def))
  (instance $user (instantiate $User (with "def" (instance $def))))
  (alias export $def "r" (type $R))
  (export "r" (type $R))
  (func (export "new") (alias export $def "new"))
  (func (export "drop") (alias export $def "drop"))
  (func (export "count") (alias export $def "count"))
  (func (export "drop-borrow") (alias export $user "drop-borrow")))
''');
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        final owned = await runtime.invokeExport('new', [13]) as int;
        await runtime.invokeExport('drop-borrow', [owned]);
        expect(await runtime.invokeExport('count', []), 0);
        expect(host.table.activeCount, 1);
        await runtime.invokeExport('drop', [owned]);
        expect(await runtime.invokeExport('count', []), 13);
        expect(host.table.activeCount, 0);
      });
    });

    test('passes the representation and drops each handle once', () async {
      final component = await _encodeComponent(_resourceDestructorSource());
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      await host.table.runScoped(() async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        final first = await runtime.invokeExport('new', [7]);
        final second = await runtime.invokeExport('new', [11]);
        await runtime.invokeExport('drop', [first]);
        expect(await runtime.invokeExport('count', []), 7);
        await expectLater(
          runtime.invokeExport('drop', [first]),
          throwsA(anything),
        );
        expect(await runtime.invokeExport('count', []), 7);
        await runtime.invokeExport('drop', [second]);
        expect(await runtime.invokeExport('count', []), 18);
        expect(host.table.activeCount, 0);
      });
      expect(host.table.activeCount, 0);
    });

    test('scope cleanup invokes the defining instance destructor', () async {
      final component = await _encodeComponent(_resourceDestructorSource());
      final host = WASIComponentHost();
      final runtime = WASIComponentNativeRuntime.component(
        component: component,
        host: host,
      );
      await host.table.runScoped(() async {
        await runtime.invokeExport('new', [13]);
        expect(await runtime.invokeExport('count', []), 0);
      });
      expect(await runtime.invokeExport('count', []), 13);
      expect(host.table.activeCount, 0);
    });

    test(
      'fresh component instances retain their own destructor core closure',
      () async {
        final component = await _encodeComponent('''
(component
  (component \$child ${_resourceDestructorSourceBody()})
  (instance \$a (instantiate \$child))
  (instance \$b (instantiate \$child))
  (func (export "new-a") (alias export \$a "new"))
  (func (export "drop-a") (alias export \$a "drop"))
  (func (export "count-a") (alias export \$a "count"))
  (func (export "new-b") (alias export \$b "new"))
  (func (export "drop-b") (alias export \$b "drop"))
  (func (export "count-b") (alias export \$b "count")))
''');
        expect(component.validate(), isEmpty);
        final host = WASIComponentHost();
        await host.table.runScoped(() async {
          final runtime = WASIComponentNativeRuntime.component(
            component: component,
            host: host,
          );
          final a = await runtime.invokeExport('new-a', [7]);
          final b = await runtime.invokeExport('new-b', [11]);
          await runtime.invokeExport('drop-b', [b]);
          expect(await runtime.invokeExport('count-a', []), 0);
          expect(await runtime.invokeExport('count-b', []), 11);
          await runtime.invokeExport('drop-a', [a]);
          expect(await runtime.invokeExport('count-a', []), 7);
          expect(await runtime.invokeExport('count-b', []), 11);
        });
        expect(host.table.activeCount, 0);
      },
    );

    test(
      'a trapping destructor releases its handle before propagating',
      () async {
        final component = await _encodeComponent(
          _resourceDestructorSource(trap: true),
        );
        final host = WASIComponentHost();
        await host.table.runScoped(() async {
          final runtime = WASIComponentNativeRuntime.component(
            component: component,
            host: host,
          );
          final handle = await runtime.invokeExport('new', [7]);
          await expectLater(
            runtime.invokeExport('drop', [handle]),
            throwsA(anything),
          );
          expect(await runtime.invokeExport('count', []), 7);
          expect(host.table.activeCount, 0);
          await expectLater(
            runtime.invokeExport('drop', [handle]),
            throwsA(anything),
          );
          expect(await runtime.invokeExport('count', []), 7);
        });
        expect(host.table.activeCount, 0);
      },
    );
  });

  for (final kind in ['stream', 'future']) {
    test(
      'fresh child resource identities reject foreign $kind endpoints',
      () async {
        final component = await _encodeComponent('''
(component
  (component \$C (type \$R (resource (rep i32))) (export "r" (type \$R)))
  (instance \$a (instantiate \$C))
  (instance \$b (instantiate \$C))
  (alias export \$a "r" (type \$R1))
  (alias export \$b "r" (type \$R2))
  (type \$OA (own \$R1))
  (type \$OB (own \$R2))
  (type \$SA ($kind \$OA))
  (type \$SB ($kind \$OB))
  (core func \$new (canon $kind.new \$SA))
  (core func \$drop (canon $kind.drop-readable \$SB))
  (core module \$m
    (import "h" "new" (func \$new (result i64)))
    (import "h" "drop" (func \$drop (param i32)))
    (func (export "run") (result i32) call \$new i32.wrap_i64 call \$drop i32.const 42))
  (core instance \$h (export "new" (func \$new)) (export "drop" (func \$drop)))
  (core instance \$m (instantiate \$m (with "h" (instance \$h))))
  (func (export "run") (result u32) (canon lift (core func \$m "run"))))
''');
        expect(component.validate(), isEmpty);
        final definitions = component.componentTypeIndexDefinitions;
        // A shared model definition is not proof of fresh instance identity.
        expect(identical(definitions[0], definitions[1]), isTrue);
        final host = WASIComponentHost();
        await expectLater(
          host.table.runScoped(() async {
            final runtime = WASIComponentNativeRuntime.component(
              component: component,
              host: host,
            );
            await runtime.invokeExport('run', []);
          }),
          throwsA(
            isA<WasmExecutionErrorContext>().having(
              (error) => error.cause,
              'cause',
              isA<StateError>().having(
                (error) => error.message,
                'message',
                contains('does not contain'),
              ),
            ),
          ),
        );
        expect(host.table.activeCount, 0);
      },
    );
  }

  test('pure structural payloads retain equivalent backing', () async {
    final component = await _encodeComponent(r'''
(component
  (type $item (record (field "x" u32)))
  (type $a (stream $item))
  (type $b (stream $item))
  (core func $new (canon stream.new $a))
  (core func $drop (canon stream.drop-readable $b))
  (core module $m
    (import "h" "new" (func $new (result i64)))
    (import "h" "drop" (func $drop (param i32)))
    (func (export "run") (result i32) call $new i32.wrap_i64 call $drop i32.const 42))
  (core instance $h (export "new" (func $new)) (export "drop" (func $drop)))
  (core instance $m (instantiate $m (with "h" (instance $h))))
  (func (export "run") (result u32) (canon lift (core func $m "run"))))
''');
    expect(component.validate(), isEmpty);
    final host = WASIComponentHost();
    await host.table.runScoped(() async {
      final runtime = WASIComponentNativeRuntime.component(
        component: component,
        host: host,
      );
      expect(await runtime.invokeExport('run', []), 42);
    });
    expect(host.table.activeCount, 0);
  });

  for (final kind in ['stream', 'future']) {
    test(
      'nested $kind transfer accepts equivalent inline result types',
      () async {
        final component = await _encodeComponent('''
(component
  (component \$producer
    (type \$value ($kind u32))
    (core func \$new (canon $kind.new \$value))
    (core module \$m
      (import "host" "new" (func \$new (result i64)))
      (func (export "make") (result i32) call \$new i32.wrap_i64))
    (core instance \$host (export "new" (func \$new)))
    (core instance \$m (instantiate \$m (with "host" (instance \$host))))
    (func (export "make") (result ($kind u32)) (canon lift (core func \$m "make"))))
  (component \$consumer
    (import "producer" (instance \$producer
      (export "make" (func (result ($kind u32))))))
    (type \$value ($kind u32))
    (core func \$drop (canon $kind.drop-readable \$value))
    (core func \$make (canon lower (func \$producer "make")))
    (core module \$m
      (import "host" "make" (func \$make (result i32)))
      (import "host" "drop" (func \$drop (param i32)))
      (func (export "run") (result i32) call \$make call \$drop i32.const 42))
    (core instance \$host (export "make" (func \$make)) (export "drop" (func \$drop)))
    (core instance \$m (instantiate \$m (with "host" (instance \$host))))
    (func (export "run") (result u32) (canon lift (core func \$m "run"))))
  (instance \$producer (instantiate \$producer))
  (instance \$consumer (instantiate \$consumer (with "producer" (instance \$producer))))
  (func (export "run") (alias export \$consumer "run")))
''');
        expect(component.validate(), isEmpty);
        final host = WASIComponentHost();
        await host.table.runScoped(() async {
          final runtime = WASIComponentNativeRuntime.component(
            component: component,
            host: host,
          );
          expect(await runtime.invokeExport('run', []), 42);
        });
        expect(host.table.activeCount, 0);
      },
    );
  }

  for (final kind in ['stream', 'future']) {
    test(
      'instance-local $kind adapter observes delayed callback failures',
      () async {
        final component = await _encodeComponent('''
(component
  (type \$value ($kind u32))
  (import "source" (func \$source (result \$value)))
  (core func \$source (canon lower (func \$source)))
  (core module \$m
    (import "host" "source" (func \$source (result i32)))
    (func (export "call") (result i32) call \$source))
  (core instance \$host (export "source" (func \$source)))
  (core instance \$m (instantiate \$m (with "host" (instance \$host))))
  (func (export "call") (result \$value) (canon lift (core func \$m "call"))))
''');
        final host = WASIComponentHost();
        final unhandled = <Object>[];
        final failure = StateError('endpoint callback failed');
        var calls = 0;
        await runZonedGuarded(
          () async {
            for (var i = 0; i < 2; i++) {
              final completion = Completer<Object?>();
              final runtime = WASIComponentNativeRuntime.component(
                component: component,
                host: host,
                imports: {
                  'source': (_) {
                    calls++;
                    return completion.future;
                  },
                },
              );
              final observed = expectLater(
                runtime.invokeExport('call', []),
                throwsA(
                  isA<WasmExecutionErrorContext>().having(
                    (error) => error.cause,
                    'cause',
                    same(failure),
                  ),
                ),
              );
              await Future<void>.delayed(Duration.zero);
              completion.completeError(failure);
              await observed;
              expect(host.table.activeCount, 0);
            }
            await Future<void>.delayed(Duration.zero);
          },
          (error, _) {
            unhandled.add(error);
          },
        );
        expect(calls, 2);
        expect(unhandled, isEmpty);
      },
    );
  }

  test(
    'fresh async runtimes initialize concurrently on the same host',
    () async {
      final component = await _encodeComponent(r'''
(component
  (type $value (stream u32))
  (core func (canon stream.new $value)))
''');
      final host = WASIComponentHost();
      await Future.wait([
        for (var i = 0; i < 3; i++)
          WASIComponentNativeRuntime.component(
            component: component,
            host: host,
          ).initialize(),
      ]);
      expect(host.table.activeCount, 0);
    },
  );

  for (final kind in ['stream', 'future']) {
    for (final delayed in [false, true]) {
      test(
        'instance-local $kind adapters transfer through Core delayed=$delayed',
        () async {
          final component = await _encodeComponent('''
(component
  (type \$value ($kind u32))
  (import "source" (func \$source (result \$value)))
  (core func \$source (canon lower (func \$source)))
  (core module \$m
    (import "host" "source" (func \$source (result i32)))
    (func (export "call") (result i32) call \$source))
  (core instance \$host (export "source" (func \$source)))
  (core instance \$m (instantiate \$m (with "host" (instance \$host))))
  (func (export "call") (result \$value) (canon lift (core func \$m "call"))))
''');
          expect(component.validate(), isEmpty);
          final host = WASIComponentHost();
          for (var i = 0; i < 2; i++) {
            final Object value = kind == 'stream'
                ? WASIComponentStream<Object?>('host')
                : WASIComponentFuture<Object?>('host');
            final Object endpoint = value is WASIComponentStream<Object?>
                ? value.readable
                : (value as WASIComponentFuture<Object?>).readable;
            var calls = 0;
            final runtime = WASIComponentNativeRuntime.component(
              component: component,
              host: host,
              imports: {
                'source': (_) {
                  calls++;
                  return delayed
                      ? Future<Object>.delayed(Duration.zero, () => endpoint)
                      : endpoint;
                },
              },
            );
            expect(await runtime.invokeExport('call', []), same(endpoint));
            expect(calls, 1);
            expect(host.table.activeCount, 0);
            if (value is WASIComponentStream<Object?>) {
              value.writable.write(42);
              expect(value.readable.read(1), [42]);
              value.readable.drop();
              value.writable.drop();
            } else {
              final future = value as WASIComponentFuture<Object?>;
              future.writable.completeForCopy(42);
              expect(future.readable.read(), 42);
              future.readable.drop();
              future.writable.drop();
            }
          }
        },
      );
    }
  }

  for (final kind in ['stream', 'future']) {
    test('fresh top-level $kind registries coexist on one host', () async {
      final component = await _encodeComponent('''
(component
  (type \$value ($kind))
  (core func (canon $kind.new \$value))
  (core func (canon $kind.drop-readable \$value))
  (core func (canon $kind.drop-writable \$value)))
''');
      expect(component.validate(), isEmpty);
      final host = WASIComponentHost();
      final one = WASIComponentNativeRuntime.component(
        component: component,
        host: host,
      );
      final two = WASIComponentNativeRuntime.component(
        component: component,
        host: host,
      );
      await one.initialize();
      await two.initialize();
      expect(host.table.activeCount, 0);
    });
  }

  test('sibling async registries retain index zero independently', () async {
    final component = await _encodeComponent(r'''
(component
  (component $child
    (type $value (stream))
    (core func (canon stream.new $value))
    (core func (canon stream.drop-readable $value))
    (core func (canon stream.drop-writable $value)))
  (instance (instantiate $child))
  (instance (instantiate $child)))
''');
    expect(component.validate(), isEmpty);
    final host = WASIComponentHost();
    await WASIComponentNativeRuntime.component(
      component: component,
      host: host,
    ).initialize();
    expect(host.table.activeCount, 0);
  });

  test('stream and future with the same local index coexist', () async {
    final host = WASIComponentHost();
    for (final kind in ['stream', 'future']) {
      final component = await _encodeComponent('''
(component
  (type \$value ($kind))
  (core func (canon $kind.new \$value))
  (core func (canon $kind.drop-readable \$value))
  (core func (canon $kind.drop-writable \$value)))
''');
      expect(component.validate(), isEmpty);
      await WASIComponentNativeRuntime.component(
        component: component,
        host: host,
      ).initialize();
    }
    expect(host.table.activeCount, 0);
  });

  group('nested Component execution', () {
    test('keeps each child Core instance state independent', () async {
      final component = await _encodeComponent('''
(component
  (component \$child
    (core module \$m
      (global \$count (mut i32) (i32.const 0))
      (func (export "next") (result i32)
        global.get \$count i32.const 1 i32.add global.set \$count
        global.get \$count))
    (core instance \$m (instantiate \$m))
    (func (export "next") (result u32) (canon lift (core func \$m "next"))))
  (instance \$one (instantiate \$child))
  (instance \$two (instantiate \$child))
  (func (export "one") (alias export \$one "next"))
  (func (export "two") (alias export \$two "next")))
''');
      expect(component.validate(), isEmpty);
      final runtime = WASIComponentNativeRuntime.component(
        component: component,
        host: WASIComponentHost(),
      );
      expect(await runtime.invokeExport('one', []), 1);
      expect(await runtime.invokeExport('one', []), 2);
      expect(await runtime.invokeExport('two', []), 1);
      expect(await runtime.invokeExport('one', []), 3);
    });

    for (final delayed in [false, true]) {
      test('retains live parent callbacks delayed=$delayed', () async {
        final component = await _encodeComponent('''
(component
  (import "source" (func \$source (result u32)))
  (component \$child
    (import "source" (func \$source (result u32)))
    (core func \$source (canon lower (func \$source)))
    (core module \$m
      (import "host" "source" (func \$source (result i32)))
      (func (export "call") (result i32) call \$source))
    (core instance \$host (export "source" (func \$source)))
    (core instance \$m (instantiate \$m (with "host" (instance \$host))))
    (func (export "call") (result u32) (canon lift (core func \$m "call"))))
  (instance \$child (instantiate \$child (with "source" (func \$source))))
  (func (export "call") (alias export \$child "call")))
''');
        var calls = 40;
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: WASIComponentHost(),
          imports: {
            'source': (_) => delayed
                ? Future<int>.delayed(Duration.zero, () => ++calls)
                : ++calls,
          },
        );
        expect(await runtime.invokeExport('call', []), 41);
        expect(await runtime.invokeExport('call', []), 42);
        expect(calls, 42);
      });
    }

    test('resolves captured outer types through an instance type', () async {
      final component = await _encodeComponent('''
(component
  (type \$flags (flags "first" "second" "third"))
  (component \$provider
    (export \$f "flags" (type \$flags))
    (core module \$m
      (func (export "check") (param i32)
        local.get 0 i32.const 5 i32.ne if unreachable end))
    (core instance \$m (instantiate \$m))
    (func (export "check") (param "x" \$f) (canon lift (core func \$m "check"))))
  (component \$caller
    (import "provider" (instance \$provider
      (export "flags" (type \$f (eq \$flags)))
      (export "check" (func (param "x" \$f)))))
    (core func \$check (canon lower (func \$provider "check")))
    (core module \$m
      (import "" "check" (func \$check (param i32)))
      (func (export "run") (result i32)
        i32.const 0xffffff05 call \$check i32.const 77))
    (core instance \$m (instantiate \$m (with "" (instance
      (export "check" (func \$check))))))
    (func (export "run") (result u32) (canon lift (core func \$m "run"))))
  (instance \$provider (instantiate \$provider))
  (instance \$caller (instantiate \$caller (with "provider" (instance \$provider))))
  (func (export "run") (alias export \$caller "run")))
''');
      expect(component.validate(), isEmpty);
      final runtime = WASIComponentNativeRuntime.component(
        component: component,
        host: WASIComponentHost(),
      );
      expect(await runtime.invokeExport('run', []), 77);
    });

    test(
      'retains nominal resource identities supplied to each child',
      () async {
        final component = await _encodeComponent('''
(component
  (import "one" (instance \$one (export "item" (type (sub resource)))))
  (import "two" (instance \$two (export "item" (type (sub resource)))))
  (alias export \$one "item" (type \$one-item))
  (alias export \$two "item" (type \$two-item))
  (component \$child
    (import "types" (instance \$types (export "item" (type (sub resource)))))
    (alias export \$types "item" (type \$item))
    (alias outer 0 \$item (type \$same))
    (core func \$drop (canon resource.drop \$same))
    (func (export "drop") (param "handle" (own \$same)) (canon lift (core func \$drop))))
  (instance \$a (instantiate \$child (with "types" (instance \$one))))
  (instance \$b (instantiate \$child (with "types" (instance \$two))))
  (func (export "one") (alias export \$a "drop"))
  (func (export "two") (alias export \$b "drop")))
''');
        expect(component.validate(), isEmpty);
        final host = WASIComponentHost();
        var firstDrops = 0;
        var secondDrops = 0;
        final resourceIndexes = [
          for (
            var index = 0;
            index < component.componentTypeIndexDefinitions.length;
            index++
          )
            if (component.componentTypeIndexDefinitions[index].resource != null)
              index,
        ];
        final first = host.canonicalHost.resourceHost
            .defineResourceType<Object>(
              resourceIndexes[0],
              'same host debug name',
              onDrop: (_) => firstDrops++,
            );
        final second = host.canonicalHost.resourceHost
            .defineResourceType<Object>(
              resourceIndexes[1],
              'same host debug name',
              onDrop: (_) => secondDrops++,
            );
        final firstHandle = host.table.insert(first, Object());
        final secondHandle = host.table.insert(second, Object());
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        await expectLater(
          runtime.invokeExport('one', [secondHandle]),
          throwsStateError,
        );
        expect(firstDrops, 0);
        expect(secondDrops, 0);
        await runtime.invokeExport('one', [firstHandle]);
        await runtime.invokeExport('two', [secondHandle]);
        expect(firstDrops, 1);
        expect(secondDrops, 1);
        expect(host.table.activeCount, 0);
      },
    );

    test(
      'rejects nested Component starts before launching callbacks',
      () async {
        final component = await _encodeComponent(r'''
(component
  (import "source" (func $source))
  (component $child
    (import "source" (func $source))
    (start $source))
  (instance (instantiate $child (with "source" (func $source)))))
''');
        expect(component.validate(), isEmpty);
        var calls = 0;
        await expectLater(
          WASIComponentNativeRuntime.component(
            component: component,
            host: WASIComponentHost(),
            imports: {
              'source': (_) {
                calls++;
                return Future<void>.value();
              },
            },
          ).initialize(),
          throwsA(
            isA<WASIPreview2ComponentExecutionException>().having(
              (error) => error.message,
              'message',
              contains('Nested Component starts are not executable'),
            ),
          ),
        );
        expect(calls, 0);
      },
    );

    test(
      'concrete local resource aliases keep their runtime identity',
      () async {
        final component = await _encodeComponent(r'''
(component
  (component $child
    (type $resource (resource (rep i32)))
    (alias outer 0 $resource (type $same))
    (core func $new (canon resource.new $resource))
    (core func $rep (canon resource.rep $same))
    (core module $m
      (import "" "new" (func $new (param i32) (result i32)))
      (import "" "rep" (func $rep (param i32) (result i32)))
      (func (export "run") (result i32) i32.const 42 call $new call $rep))
    (core instance $m (instantiate $m (with "" (instance
      (export "new" (func $new)) (export "rep" (func $rep))))))
    (func (export "run") (result u32) (canon lift (core func $m "run"))))
  (instance $child (instantiate $child))
  (func (export "run") (alias export $child "run")))
''');
        expect(component.validate(), isEmpty);
        final host = WASIComponentHost();
        await host.table.runScoped(() async {
          final runtime = WASIComponentNativeRuntime.component(
            component: component,
            host: host,
          );
          expect(await runtime.invokeExport('run', []), 42);
        });
        expect(host.table.activeCount, 0);
      },
    );

    for (final (depth, index) in [(2, 0), (1, 8)]) {
      test('rejects invalid outer alias $depth/$index', () async {
        final component = await _encodeComponent('''
(component
  (type (flags "flag"))
  (component \$child (alias outer $depth $index (type)))
  (instance (instantiate \$child)))
''');
        expect(component.validate(), isNotEmpty);
        await expectLater(
          WASIComponentNativeRuntime.component(
            component: component,
            host: WASIComponentHost(),
          ).initialize(),
          throwsA(isA<WASIPreview2ComponentExecutionException>()),
        );
      });
    }
  });

  for (final coreStart in [false, true]) {
    test(
      'Core invalid char retains a typed cause coreStart=$coreStart',
      () async {
        final component = await _encodeComponent('''
(component
  (import "take" (func \$take (param "value" char)))
  (core func \$take (canon lower (func \$take)))
  (core module \$m
    (import "" "take" (func \$take (param i32)))
    (func \$run (export "run") i32.const 0xd800 call \$take)
    ${coreStart ? '(start \$run)' : ''})
  (core instance \$m (instantiate \$m (with "" (instance
    (export "take" (func \$take))))))
  (func (export "run") (canon lift (core func \$m "run"))))
''');
        var calls = 0;
        Object? observed;
        try {
          final runtime = WASIComponentNativeRuntime.component(
            component: component,
            host: WASIComponentHost(),
            imports: {
              'take': (_) {
                calls++;
                return null;
              },
            },
          );
          if (coreStart) {
            await runtime.initialize();
          } else {
            await runtime.invokeExport('run', []);
          }
        } catch (error) {
          observed = error;
        }
        expect(calls, 0);
        expect(observed, isA<WasmExecutionErrorContext>());
        while (observed is WasmExecutionErrorContext) {
          observed = observed.cause;
        }
        expect(observed, isA<WASIComponentInvalidCharException>());
      },
    );
  }

  test('initialization is idempotent and preserves guest state', () async {
    final component = _counterComponent();
    expect(component.validate(), isEmpty);
    final runtime = WASIComponentNativeRuntime.component(
      component: component,
      host: WASIComponentHost(),
    );

    await runtime.initialize();
    expect(await runtime.invokeExport('next', []), 1);
    await runtime.initialize();
    expect(await runtime.invokeExport('next', []), 2);

    final other = WASIComponentNativeRuntime.component(
      component: component,
      host: WASIComponentHost(),
    );
    expect(await other.invokeExport('next', []), 1);
    expect(await runtime.invokeExport('next', []), 3);
  });

  test('missing exports report a lookup failure before invocation', () async {
    final runtime = WASIComponentNativeRuntime.component(
      component: _counterComponent(),
      host: WASIComponentHost(),
    );

    expect(
      () => runtime.invokeExport('missing', []),
      throwsA(
        isA<WASIPreview2ComponentExecutionException>().having(
          (error) => error.message,
          'message',
          contains('export `missing` not found'),
        ),
      ),
    );
    expect(await runtime.invokeExport('next', []), 1);
  });

  for (final throughCore in [false, true]) {
    test(
      'generic execution invokes imports throughCore=$throughCore',
      () async {
        final runtime = WASIComponentNativeRuntime.component(
          component: throughCore
              ? _callbackThroughCoreComponent()
              : _callbackComponent(),
          host: WASIComponentHost(),
          imports: {'source': (_) => 42},
        );

        expect(await runtime.invokeExport('call', []), 42);
      },
    );
  }

  test('generic execution does not supply implicit WASI imports', () async {
    final runtime = WASIComponentNativeRuntime.component(
      component: _callbackComponent(),
      host: WASIComponentHost(),
    );

    await expectLater(
      runtime.initialize,
      throwsA(
        isA<WASIPreview2ComponentExecutionException>().having(
          (error) => error.message,
          'message',
          contains('import callback `source`'),
        ),
      ),
    );
  });

  for (final throughCore in [false, true]) {
    for (final fails in [false, true]) {
      test(
        'invocation observes delayed callback throughCore=$throughCore fails=$fails',
        () async {
          final unhandled = <Object>[];
          final completion = Completer<int>();
          final effects = <String>[];
          Object? observedResult;
          Object? observedError;
          var observedBeforeCompletion = false;
          await runZonedGuarded(
            () async {
              final runtime = WASIComponentNativeRuntime.component(
                component: throughCore
                    ? _callbackThroughCoreComponent()
                    : _callbackComponent(),
                host: WASIComponentHost(),
                imports: {
                  'source': (_) async {
                    final result = await completion.future;
                    effects.add('completed');
                    if (fails) throw StateError('delayed import failure');
                    return result;
                  },
                },
              );
              final invocation =
                  Future<Object?>.sync(
                    () => runtime.invokeExport('call', []),
                  ).then<void>(
                    (result) {
                      observedResult = result;
                    },
                    onError: (Object error, StackTrace stack) {
                      observedError = error;
                    },
                  );
              await Future<void>.delayed(Duration.zero);
              observedBeforeCompletion =
                  observedResult != null || observedError != null;
              completion.complete(42);
              await invocation;
              await Future<void>.delayed(Duration.zero);
            },
            (error, stack) {
              unhandled.add(error);
            },
          );
          expect(observedBeforeCompletion, false);
          expect(effects, ['completed']);
          expect(unhandled, isEmpty);
          if (fails) {
            expect(observedResult, isNull);
            expect(
              observedError,
              throughCore
                  ? isA<Exception>().having(
                      (error) => error.toString(),
                      'VM error cause',
                      endsWith('Bad state: delayed import failure'),
                    )
                  : isA<StateError>().having(
                      (error) => error.message,
                      'message',
                      'delayed import failure',
                    ),
            );
          } else {
            expect(observedResult, 42);
            expect(observedError, isNull);
          }
        },
      );
    }
  }

  for (final fails in [false, true]) {
    test(
      'initialization observes delayed Component start fails=$fails',
      () async {
        final completion = Completer<void>();
        final unhandled = <Object>[];
        var started = 0;
        var finished = false;
        Object? observedError;
        var settled = false;
        var settledBeforeCompletion = false;
        await runZonedGuarded(
          () async {
            final runtime = WASIComponentNativeRuntime.component(
              component: _componentStart(),
              host: WASIComponentHost(),
              imports: {
                'source': (_) async {
                  started++;
                  await completion.future;
                  finished = true;
                  if (fails) throw StateError('delayed start failure');
                  return null;
                },
              },
            );
            final initialization = Future<void>.sync(runtime.initialize)
                .then<void>(
                  (_) {
                    settled = true;
                  },
                  onError: (Object error, StackTrace stack) {
                    settled = true;
                    observedError = error;
                  },
                );
            await Future<void>.delayed(Duration.zero);
            settledBeforeCompletion = settled;
            completion.complete();
            await initialization;
            await Future<void>.delayed(Duration.zero);
            if (!fails && observedError == null) {
              await runtime.initialize();
            }
          },
          (error, stack) {
            unhandled.add(error);
          },
        );
        expect(settledBeforeCompletion, false);
        expect(started, 1);
        expect(finished, true);
        expect(unhandled, isEmpty);
        if (fails) {
          expect(
            observedError,
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'delayed start failure',
            ),
          );
        } else {
          expect(observedError, isNull);
        }
      },
    );
  }

  for (final delayed in [false, true]) {
    for (final invoke in [false, true]) {
      test(
        'initialization rejects same-chain reentry delayed=$delayed invoke=$invoke',
        () async {
          var calls = 0;
          final unhandled = <Object>[];
          Object? reentryError;
          Object? initializationError;
          late WASIComponentNativeRuntime runtime;
          await runZonedGuarded(
            () async {
              runtime = WASIComponentNativeRuntime.component(
                component: _componentStart(),
                host: WASIComponentHost(),
                imports: {
                  'source': (_) {
                    calls++;
                    Future<void> reenter() async {
                      try {
                        if (invoke) {
                          await runtime.invokeExport('missing', []);
                        } else {
                          await runtime.initialize();
                        }
                      } catch (error) {
                        reentryError = error;
                      }
                    }

                    return delayed
                        ? Future<void>.delayed(
                            Duration.zero,
                          ).then((_) => reenter())
                        : reenter();
                  },
                },
              );
              try {
                await runtime.initialize().timeout(const Duration(seconds: 1));
              } catch (error) {
                initializationError = error;
              }
              await Future<void>.delayed(Duration.zero);
            },
            (error, stack) {
              unhandled.add(error);
            },
          );
          expect(calls, 1);
          expect(initializationError, isNull);
          expect(unhandled, isEmpty);
          expect(
            reentryError,
            isA<WASIPreview2ComponentExecutionException>().having(
              (error) => error.message,
              'message',
              contains('Reentrant Component initialization'),
            ),
          );
          await runtime.initialize();
        },
      );
    }
  }

  test('concurrent initialization awaits the same Component start', () async {
    final completion = Completer<void>();
    var calls = 0;
    final runtime = WASIComponentNativeRuntime.component(
      component: _componentStart(),
      host: WASIComponentHost(),
      imports: {
        'source': (_) async {
          calls++;
          await completion.future;
          return null;
        },
      },
    );
    final first = runtime.initialize();
    final second = runtime.initialize();
    expect(identical(first, second), true);
    expect(calls, 1);
    completion.complete();
    await Future.wait([first, second]);
    await runtime.initialize();
    expect(calls, 1);
  });

  test('generic core start rejects callbacks before launching them', () async {
    final component = _coreStart();
    expect(component.validate(), isEmpty);
    final unhandled = <Object>[];
    var calls = 0;
    Object? observedError;
    await runZonedGuarded(
      () async {
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: WASIComponentHost(),
          imports: {
            'source': (_) async {
              calls++;
              await Future<void>.delayed(Duration.zero);
              throw StateError('unobserved core start');
            },
          },
        );
        try {
          await Future<void>.sync(runtime.initialize);
        } catch (error) {
          observedError = error;
        }
        await Future<void>.delayed(Duration.zero);
      },
      (error, stack) {
        unhandled.add(error);
      },
    );
    expect(calls, 0);
    expect(unhandled, isEmpty);
    expect(
      observedError,
      isA<WASIPreview2ComponentExecutionException>().having(
        (error) => error.message,
        'message',
        contains('cannot be invoked synchronously'),
      ),
    );
  });

  test('the caller owns the resource scope across invocations', () async {
    final host = WASIComponentHost();
    final type = host.table.defineType<String>('test');
    final runtime = WASIComponentNativeRuntime.component(
      component: _callbackComponent(),
      host: host,
      imports: {'source': (_) => host.table.insert(type, 'alive')},
    );

    await host.table.runScoped(() async {
      final first = await runtime.invokeExport('call', []) as int;
      final second = await runtime.invokeExport('call', []) as int;
      expect(host.table.get(type, first), 'alive');
      expect(host.table.get(type, second), 'alive');
      expect(host.table.activeCount, 2);
    });
    expect(host.table.activeCount, 0);
  });

  test(
    'generic construction keeps the existing WASI profiles separate',
    () async {
      final component = _component([
        // canon context.get i32 0 is legal outside the Preview2 profile.
        _section(8, [1, 0x0a, 0x7f, 0]),
      ]);
      expect(component.validate(), isEmpty);

      await WASIComponentNativeRuntime.component(
        component: component,
        host: WASIComponentHost(),
      ).initialize();
      await WASIComponentNativeRuntime.preview3(
        component: component,
        host: WASIPreview3ComponentHost(),
      ).initialize();
      await expectLater(
        WASIComponentNativeRuntime.preview2(
          component: component,
          host: WASIPreview2ComponentHost(),
        ).initialize,
        throwsA(
          isA<WASIPreview2ComponentExecutionException>().having(
            (error) => error.message,
            'message',
            contains('Preview2 does not include context'),
          ),
        ),
      );
    },
  );
}

Future<WasmComponent> _encodeComponent(String source) async {
  final directory = await Directory.systemTemp.createTemp(
    'wasd-nested-component-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final input = File('${directory.path}/input.wat');
  final output = File('${directory.path}/input.wasm');
  await input.writeAsString(source);
  final result = await Process.run(
    '.toolchains/bin/${Platform.isWindows ? 'wasm-tools.exe' : 'wasm-tools'}',
    ['parse', input.path, '-o', output.path],
  );
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  return WasmComponent.decode(await output.readAsBytes());
}

String _resourceDestructorSource({bool trap = false}) =>
    '(component ${_resourceDestructorSourceBody(trap: trap)})';

WasmComponent _asyncResourceDestructorComponent() => _component([
  _section(1, [
    0,
    97,
    115,
    109,
    1,
    0,
    0,
    0,
    ..._section(1, [1, 0x60, 1, 0x7f, 0]),
    ..._section(3, [1, 0]),
    ..._section(7, [1, ..._name('dtor'), 0, 0]),
    ..._section(10, [1, 2, 0, 0x0b]),
  ]),
  _section(2, [1, 0, 0, 0]),
  _section(6, [1, 0, 0, 1, 0, ..._name('dtor')]),
  _section(7, [1, 0x3e, 0x7f, 0, 0]),
]);

String _resourceMayLeaveSource(
  String trigger,
  String operation, {
  bool nested = false,
}) =>
    '''
(component
  ${nested ? '''
  (component \$child ${_resourceDestructorSourceBody()})
  (instance \$child (instantiate \$child))
  (func (export "count") (alias export \$child "count"))
  (core func \$new (canon lower (func \$child "new")))
  (core func \$drop (canon lower (func \$child "drop")))
  ''' : '''
  ${_resourceDestructorSourceBody()}
  (core func \$rep (canon resource.rep \$r))
  '''}
  (core module \$driver
    (import "h" "new" (func \$new (param i32) (result i32)))
    (import "h" "op" (func \$op (param i32) ${operation == 'drop' ? '' : '(result i32)'}))
    (global \$h (mut i32) (i32.const 0))
    ${trigger == 'post-return' ? '''
    (func (export "run") (result i32) i32.const 7 call \$new global.set \$h i32.const 0)
    (func (export "post") (param i32) global.get \$h call \$op ${operation == 'drop' ? '' : 'drop'})
    ''' : '''
    (memory (export "memory") 1)
    (func (export "seed") (param i32) local.get 0 call \$new global.set \$h)
    (func (export "accept") (param i32 i32))
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      global.get \$h call \$op ${operation == 'drop' ? '' : 'drop'} i32.const 64)
    '''})
  (core instance \$h (export "new" (func \$new)) (export "op" (func \$$operation)))
  (core instance \$driver (instantiate \$driver (with "h" (instance \$h))))
  ${trigger == 'post-return' ? '''
  (func (export "run") (result u32) (canon lift (core func \$driver "run") (post-return (core func \$driver "post"))))
  ''' : '''
  (func (export "seed") (param "rep" u32) (canon lift (core func \$driver "seed")))
  (func (export "accept") (param "text" string) (canon lift (core func \$driver "accept")
    (memory (core memory \$driver "memory")) (realloc (core func \$driver "realloc"))))
  '''})
''';

String _resourceDestructorSourceBody({
  bool trap = false,
  bool reenter = false,
  bool external = false,
}) =>
    '''
  ${external ? '(import "blocked" (func \$blocked (result u32)))' : ''}
  (core module \$state
    (global \$count (mut i32) (i32.const 0))
    (func (export "dtor") (param i32)
      global.get \$count local.get 0 i32.add global.set \$count
      ${trap ? 'unreachable' : ''})
    (func (export "count") (result i32) global.get \$count))
  (core instance \$state (instantiate \$state))
  (alias core export \$state "dtor" (core func \$dtor))
  (alias core export \$state "count" (core func \$count))
  (func \$padding (result u32) (canon lift (core func \$count)))
  ${reenter ? '''
  (core func \$read (canon lower (func ${external ? '\$blocked' : '\$padding'})))
  (core module \$recursive
    (import "h" "dtor" (func \$dtor (param i32)))
    (import "h" "read" (func \$read (result i32)))
    (func (export "dtor") (param i32) local.get 0 call \$dtor call \$read drop))
  (core instance \$recursive-imports (export "dtor" (func \$dtor)) (export "read" (func \$read)))
  (core instance \$recursive (instantiate \$recursive (with "h" (instance \$recursive-imports))))
  (alias core export \$recursive "dtor" (core func \$recursive-dtor))
  ''' : ''}
  (type \$r (resource (rep i32) (dtor ${reenter ? '\$recursive-dtor' : '\$dtor'})))
  (core func \$new (canon resource.new \$r))
  (core func \$drop (canon resource.drop \$r))
  (func (export "new") (param "rep" u32) (result u32)
    (canon lift (core func \$new)))
  (func (export "drop") (param "handle" u32)
    (canon lift (core func \$drop)))
  (func (export "count") (result u32) (canon lift (core func \$count)))
''';

WasmComponent _callbackComponent() => _component([
  _section(7, [1, 0x40, 0, 0, 0x79]),
  _section(10, [1, 0, ..._name('source'), 1, 0]),
  _section(11, [1, 0, ..._name('call'), 1, 0, 0]),
]);

// Host import -> canon lower -> Core call -> canon lift -> Component export.
WasmComponent _callbackThroughCoreComponent() => _component([
  _section(7, [1, 0x40, 0, 0, 0x79]),
  _section(10, [1, 0, ..._name('source'), 1, 0]),
  _section(8, [1, 1, 0, 0, 0]),
  _section(1, [
    0,
    97,
    115,
    109,
    1,
    0,
    0,
    0,
    ..._section(1, [1, 0x60, 0, 1, 0x7f]),
    ..._section(2, [1, ..._name('host'), ..._name('source'), 0, 0]),
    ..._section(3, [1, 0]),
    ..._section(7, [1, ..._name('call'), 0, 1]),
    ..._section(10, [1, 4, 0, 0x10, 0, 0x0b]),
  ]),
  _section(2, [1, 1, 1, ..._name('source'), 0, 0]),
  _section(2, [1, 0, 0, 1, ..._name('host'), 0x12, 0]),
  _section(6, [1, 0, 0, 1, 1, ..._name('call')]),
  _section(8, [1, 0, 0, 1, 0, 0]),
  _section(11, [1, 0, ..._name('call'), 1, 1, 0]),
]);

WasmComponent _componentStart() => _component([
  _section(7, [1, 0x40, 0, 1, 0]),
  _section(10, [1, 0, ..._name('source'), 1, 0]),
  _section(9, [0, 0, 0]),
]);

WasmComponent _coreStart() => _component([
  _section(7, [1, 0x40, 0, 1, 0]),
  _section(10, [1, 0, ..._name('source'), 1, 0]),
  _section(8, [1, 1, 0, 0, 0]),
  _section(2, [1, 1, 1, ..._name('source'), 0, 0]),
  _section(1, [
    0,
    97,
    115,
    109,
    1,
    0,
    0,
    0,
    ..._section(1, [1, 0x60, 0, 0]),
    ..._section(2, [1, ..._name('host'), ..._name('source'), 0, 0]),
    ..._section(8, [0]),
  ]),
  _section(2, [1, 0, 0, 1, ..._name('host'), 0x12, 0]),
]);

WasmComponent _counterComponent() {
  // One guest i32 global; next increments it and returns the new value.
  final core = [
    0,
    97,
    115,
    109,
    1,
    0,
    0,
    0,
    ..._section(1, [1, 0x60, 0, 1, 0x7f]),
    ..._section(3, [1, 0]),
    ..._section(6, [1, 0x7f, 1, 0x41, 0, 0x0b]),
    ..._section(7, [1, ..._name('next'), 0, 0]),
    ..._section(10, [1, 11, 0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0x23, 0, 0x0b]),
  ];
  return _component([
    _section(1, core),
    _section(2, [1, 0, 0, 0]),
    _section(6, [1, 0, 0, 1, 0, ..._name('next')]),
    _section(7, [1, 0x40, 0, 0, 0x79]),
    _section(8, [1, 0, 0, 0, 0, 0]),
    _section(11, [1, 0, ..._name('next'), 1, 0, 0]),
  ]);
}

WasmComponent _component(List<List<int>> sections) => WasmComponent.decode(
  Uint8List.fromList([
    0,
    97,
    115,
    109,
    13,
    0,
    1,
    0,
    for (final section in sections) ...section,
  ]),
);

// These small test sections and ASCII names fit in one unsigned LEB byte.
List<int> _section(int id, List<int> payload) => [
  id,
  payload.length,
  ...payload,
];
List<int> _name(String name) => [name.length, ...name.codeUnits];

const _canonicalOwnershipScenarios =
    <(String, String, List<(String, List<Object?>, Object?)>)>[
      (
        'own-stream-accepted-prefix',
        _ownStreamAcceptance,
        [
          ('open', [], 1),
          ('write-status', [], 4294967295),
          ('first', [], 50),
          ('second', [], 51),
          ('receive', [], 16),
          ('sentinel', [], 3735928559),
          ('first', [], 'trap'),
          ('second', [], 51),
          ('sum', [], 0),
          ('drop-received', [], null),
          ('sum', [], 50),
          ('cancel', [], 18),
          ('drop-second', [], null),
          ('sum', [], 101),
          ('close-reader', [], null),
          ('close', [], null),
        ],
      ),
      (
        'own-stream-cancel-unaccepted',
        _ownStreamAcceptance,
        [
          ('open', [], 1),
          ('write-status', [], 4294967295),
          ('first', [], 50),
          ('second', [], 51),
          ('cancel', [], 2),
          ('first', [], 50),
          ('second', [], 51),
          ('sum', [], 0),
          ('drop-first', [], null),
          ('sum', [], 50),
          ('drop-second', [], null),
          ('sum', [], 101),
          ('close-reader', [], null),
        ],
      ),
      (
        'own-future-accepted-prefix',
        _ownFutureAcceptance,
        [
          ('open', [], 1),
          ('write-status', [], 4294967295),
          ('first', [], 50),
          ('receive', [], 0),
          ('sentinel', [], 3735928559),
          ('first', [], 'trap'),
          ('sum', [], 0),
          ('drop-received', [], null),
          ('sum', [], 50),
          ('cancel', [], 0),
          ('close-reader', [], null),
          ('close', [], null),
        ],
      ),
      (
        'own-future-cancel-unaccepted',
        _ownFutureAcceptance,
        [
          ('open', [], 1),
          ('write-status', [], 4294967295),
          ('first', [], 50),
          ('cancel', [], 2),
          ('first', [], 50),
          ('sum', [], 0),
          ('drop-first', [], null),
          ('sum', [], 50),
          ('close-reader', [], null),
        ],
      ),
    ];

const _ownStreamAcceptance = r'''
(component
 (component $producer
  (core module $memory (memory (export "mem") 1))
  (core instance $memory (instantiate $memory))
  (core module $counter
   (global $sum (mut i32) (i32.const 0))
   (func (export "dtor") (param i32) global.get $sum local.get 0 i32.add global.set $sum)
   (func (export "sum") (result i32) global.get $sum))
  (core instance $counter (instantiate $counter))
  (type $r (resource (rep i32) (dtor (core func $counter "dtor"))))
  (export $re "r" (type $r))
  (type $channel (stream (own $r)))
  (core func $rnew (canon resource.new $r)) (core func $rrep (canon resource.rep $r)) (core func $rdrop (canon resource.drop $r))
  (core func $new (canon stream.new $channel))
  (core func $write (canon stream.write $channel async (memory (core memory $memory "mem"))))
  (core func $cancel (canon stream.cancel-write $channel))
  (core func $close (canon stream.drop-writable $channel))
  (core module $p
   (import "h" "mem" (memory 1))
   (import "h" "rnew" (func $rnew (param i32) (result i32)))
   (import "h" "rrep" (func $rrep (param i32) (result i32)))
   (import "h" "rdrop" (func $rdrop (param i32)))
   (import "h" "new" (func $new (result i64)))
   (import "h" "write" (func $write (param i32 i32 i32) (result i32)))
   (import "h" "cancel" (func $cancel (param i32) (result i32)))
   (import "h" "close" (func $close (param i32)))
   (global $writer (mut i32) (i32.const 0)) (global $status (mut i32) (i32.const 0))
   (global $first (mut i32) (i32.const 0)) (global $second (mut i32) (i32.const 0))
   (func (export "start") (result i32) (local $pair i64)
    call $new local.set $pair
    local.get $pair i64.const 32 i64.shr_u i32.wrap_i64 global.set $writer
    i32.const 50 call $rnew global.set $first
    i32.const 8 global.get $first i32.store i32.const 51 call $rnew global.set $second i32.const 12 global.get $second i32.store
    global.get $writer i32.const 8 i32.const 2 call $write
    global.set $status
    local.get $pair i32.wrap_i64)
   (func (export "write-status") (result i32) global.get $status)
   (func (export "first") (result i32) global.get $first call $rrep)
   (func (export "second") (result i32) global.get $second call $rrep)
   (func (export "drop-first") global.get $first call $rdrop)
   (func (export "drop-second") global.get $second call $rdrop)
   (func (export "cancel") (result i32) global.get $writer call $cancel)
   (func (export "close") global.get $writer call $close))
  (core instance $h (export "mem" (memory $memory "mem")) (export "rnew" (func $rnew)) (export "rrep" (func $rrep)) (export "rdrop" (func $rdrop)) (export "new" (func $new)) (export "write" (func $write)) (export "cancel" (func $cancel)) (export "close" (func $close)))
  (core instance $p (instantiate $p (with "h" (instance $h))))
  (func (export "start") (result (stream (own $re))) (canon lift (core func $p "start")))
  (func (export "write-status") (result u32) (canon lift (core func $p "write-status")))
  (func (export "first") (result u32) (canon lift (core func $p "first")))
  (func (export "second") (result u32) (canon lift (core func $p "second")))
  (func (export "drop-first") (canon lift (core func $p "drop-first")))
  (func (export "drop-second") (canon lift (core func $p "drop-second")))
  (func (export "cancel") (result u32) (canon lift (core func $p "cancel")))
  (func (export "close") (canon lift (core func $p "close")))
  (func (export "sum") (result u32) (canon lift (core func $counter "sum"))))
 (component $consumer
  (import "p" (instance $p (export "r" (type $r (sub resource))) (export "start" (func (result (stream (own $r)))))))
  (alias export $p "r" (type $r))
  (type $channel (stream (own $r)))
  (core module $memory (memory (export "mem") 1)) (core instance $memory (instantiate $memory))
  (core func $start (canon lower (func $p "start")))
  (core func $read (canon stream.read $channel async (memory (core memory $memory "mem"))))
  (core func $drop (canon resource.drop $r))
  (core func $rcancel (canon stream.cancel-read $channel))
  (core func $close (canon stream.drop-readable $channel))
  (core module $c
   (import "h" "mem" (memory 1))
   (import "h" "start" (func $start (result i32)))
   (import "h" "read" (func $read (param i32 i32 i32) (result i32)))
   (import "h" "drop" (func $drop (param i32)))
   (import "h" "rcancel" (func $rcancel (param i32) (result i32)))
   (import "h" "close" (func $close (param i32)))
   (global $last-read (mut i32) (i32.const 0)) (global $reader (mut i32) (i32.const 0)) (global $received (mut i32) (i32.const 0))
   (func (export "open") (result i32) call $start global.set $reader global.get $reader)
   (func (export "receive") (result i32) (local $status i32)
    i32.const 8 i64.const -2401053088876216593 i64.store
    global.get $reader i32.const 8 i32.const 1 call $read local.set $status
    i32.const 8 i32.load global.set $received local.get $status global.set $last-read local.get $status)
   (func (export "abort-read") global.get $last-read i32.const -1 i32.eq if global.get $reader call $rcancel drop end)
   (func (export "sentinel") (result i32) i32.const 12 i32.load)
   (func (export "drop-received") global.get $received call $drop)
   (func (export "close-reader") global.get $reader call $close))
  (core instance $h (export "mem" (memory $memory "mem")) (export "start" (func $start)) (export "read" (func $read)) (export "drop" (func $drop)) (export "rcancel" (func $rcancel)) (export "close" (func $close)))
  (core instance $c (instantiate $c (with "h" (instance $h))))
  (func (export "open") (result u32) (canon lift (core func $c "open")))
  (func (export "receive") (result u32) (canon lift (core func $c "receive")))
  (func (export "abort-read") (canon lift (core func $c "abort-read")))
  (func (export "sentinel") (result u32) (canon lift (core func $c "sentinel")))
  (func (export "drop-received") (canon lift (core func $c "drop-received")))
  (func (export "close-reader") (canon lift (core func $c "close-reader"))))
 (instance $producer (instantiate $producer))
 (instance $consumer (instantiate $consumer (with "p" (instance $producer))))
 (func (export "write-status") (alias export $producer "write-status"))
(func (export "first") (alias export $producer "first"))
(func (export "second") (alias export $producer "second"))
(func (export "drop-first") (alias export $producer "drop-first"))
(func (export "drop-second") (alias export $producer "drop-second"))
(func (export "cancel") (alias export $producer "cancel"))
(func (export "close") (alias export $producer "close"))
(func (export "sum") (alias export $producer "sum"))
(func (export "open") (alias export $consumer "open"))
(func (export "receive") (alias export $consumer "receive"))
(func (export "abort-read") (alias export $consumer "abort-read"))
(func (export "sentinel") (alias export $consumer "sentinel"))
(func (export "drop-received") (alias export $consumer "drop-received"))
(func (export "close-reader") (alias export $consumer "close-reader"))
)

''';

const _ownFutureAcceptance = r'''
(component
 (component $producer
  (core module $memory (memory (export "mem") 1))
  (core instance $memory (instantiate $memory))
  (core module $counter
   (global $sum (mut i32) (i32.const 0))
   (func (export "dtor") (param i32) global.get $sum local.get 0 i32.add global.set $sum)
   (func (export "sum") (result i32) global.get $sum))
  (core instance $counter (instantiate $counter))
  (type $r (resource (rep i32) (dtor (core func $counter "dtor"))))
  (export $re "r" (type $r))
  (type $channel (future (own $r)))
  (core func $rnew (canon resource.new $r)) (core func $rrep (canon resource.rep $r)) (core func $rdrop (canon resource.drop $r))
  (core func $new (canon future.new $channel))
  (core func $write (canon future.write $channel async (memory (core memory $memory "mem"))))
  (core func $cancel (canon future.cancel-write $channel))
  (core func $close (canon future.drop-writable $channel))
  (core module $p
   (import "h" "mem" (memory 1))
   (import "h" "rnew" (func $rnew (param i32) (result i32)))
   (import "h" "rrep" (func $rrep (param i32) (result i32)))
   (import "h" "rdrop" (func $rdrop (param i32)))
   (import "h" "new" (func $new (result i64)))
   (import "h" "write" (func $write (param i32 i32) (result i32)))
   (import "h" "cancel" (func $cancel (param i32) (result i32)))
   (import "h" "close" (func $close (param i32)))
   (global $writer (mut i32) (i32.const 0)) (global $status (mut i32) (i32.const 0))
   (global $first (mut i32) (i32.const 0)) (global $second (mut i32) (i32.const 0))
   (func (export "start") (result i32) (local $pair i64)
    call $new local.set $pair
    local.get $pair i64.const 32 i64.shr_u i32.wrap_i64 global.set $writer
    i32.const 50 call $rnew global.set $first
    i32.const 8 global.get $first i32.store
    global.get $writer i32.const 8  call $write
    global.set $status
    local.get $pair i32.wrap_i64)
   (func (export "write-status") (result i32) global.get $status)
   (func (export "first") (result i32) global.get $first call $rrep)
   (func (export "second") (result i32) global.get $second call $rrep)
   (func (export "drop-first") global.get $first call $rdrop)
   (func (export "drop-second") global.get $second call $rdrop)
   (func (export "cancel") (result i32) global.get $writer call $cancel)
   (func (export "close") global.get $writer call $close))
  (core instance $h (export "mem" (memory $memory "mem")) (export "rnew" (func $rnew)) (export "rrep" (func $rrep)) (export "rdrop" (func $rdrop)) (export "new" (func $new)) (export "write" (func $write)) (export "cancel" (func $cancel)) (export "close" (func $close)))
  (core instance $p (instantiate $p (with "h" (instance $h))))
  (func (export "start") (result (future (own $re))) (canon lift (core func $p "start")))
  (func (export "write-status") (result u32) (canon lift (core func $p "write-status")))
  (func (export "first") (result u32) (canon lift (core func $p "first")))
  (func (export "second") (result u32) (canon lift (core func $p "second")))
  (func (export "drop-first") (canon lift (core func $p "drop-first")))
  (func (export "drop-second") (canon lift (core func $p "drop-second")))
  (func (export "cancel") (result u32) (canon lift (core func $p "cancel")))
  (func (export "close") (canon lift (core func $p "close")))
  (func (export "sum") (result u32) (canon lift (core func $counter "sum"))))
 (component $consumer
  (import "p" (instance $p (export "r" (type $r (sub resource))) (export "start" (func (result (future (own $r)))))))
  (alias export $p "r" (type $r))
  (type $channel (future (own $r)))
  (core module $memory (memory (export "mem") 1)) (core instance $memory (instantiate $memory))
  (core func $start (canon lower (func $p "start")))
  (core func $read (canon future.read $channel async (memory (core memory $memory "mem"))))
  (core func $drop (canon resource.drop $r))
  (core func $close (canon future.drop-readable $channel))
  (core module $c
   (import "h" "mem" (memory 1))
   (import "h" "start" (func $start (result i32)))
   (import "h" "read" (func $read (param i32 i32) (result i32)))
   (import "h" "drop" (func $drop (param i32)))
   (import "h" "close" (func $close (param i32)))
   (global $reader (mut i32) (i32.const 0)) (global $received (mut i32) (i32.const 0))
   (func (export "open") (result i32) call $start global.set $reader global.get $reader)
   (func (export "receive") (result i32) (local $status i32)
    i32.const 8 i64.const -2401053088876216593 i64.store
    global.get $reader i32.const 8  call $read local.set $status
    i32.const 8 i32.load global.set $received local.get $status)
   (func (export "sentinel") (result i32) i32.const 12 i32.load)
   (func (export "drop-received") global.get $received call $drop)
   (func (export "close-reader") global.get $reader call $close))
  (core instance $h (export "mem" (memory $memory "mem")) (export "start" (func $start)) (export "read" (func $read)) (export "drop" (func $drop)) (export "close" (func $close)))
  (core instance $c (instantiate $c (with "h" (instance $h))))
  (func (export "open") (result u32) (canon lift (core func $c "open")))
  (func (export "receive") (result u32) (canon lift (core func $c "receive")))
  (func (export "sentinel") (result u32) (canon lift (core func $c "sentinel")))
  (func (export "drop-received") (canon lift (core func $c "drop-received")))
  (func (export "close-reader") (canon lift (core func $c "close-reader"))))
 (instance $producer (instantiate $producer))
 (instance $consumer (instantiate $consumer (with "p" (instance $producer))))
 (func (export "write-status") (alias export $producer "write-status"))
(func (export "first") (alias export $producer "first"))
(func (export "second") (alias export $producer "second"))
(func (export "drop-first") (alias export $producer "drop-first"))
(func (export "drop-second") (alias export $producer "drop-second"))
(func (export "cancel") (alias export $producer "cancel"))
(func (export "close") (alias export $producer "close"))
(func (export "sum") (alias export $producer "sum"))
(func (export "open") (alias export $consumer "open"))
(func (export "receive") (alias export $consumer "receive"))
(func (export "sentinel") (alias export $consumer "sentinel"))
(func (export "drop-received") (alias export $consumer "drop-received"))
(func (export "close-reader") (alias export $consumer "close-reader"))
)

''';

const _canonicalThreadEvents = r'''
(component
  (type $r (resource (rep i32)))
  (core func $new (canon resource.new $r))
  (import "hold" (func $hold async (param "id" u32) (param "thread" u32)))
  (core func $hold (canon lower (func $hold) async))
  (core func $thread (canon thread.index))
  (core func $get (canon context.get i32 0))
  (core func $put (canon context.set i32 0))
  (core func $return (canon task.return (result u32)))
  (core func $drop (canon subtask.drop))
  (core func $join (canon waitable.join))
  (core func $setnew (canon waitable-set.new))
  (core func $setdrop (canon waitable-set.drop))
  (core module $main
    (import "h" "new" (func $new (param i32) (result i32)))
    (import "h" "hold" (func $hold (param i32 i32) (result i32)))
    (import "h" "thread" (func $thread (result i32)))
    (import "h" "get" (func $get (result i32)))
    (import "h" "put" (func $put (param i32)))
    (import "h" "return" (func $return (param i32)))
    (import "h" "drop" (func $drop (param i32)))
    (import "h" "join" (func $join (param i32 i32)))
    (import "h" "setnew" (func $setnew (result i32)))
    (import "h" "setdrop" (func $setdrop (param i32)))
    (global $packed (mut i32) (i32.const 0))
    (global $wait (mut i32) (i32.const 0))
    (global $event (mut i32) (i32.const 0))
    (global $index (mut i32) (i32.const 0))
    (global $state (mut i32) (i32.const 0))
    (func (export "seed") (result i32) i32.const 888 call $new)
    (func (export "run") (param $id i32) (result i32)
      (local $subtask i32) (local $set i32)
      local.get $id call $thread call $hold
      global.set $packed
      global.get $packed i32.const 15 i32.and i32.const 1 i32.ne if unreachable end
      global.get $packed i32.const 4 i32.shr_u local.set $subtask
      call $setnew local.tee $set call $put
      local.get $subtask local.get $set call $join
      local.get $set i32.const 4 i32.shl i32.const 2 i32.or
      global.set $wait global.get $wait)
    (func (export "callback") (param $event i32) (param $index i32) (param $state i32) (result i32)
      local.get $event global.set $event
      local.get $index global.set $index
      local.get $state global.set $state
      local.get $event i32.const 1 i32.ne if unreachable end
      local.get $state i32.const 2 i32.ne if unreachable end
      local.get $index i32.const 0 call $join
      local.get $index call $drop
      call $get call $setdrop
      call $thread call $return
      i32.const 0)
    (func (export "packed") (result i32) global.get $packed)
    (func (export "wait") (result i32) global.get $wait)
    (func (export "event") (result i32) global.get $event)
    (func (export "index") (result i32) global.get $index)
    (func (export "state") (result i32) global.get $state))
  (core instance $h
    (export "new" (func $new)) (export "hold" (func $hold)) (export "thread" (func $thread))
    (export "get" (func $get)) (export "put" (func $put)) (export "return" (func $return))
    (export "drop" (func $drop)) (export "join" (func $join))
    (export "setnew" (func $setnew)) (export "setdrop" (func $setdrop)))
  (core instance $main (instantiate $main (with "h" (instance $h))))
  (func (export "seed") (result u32) (canon lift (core func $main "seed")))
  (func (export "run") async (param "id" u32) (result u32)
    (canon lift (core func $main "run") async (callback (core func $main "callback"))))
  (func (export "packed") (result u32) (canon lift (core func $main "packed")))
  (func (export "wait") (result u32) (canon lift (core func $main "wait")))
  (func (export "event") (result u32) (canon lift (core func $main "event")))
  (func (export "index") (result u32) (canon lift (core func $main "index")))
  (func (export "state") (result u32) (canon lift (core func $main "state"))))

''';

const _canonicalSyncBorrow = r'''
(component
 (import "visit" (func $visit (param "rep" u32)))
 (component $def
  (import "visit" (func $visit (param "rep" u32)))
  (core func $visit (canon lower (func $visit)))
  (core module $state
   (global $sum (mut i32) (i32.const 0))
   (func (export "dtor") (param i32) global.get $sum local.get 0 i32.add global.set $sum)
   (func (export "sum") (result i32) global.get $sum))
  (core instance $state (instantiate $state))
  (type $r (resource (rep i32) (dtor (core func $state "dtor"))))
  (export $re "r" (type $r))
  (core func $new (canon resource.new $r))
  (core module $m
   (import "h" "new" (func $new (param i32) (result i32)))
   (import "h" "visit" (func $visit (param i32)))
   (func (export "make") (result i32) i32.const 100 call $new)
   (func (export "inspect") (param i32) local.get 0 call $visit))
  (core instance $h (export "new" (func $new)) (export "visit" (func $visit)))
  (core instance $m (instantiate $m (with "h" (instance $h))))
  (func (export "make") (result (own $re)) (canon lift (core func $m "make")))
  (func (export "inspect") (param "h" (borrow $re)) (canon lift (core func $m "inspect")))
  (func (export "sum") (result u32) (canon lift (core func $state "sum"))))
 (component $user
  (import "def" (instance $def
   (export "r" (type $r (sub resource)))
   (export "make" (func (result (own $r))))
   (export "inspect" (func (param "h" (borrow $r))))))
  (alias export $def "r" (type $r))
  (core func $make (canon lower (func $def "make")))
  (core func $inspect (canon lower (func $def "inspect")))
  (core func $drop (canon resource.drop $r))
  (core module $m
   (import "h" "make" (func $make (result i32)))
   (import "h" "inspect" (func $inspect (param i32)))
   (import "h" "drop" (func $drop (param i32)))
   (global $owner (mut i32) (i32.const 0))
   (func (export "begin") call $make global.set $owner global.get $owner call $inspect)
   (func (export "drop-owner") global.get $owner call $drop))
  (core instance $h (export "make" (func $make)) (export "inspect" (func $inspect)) (export "drop" (func $drop)))
  (core instance $m (instantiate $m (with "h" (instance $h))))
  (func (export "begin") (canon lift (core func $m "begin")))
  (func (export "drop-owner") (canon lift (core func $m "drop-owner"))))
 (instance $def (instantiate $def (with "visit" (func $visit))))
 (instance $user (instantiate $user (with "def" (instance $def))))
 (func (export "sum") (alias export $def "sum"))
 (func (export "begin") (alias export $user "begin"))
 (func (export "drop-owner") (alias export $user "drop-owner")))

''';

const _canonicalAsyncBorrow = r'''
(component
 (import "hold" (func $hold async (param "rep" u32)))
 (component $def
  (import "hold" (func $hold async (param "rep" u32)))
  (core func $hold (canon lower (func $hold) async))
  (core module $state
   (global $sum (mut i32) (i32.const 0))
   (func (export "dtor") (param i32) global.get $sum local.get 0 i32.add global.set $sum)
   (func (export "sum") (result i32) global.get $sum))
  (core instance $state (instantiate $state))
  (type $r (resource (rep i32) (dtor (core func $state "dtor"))))
  (export $re "r" (type $r))
  (core func $new (canon resource.new $r))
  (core func $return (canon task.return))
  (core func $join (canon waitable.join))
  (core func $drop (canon subtask.drop))
  (core func $setnew (canon waitable-set.new))
  (core func $setdrop (canon waitable-set.drop))
  (core module $m
   (import "h" "hold" (func $hold (param i32) (result i32)))
   (import "h" "new" (func $new (param i32) (result i32)))
   (import "h" "return" (func $return))
   (import "h" "join" (func $join (param i32 i32)))
   (import "h" "drop" (func $drop (param i32)))
   (import "h" "setnew" (func $setnew (result i32)))
   (import "h" "setdrop" (func $setdrop (param i32)))
   (global $set (mut i32) (i32.const 0))
   (func (export "make") (result i32) i32.const 100 call $new)
   (func (export "inspect") (param $rep i32) (result i32) (local $subtask i32)
    local.get $rep call $hold i32.const 4 i32.shr_u local.set $subtask
    call $setnew global.set $set
    local.get $subtask global.get $set call $join
    global.get $set i32.const 4 i32.shl i32.const 2 i32.or)
   (func (export "callback") (param $event i32) (param $index i32) (param $state i32) (result i32)
    local.get $event i32.const 1 i32.ne if unreachable end
    local.get $state i32.const 2 i32.ne if unreachable end
    local.get $index i32.const 0 call $join
    local.get $index call $drop
    global.get $set call $setdrop
    call $return i32.const 0))
  (core instance $h (export "hold" (func $hold)) (export "new" (func $new)) (export "return" (func $return)) (export "join" (func $join)) (export "drop" (func $drop)) (export "setnew" (func $setnew)) (export "setdrop" (func $setdrop)))
  (core instance $m (instantiate $m (with "h" (instance $h))))
  (func (export "make") (result (own $re)) (canon lift (core func $m "make")))
  (func (export "inspect") async (param "h" (borrow $re)) (canon lift (core func $m "inspect") async (callback (core func $m "callback"))))
  (func (export "sum") (result u32) (canon lift (core func $state "sum"))))
 (component $user
  (import "def" (instance $def
   (export "r" (type $r (sub resource)))
   (export "make" (func (result (own $r))))
   (export "inspect" (func async (param "h" (borrow $r))))))
  (alias export $def "r" (type $r))
  (core module $memory (memory (export "mem") 1))
  (core instance $memory (instantiate $memory))
  (core func $make (canon lower (func $def "make")))
  (core func $inspect (canon lower (func $def "inspect") async))
  (core func $drop (canon resource.drop $r))
  (core func $join (canon waitable.join))
  (core func $subdrop (canon subtask.drop))
  (core func $setnew (canon waitable-set.new))
  (core func $setdrop (canon waitable-set.drop))
  (core func $poll (canon waitable-set.poll (memory (core memory $memory "mem"))))
  (core module $m
   (import "h" "mem" (memory 1))
   (import "h" "make" (func $make (result i32)))
   (import "h" "inspect" (func $inspect (param i32) (result i32)))
   (import "h" "drop" (func $drop (param i32)))
   (import "h" "join" (func $join (param i32 i32)))
   (import "h" "subdrop" (func $subdrop (param i32)))
   (import "h" "setnew" (func $setnew (result i32)))
   (import "h" "setdrop" (func $setdrop (param i32)))
   (import "h" "poll" (func $poll (param i32 i32) (result i32)))
   (global $owner (mut i32) (i32.const 0))
   (global $subtask (mut i32) (i32.const 0))
   (global $set (mut i32) (i32.const 0))
   (func (export "begin") (result i32) (local $packed i32)
    call $make global.set $owner
    global.get $owner call $inspect local.tee $packed
    i32.const 4 i32.shr_u global.set $subtask
    call $setnew global.set $set
    global.get $subtask global.get $set call $join
    local.get $packed)
   (func (export "drop-owner") global.get $owner call $drop)
   (func (export "poll") (result i32) global.get $set i32.const 32 call $poll)
   (func (export "event-index") (result i32) i32.const 32 i32.load)
   (func (export "event-state") (result i32) i32.const 36 i32.load)
   (func (export "finish")
    global.get $subtask i32.const 0 call $join
    global.get $subtask call $subdrop
    global.get $set call $setdrop))
  (core instance $h (export "mem" (memory $memory "mem")) (export "make" (func $make)) (export "inspect" (func $inspect)) (export "drop" (func $drop)) (export "join" (func $join)) (export "subdrop" (func $subdrop)) (export "setnew" (func $setnew)) (export "setdrop" (func $setdrop)) (export "poll" (func $poll)))
  (core instance $m (instantiate $m (with "h" (instance $h))))
  (func (export "begin") (result u32) (canon lift (core func $m "begin")))
  (func (export "drop-owner") (canon lift (core func $m "drop-owner")))
  (func (export "poll") (result u32) (canon lift (core func $m "poll")))
  (func (export "event-index") (result u32) (canon lift (core func $m "event-index")))
  (func (export "event-state") (result u32) (canon lift (core func $m "event-state")))
  (func (export "finish") (canon lift (core func $m "finish"))))
 (instance $def (instantiate $def (with "hold" (func $hold))))
 (instance $user (instantiate $user (with "def" (instance $def))))
 (func (export "sum") (alias export $def "sum"))
 (func (export "begin") (alias export $user "begin"))
 (func (export "drop-owner") (alias export $user "drop-owner"))
 (func (export "poll") (alias export $user "poll"))
 (func (export "event-index") (alias export $user "event-index"))
 (func (export "event-state") (alias export $user "event-state"))
 (func (export "finish") (alias export $user "finish")))

''';

String _canonicalOwnedTuple(int width, {required bool asynchronous}) {
  final owners = List.filled(width, '(own \$exported)').join(' ');
  final flat = width <= 16;
  final params = flat ? List.filled(width, 'i32').join(' ') : 'i32';
  final arguments = [
    for (var i = 0; i < width; i++)
      flat ? 'local.get $i' : 'local.get 0 i32.load offset=${i * 4}',
  ];
  final stores = [
    for (var i = 0; i < width; i++)
      'i32.const ${64 + i * 4} i32.const ${i + 1} call \$new i32.store',
  ].join('\n');
  final asyncBody = flat
      ? '${[for (var i = 0; i < width; i++) 'i32.const ${i + 1} call \$new'].join(' ')} call \$return i32.const 0'
      : '$stores i32.const 64 call \$return i32.const 0';
  final make = asynchronous ? asyncBody : '$stores i32.const 64';
  return '''
(component
  (core module \$memory (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) i32.const 1024))
  (core instance \$memory (instantiate \$memory))
  (core module \$state
    (global \$sum (mut i32) (i32.const 0)) (global \$hits (mut i32) (i32.const 0))
    (func (export "dtor") (param i32) global.get \$sum local.get 0 i32.add global.set \$sum)
    (func (export "sum") (result i32) global.get \$sum)
    (func (export "hit") global.get \$hits i32.const 1 i32.add global.set \$hits)
    (func (export "hits") (result i32) global.get \$hits))
  (core instance \$state (instantiate \$state))
  (type \$r (resource (rep i32) (dtor (core func \$state "dtor"))))
  (export \$exported "r" (type \$r))
  (type \$owners (tuple $owners))
  (core func \$new (canon resource.new \$r))
  (core func \$drop (canon resource.drop \$r))
  ${asynchronous ? '(core func \$return (canon task.return (result \$owners) (memory (core memory \$memory "mem"))))' : ''}
  (core module \$m
    (import "h" "mem" (memory 1))
    (import "h" "new" (func \$new (param i32) (result i32)))
    (import "h" "drop" (func \$drop (param i32)))
    (import "h" "sum" (func \$sum (result i32)))
    (import "h" "hit" (func \$hit))
    ${asynchronous ? '(import "h" "return" (func \$return (param $params)))' : ''}
    (func (export "make") (result i32) $make)
    (func (export "take") (param $params) (result i32)
      call \$hit
      ${arguments.map((value) => '$value call \$drop').join('\n')}
      call \$sum)
    (func (export "callback") (param i32 i32 i32) (result i32) unreachable))
  (core instance \$h
    (export "mem" (memory \$memory "mem")) (export "new" (func \$new)) (export "drop" (func \$drop))
    (export "sum" (func \$state "sum")) (export "hit" (func \$state "hit"))
    ${asynchronous ? '(export "return" (func \$return))' : ''})
  (core instance \$m (instantiate \$m (with "h" (instance \$h))))
  (func (export "make") ${asynchronous ? 'async' : ''} (result \$owners)
    (canon lift (core func \$m "make") ${asynchronous ? 'async (callback (core func \$m "callback"))' : ''} (memory (core memory \$memory "mem"))))
  (func (export "take") (param "owners" \$owners) (result u32)
    (canon lift (core func \$m "take") (memory (core memory \$memory "mem")) (realloc (core func \$memory "realloc"))))
  (func (export "sum") (result u32) (canon lift (core func \$state "sum")))
  (func (export "hits") (result u32) (canon lift (core func \$state "hits"))))
''';
}

const _canonicalBorrowCancellation = r'''
(component
  (core module $state
    (global $sum (mut i32) (i32.const 0))
    (func (export "dtor") (param i32) global.get $sum local.get 0 i32.add global.set $sum)
    (func (export "sum") (result i32) global.get $sum))
  (core instance $state (instantiate $state))
  (type $r (resource (rep i32) (dtor (core func $state "dtor"))))
  (export $exported "r" (type $r))
  (import "hold" (func $hold async (param "loan" (borrow $exported)) (result (own $exported))))
  (core module $memory (memory (export "mem") 1)) (core instance $memory (instantiate $memory))
  (core func $hold (canon lower (func $hold) async (memory (core memory $memory "mem"))))
  (core func $new (canon resource.new $r)) (core func $drop (canon resource.drop $r))
  (core func $cancel (canon subtask.cancel async)) (core func $subdrop (canon subtask.drop))
  (core func $setnew (canon waitable-set.new)) (core func $setdrop (canon waitable-set.drop))
  (core func $join (canon waitable.join)) (core func $poll (canon waitable-set.poll (memory (core memory $memory "mem"))))
  (core module $m
    (import "h" "mem" (memory 1))
    (import "h" "hold" (func $hold (param i32 i32) (result i32)))
    (import "h" "new" (func $new (param i32) (result i32))) (import "h" "drop" (func $drop (param i32)))
    (import "h" "cancel" (func $cancel (param i32) (result i32))) (import "h" "subdrop" (func $subdrop (param i32)))
    (import "h" "setnew" (func $setnew (result i32))) (import "h" "setdrop" (func $setdrop (param i32)))
    (import "h" "join" (func $join (param i32 i32))) (import "h" "poll" (func $poll (param i32 i32) (result i32)))
    (global $owner (mut i32) (i32.const 0)) (global $sub (mut i32) (i32.const 0)) (global $set (mut i32) (i32.const 0))
    (func (export "begin") (result i32) (local $packed i32)
      i32.const 100 call $new global.set $owner
      global.get $owner i32.const 64 call $hold local.tee $packed i32.const 4 i32.shr_u global.set $sub
      call $setnew global.set $set global.get $sub global.get $set call $join local.get $packed)
    (func (export "cancel") (result i32) global.get $sub call $cancel)
    (func (export "drop-owner") global.get $owner call $drop)
    (func (export "poll") (result i32) global.get $set i32.const 32 call $poll)
    (func (export "event-state") (result i32) i32.const 36 i32.load)
    (func (export "finish") global.get $sub i32.const 0 call $join global.get $sub call $subdrop global.get $set call $setdrop))
  (core instance $h (export "mem" (memory $memory "mem")) (export "hold" (func $hold)) (export "new" (func $new)) (export "drop" (func $drop))
    (export "cancel" (func $cancel)) (export "subdrop" (func $subdrop)) (export "setnew" (func $setnew)) (export "setdrop" (func $setdrop)) (export "join" (func $join)) (export "poll" (func $poll)))
  (core instance $m (instantiate $m (with "h" (instance $h))))
  (func (export "begin") (result u32) (canon lift (core func $m "begin")))
  (func (export "cancel") (result u32) (canon lift (core func $m "cancel")))
  (func (export "drop-owner") (canon lift (core func $m "drop-owner")))
  (func (export "poll") (result u32) (canon lift (core func $m "poll")))
  (func (export "event-state") (result u32) (canon lift (core func $m "event-state")))
  (func (export "finish") (canon lift (core func $m "finish")))
  (func (export "make-extra") (param "rep" u32) (result (own $exported)) (canon lift (core func $new)))
  (func (export "sum") (result u32) (canon lift (core func $state "sum"))))
''';
