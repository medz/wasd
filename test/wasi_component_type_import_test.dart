import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/preview2/component_runner.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

void main() {
  group('Component equality type imports', () {
    for (final fixture in [_eqNumber, _eqNumberChain]) {
      test(
        'forwards numeric ${fixture == _eqNumber ? 'type' : 'alias chain'}',
        () async {
          final host = WASIComponentHost();
          final runtime = WASIComponentNativeRuntime.component(
            component: _component(fixture),
            host: host,
          );
          try {
            expect(await runtime.invokeExport('run', [41]), 42);
          } finally {
            await runtime.dispose();
          }
          expect(host.table.activeCount, 0);
        },
      );
    }

    for (final fixture in [_eqRecordContext, _eqRecordStringShadowContext]) {
      test(
        'retains the source record type context with ${fixture == _eqRecordContext ? 'numeric' : 'string'} shadow',
        () async {
          final host = WASIComponentHost();
          final runtime = WASIComponentNativeRuntime.component(
            component: _component(fixture),
            host: host,
          );
          try {
            final result =
                await runtime.invokeExport('run', [
                      WasmComponentValueData(
                        kind: WasmComponentValueDataKind.record,
                        rawBytes: Uint8List(0),
                        runtimeItems: [300],
                      ),
                    ])
                    as WasmComponentValueData;
            expect(result.items.single.integer, 301);
          } finally {
            await runtime.dispose();
          }
          expect(host.table.activeCount, 0);
        },
      );
    }

    test(
      'requires canonical memory for a source string despite numeric shadow',
      () async {
        final component = WasmComponent.decode(
          base64Decode(_eqStringRecordContext),
        );
        final errors = component.validate();
        expect(
          errors.any(
            (error) => error.message.contains(
              'result lowering requires a memory option',
            ),
          ),
          isTrue,
        );
        expect(
          errors.any(
            (error) => error.message.contains(
              'parameter lifting requires a realloc option',
            ),
          ),
          isTrue,
        );
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: WASIComponentHost(),
        );
        try {
          await expectLater(
            runtime.initialize(),
            throwsA(isA<WASIPreview2ComponentExecutionException>()),
          );
        } finally {
          await runtime.dispose();
        }
      },
    );

    for (final equality in [false, true]) {
      test(
        'keeps registered abstract source ${equality ? 'through equality' : 'directly'}',
        () async {
          final host = WASIComponentHost();
          host.canonicalHost.resourceHost.defineResourceType<int>(0, 'source');
          final runtime = WASIComponentNativeRuntime.component(
            component: _component(
              equality ? _eqHostResource : _abstractRegistered,
            ),
            host: host,
          );
          try {
            expect(await runtime.invokeExport('run', []), equality ? 41 : 42);
          } finally {
            await runtime.dispose();
          }
          expect(host.table.activeCount, 0);
        },
      );
    }

    for (final registerAliases in [false, true]) {
      test(
        'uses source owner and destructor across aliases with noise=$registerAliases',
        () async {
          final host = WASIComponentHost();
          final sourceDrops = <int>[];
          final otherDrops = <int>[];
          final resourceHost = host.canonicalHost.resourceHost;
          final source = resourceHost.defineResourceType<int>(
            0,
            'same name',
            onDrop: sourceDrops.add,
          );
          final other = registerAliases
              ? resourceHost.defineResourceType<int>(
                  1,
                  'same name',
                  onDrop: otherDrops.add,
                )
              : host.table.defineType<int>('same name', onDrop: otherDrops.add);
          if (registerAliases) {
            resourceHost.defineResourceType<int>(
              2,
              'same name',
              onDrop: otherDrops.add,
            );
          }
          await host.table.runScoped(() async {
            final owner = host.table.insert(source, 7);
            final wrongOwner = host.table.insert(other, 11);
            final runtime = WASIComponentNativeRuntime.component(
              component: _component(_eqResourceChainDrop),
              host: host,
            );
            try {
              await runtime.initialize();
              await expectLater(
                runtime.invokeExport('drop', [wrongOwner]),
                throwsStateError,
              );
              expect(host.table.get(other, wrongOwner), 11);
              expect(sourceDrops, isEmpty);
              expect(otherDrops, isEmpty);
              await runtime.invokeExport('drop', [owner]);
              expect(sourceDrops, [7]);
              expect(otherDrops, isEmpty);
              expect(host.table.contains(owner), isFalse);
              await expectLater(
                runtime.invokeExport('drop', [owner]),
                throwsStateError,
              );
            } finally {
              await runtime.dispose();
            }
          });
          expect(sourceDrops, [7]);
          expect(otherDrops, [11]);
          expect(host.table.activeCount, 0);
        },
      );
    }

    test(
      'rejects an owner from another scope and preserves its source',
      () async {
        final host = WASIComponentHost();
        final dropped = <int>[];
        final source = host.canonicalHost.resourceHost.defineResourceType<int>(
          0,
          'source',
          onDrop: dropped.add,
        );
        await host.table.runScoped(() async {
          final owner = host.table.insert(source, 7);
          final runtime = WASIComponentNativeRuntime.component(
            component: _component(_eqResourceChainDrop),
            host: host,
          );
          try {
            await runtime.initialize();
            await host.table.runScoped(() async {
              await expectLater(
                runtime.invokeExport('drop', [owner]),
                throwsA(
                  isA<StateError>().having(
                    (error) => error.message,
                    'message',
                    contains('another runtime scope'),
                  ),
                ),
              );
            });
            expect(dropped, isEmpty);
            expect(host.table.get(source, owner), 7);
            await runtime.invokeExport('drop', [owner]);
            expect(dropped, [7]);
          } finally {
            await runtime.dispose();
          }
        });
        expect(dropped, [7]);
        expect(host.table.activeCount, 0);
      },
    );

    for (final registerOnlyAlias in [false, true]) {
      test(
        'rejects unregistered source with alias registration=$registerOnlyAlias',
        () async {
          final host = WASIComponentHost();
          if (registerOnlyAlias) {
            host.canonicalHost.resourceHost.defineResourceType<int>(
              1,
              'unrelated',
            );
          }
          final runtime = WASIComponentNativeRuntime.component(
            component: _component(_eqHostResource),
            host: host,
          );
          try {
            await expectLater(
              runtime.initialize(),
              throwsA(
                isA<WASIPreview2ComponentExecutionException>().having(
                  (error) => error.message,
                  'message',
                  contains('Unregistered abstract host resource `r`'),
                ),
              ),
            );
          } finally {
            await runtime.dispose();
          }
          expect(host.table.activeCount, 0);
        },
      );
    }

    test(
      'rejects an equality import that references an unavailable type',
      () async {
        final component = WasmComponent.decode(base64Decode(_invalidEqIndex));
        expect(component.validate(), isNotEmpty);
        final host = WASIComponentHost();
        final runtime = WASIComponentNativeRuntime.component(
          component: component,
          host: host,
        );
        try {
          await expectLater(
            runtime.initialize(),
            throwsA(
              isA<WASIPreview2ComponentExecutionException>().having(
                (error) => error.message,
                'message',
                contains('validation failed'),
              ),
            ),
          );
        } finally {
          await runtime.dispose();
        }
        expect(host.table.activeCount, 0);
      },
    );
  });
}

