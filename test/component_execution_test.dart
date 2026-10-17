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
