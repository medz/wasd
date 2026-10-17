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
  (component \$child
    (import "types" (instance \$types (export "item" (type (sub resource)))))
    (alias export \$types "item" (type \$item))
    (alias outer 0 \$item (type \$same))
    (core func \$drop (canon resource.drop \$same))
    (func (export "drop") (param "handle" u32) (canon lift (core func \$drop))))
  (instance \$a (instantiate \$child (with "types" (instance \$one))))
  (instance \$b (instantiate \$child (with "types" (instance \$two))))
  (func (export "one") (alias export \$a "drop"))
  (func (export "two") (alias export \$b "drop")))
''');
        expect(component.validate(), isEmpty);
        final host = WASIComponentHost();
        var firstDrops = 0;
        var secondDrops = 0;
        final first = host.table.defineType<Object>(
          'one.item',
          onDrop: (_) => firstDrops++,
        );
        final second = host.table.defineType<Object>(
          'two.item',
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
      'rejects concrete local resource aliases before initialization',
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
        await expectLater(
          WASIComponentNativeRuntime.component(
            component: component,
            host: host,
          ).initialize(),
          throwsA(
            isA<WASIPreview2ComponentExecutionException>().having(
              (error) => error.message,
              'message',
              contains('Concrete local resource aliases are not executable'),
            ),
          ),
        );
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