WasmComponent _component(String encoded) {
  final component = WasmComponent.decode(base64Decode(encoded));
  expect(component.validate(), isEmpty);
  return component;
}

// The fixtures below are encoded from the adjacent WAT with wasm-tools 1.262.0.
// (component
//  (type $number u32)
//  (import "same-number" (type $same (eq $number)))
//  (core module $m (func (export "run") (param i32) (result i32) local.get 0 i32.const 1 i32.add))
//  (core instance $m (instantiate $m))
//  (func (export "run") (param "value" $same) (result $same) (canon lift (core func $m "run"))))
const _eqNumber =
    'AGFzbQ0AAQAHAgF5ChEBAAtzYW1lLW51bWJlcgMAAAEzAGFzbQEAAAABBgFgAX8BfwMCAQAHBwEDcnVuAAAKCQEH'
    'ACAAQQFqCwAJBG5hbWUAAgFtAgQBAAAABwwBQAEFdmFsdWUBAAEGCQEAAAEAA3J1bggGAQAAAAACCwkBAANydW4B'
    'AAAAMQ5jb21wb25lbnQtbmFtZQEGABEBAAFtAQYAEgEAAW0BEAMCAAZudW1iZXIBBHNhbWU=';

// (component
//  (type $number u32)
//  (import "same-number" (type $same (eq $number)))
//  (import "same-again" (type $again (eq $same)))
//  (core module $m (func (export "run") (param i32) (result i32)
//    local.get 0 i32.const 1 i32.add))
//  (core instance $m (instantiate $m))
//  (func (export "run") (param "value" $again) (result $again)
//    (canon lift (core func $m "run"))))
const _eqNumberChain =
    'AGFzbQ0AAQAHAgF5CiACAAtzYW1lLW51bWJlcgMAAAAKc2FtZS1hZ2FpbgMAAQEzAGFzbQEAAAABBgFgAX8BfwMC'
    'AQAHBwEDcnVuAAAKCQEHACAAQQFqCwAJBG5hbWUAAgFtAgQBAAAABwwBQAEFdmFsdWUCAAIGCQEAAAEAA3J1bggG'
    'AQAAAAADCwkBAANydW4BAAAAOA5jb21wb25lbnQtbmFtZQEGABEBAAFtAQYAEgEAAW0BFwMDAAZudW1iZXIBBHNh'
    'bWUCBWFnYWlu';

// (component
//  (type $noise u8)
//  (import "types" (instance $types
//    (type $number u32)
//    (type $record (record (field "value" $number)))
//    (export "item" (type (eq $record)))))
//  (alias export $types "item" (type $item))
//  (import "same-item" (type $same (eq $item)))
//  (core module $m (func (export "run") (param i32) (result i32)
//    local.get 0 i32.const 1 i32.add))
//  (core instance $m (instantiate $m))
//  (func (export "run") (param "item" $same) (result $same)
//    (canon lift (core func $m "run"))))
const _eqRecordContext =
    'AGFzbQ0AAQAHGgJ9QgMBeQFyAQV2YWx1ZQAEAARpdGVtAwABCgoBAAV0eXBlcwUBBgkBAwAABGl0ZW0KDwEACXNh'
    'bWUtaXRlbQMAAgEzAGFzbQEAAAABBgFgAX8BfwMCAQAHBwEDcnVuAAAKCQEHACAAQQFqCwAJBG5hbWUAAgFtAgQB'
    'AAAABwsBQAEEaXRlbQMAAwYJAQAAAQADcnVuCAYBAAAAAAQLCQEAA3J1bgEAAABBDmNvbXBvbmVudC1uYW1lAQYA'
    'EQEAAW0BBgASAQABbQEVAwMABW5vaXNlAgRpdGVtAwRzYW1lAQkFAQAFdHlwZXM=';

// (component
//  (import "r" (type $r (sub resource)))
//  (import "same-r" (type $same (eq $r)))
//  (core module $m (func (export "run") (result i32) i32.const 41))
//  (core instance $m (instantiate $m))
//  (func (export "run") (result u32) (canon lift (core func $m "run"))))
const _eqHostResource =
    'AGFzbQ0AAQAKEQIAAXIDAQAGc2FtZS1yAwAAAS8AYXNtAQAAAAEFAWAAAX8DAgEABwcBA3J1bgAACgYBBABBKQsA'
    'CQRuYW1lAAIBbQIEAQAAAAcFAUAAAHkGCQEAAAEAA3J1bggGAQAAAAACCwkBAANydW4BAAAALA5jb21wb25lbnQt'
    'bmFtZQEGABEBAAFtAQYAEgEAAW0BCwMCAAFyAQRzYW1l';

// (component
//  (import "r" (type $r (sub resource)))
//  (core module $m (func (export "run") (result i32) i32.const 42))
//  (core instance $m (instantiate $m))
//  (func (export "run") (result u32) (canon lift (core func $m "run"))))
const _abstractRegistered =
    'AGFzbQ0AAQAKBgEAAXIDAQEvAGFzbQEAAAABBQFgAAF/AwIBAAcHAQNydW4AAAoGAQQAQSoLAAkEbmFtZQACAW0C'
    'BAEAAAAHBQFAAAB5BgkBAAABAANydW4IBgEAAAAAAQsJAQADcnVuAQAAACYOY29tcG9uZW50LW5hbWUBBgARAQAB'
    'bQEGABIBAAFtAQUDAQABcg==';

// (component
//  (import "r" (type $r (sub resource)))
//  (import "same-r" (type $same (eq $r)))
//  (import "same-again" (type $again (eq $same)))
//  (core func $drop (canon resource.drop $again))
//  (func (export "drop") (param "owner" (own $again))
//    (canon lift (core func $drop))))
const _eqResourceChainDrop =
    'AGFzbQ0AAQAKIAMAAXIDAQAGc2FtZS1yAwAAAApzYW1lLWFnYWluAwABCAMBAwIHDgJpAkABBW93bmVyAwEACAYB'
    'AAAAAAQLCgEABGRyb3ABAAAALg5jb21wb25lbnQtbmFtZQEJAAABAARkcm9wARIDAwABcgEEc2FtZQIFYWdhaW4=';

// (component (import "same" (type (eq 0))))
const _invalidEqIndex = 'AGFzbQ0AAQAKCgEABHNhbWUDAAA=';

// (component
//  (type $noise string)
//  (import "types" (instance $types
//    (type $number u32)
//    (type $record (record (field "value" $number)))
//    (export "item" (type (eq $record)))))
//  (alias export $types "item" (type $item))
//  (import "same-item" (type $same (eq $item)))
//  (core module $m (func (export "run") (param i32) (result i32)
//    local.get 0 i32.const 1 i32.add))
//  (core instance $m (instantiate $m))
//  (func (export "run") (param "item" $same) (result $same)
//    (canon lift (core func $m "run"))))
const _eqRecordStringShadowContext =
    'AGFzbQ0AAQAHGgJzQgMBeQFyAQV2YWx1ZQAEAARpdGVtAwABCgoBAAV0eXBlcwUBBgkBAwAABGl0ZW0KDwEACXNh'
    'bWUtaXRlbQMAAgEzAGFzbQEAAAABBgFgAX8BfwMCAQAHBwEDcnVuAAAKCQEHACAAQQFqCwAJBG5hbWUAAgFtAgQB'
    'AAAABwsBQAEEaXRlbQMAAwYJAQAAAQADcnVuCAYBAAAAAAQLCQEAA3J1bgEAAABBDmNvbXBvbmVudC1uYW1lAQYA'
    'EQEAAW0BBgASAQABbQEVAwMABW5vaXNlAgRpdGVtAwRzYW1lAQkFAQAFdHlwZXM=';

// (component
//  (type $noise u8)
//  (import "types" (instance $types
//    (type $number string)
//    (type $record (record (field "value" $number)))
//    (export "item" (type (eq $record)))))
//  (alias export $types "item" (type $item))
//  (import "same-item" (type $same (eq $item)))
//  (core module $m (func (export "run") (param i32 i32) (result i32)
//    unreachable))
//  (core instance $m (instantiate $m))
//  (func (export "run") (param "item" $same) (result $same)
//    (canon lift (core func $m "run"))))
const _eqStringRecordContext =
    'AGFzbQ0AAQAHGgJ9QgMBcwFyAQV2YWx1ZQAEAARpdGVtAwABCgoBAAV0eXBlcwUBBgkBAwAABGl0ZW0KDwEACXNh'
    'bWUtaXRlbQMAAgEwAGFzbQEAAAABBwFgAn9/AX8DAgEABwcBA3J1bgAACgUBAwAACwAJBG5hbWUAAgFtAgQBAAAA'
    'BwsBQAEEaXRlbQMAAwYJAQAAAQADcnVuCAYBAAAAAAQLCQEAA3J1bgEAAABBDmNvbXBvbmVudC1uYW1lAQYAEQEA'
    'AW0BBgASAQABbQEVAwMABW5vaXNlAgRpdGVtAwRzYW1lAQkFAQAFdHlwZXM=';
