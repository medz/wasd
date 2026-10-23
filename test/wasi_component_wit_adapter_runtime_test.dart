import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/standard_wit.dart';
import 'package:wasd/src/wasi/component/wit_adapter.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('WIT named interface adapters', () {
    test('nested include with can rename a plain empty interface binding', () {
      final document = WASIComponentWitDocument.parse('''
interface store {}
world base { import cache: store; }
world middle { include base with { cache as primary } }
world command { include middle with { primary as renamed } }
''');
      expect(
        wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('command')!,
        ),
        isEmpty,
      );
    });

    test('invokes distinct labels and keeps external IDs as metadata', () {
      final document = WASIComponentWitDocument.parse('''
package acme:db;
interface store { get: func() -> u32; }
world command {
  @external-id("same-id") import one: store;
  @external-id("same-id") import two: store;
  export result: store;
}
''');
      final functions = wasiComponentWitWorldFunctions(
        document,
        document.worldNamed('command')!,
      );
      expect(functions.map((f) => f.qualifiedName), [
        'one.get',
        'two.get',
        'result.get',
      ]);
      final program = WASIComponentWitAdapterProgram.bind(
        functions,
        imports: {'one.get': (_) => _u32(11), 'two.get': (_) => _u32(22)},
        exports: {'result.get': (_) => _u32(33)},
      );
      expect(program.invokeImport('one.get', []), 11);
      expect(program.invokeImport('two.get', []), 22);
      expect(program.invokeExport('result.get', []), 33);
      expect(() => program.invokeImport('same-id.get', []), throwsStateError);
    });

    test('include with renames callbacks and preserves interface metadata', () {
      final document = WASIComponentWitDocument.parse('''
package acme:db;
interface store { @external-id("Read") get: func() -> u32; }
world base { @external-id("DB") import cache: store; }
world command {
  import cache: store;
  include base with { cache as renamed }
}
''');
      final functions = wasiComponentWitWorldFunctions(
        document,
        document.worldNamed('command')!,
      );
      expect(functions.map((f) => f.qualifiedName), [
        'cache.get',
        'renamed.get',
      ]);
      expect(functions.last.item.target.text, 'store');
      expect(functions.last.item.externalId, 'DB');
      expect(functions.last.function.externalId, 'Read');
      final program = WASIComponentWitAdapterProgram.bind(
        functions,
        imports: {'cache.get': (_) => _u32(1), 'renamed.get': (_) => _u32(2)},
      );
      expect(program.invokeImport('renamed.get', []), 2);
    });

    test('resolves a named qualified target using its interface path', () {
      final dependency = WASIComponentWitDocument.parse('''
package acme:db@1.0.0;
interface store { get: func() -> u32; }
''');
      final document = WASIComponentWitDocument.parse('''
world command { import remote: acme:db/store@1.0.0; }
''');
      final seen = <String>[];
      final functions = wasiComponentWitWorldFunctions(
        document,
        document.worldNamed('command')!,
        resolveTarget: (target) {
          seen.add(target);
          return WASIComponentWitResolvedTarget(
            document: dependency,
            memberName: 'store',
          );
        },
      );
      expect(seen, ['acme:db/store@1.0.0']);
      expect(functions.single.qualifiedName, 'remote.get');
      final program = WASIComponentWitAdapterProgram.bind(
        functions,
        imports: {'remote.get': (_) => 42},
      );
      expect(program.invokeImport('remote.get', []), 42);
    });

    test('include with rejects interface names and missing labels', () {
      for (final rename in ['store as other', 'missing as other']) {
        final document = WASIComponentWitDocument.parse('''
interface store { get: func() -> u32; }
world base { import store; }
world command { include base with { $rename } }
''');
        expect(
          () => wasiComponentWitWorldFunctions(
            document,
            document.worldNamed('command')!,
          ),
          throwsA(isA<WASIComponentWitTargetResolutionException>()),
        );
      }
    });

    test(
      'copies local resources per named instance and shares used resources',
      () {
        final document = WASIComponentWitDocument.parse('''
interface shared { resource bucket; }
interface store {
  use shared.{bucket as shared-bucket};
  resource bucket { constructor(); read: func() -> u32; }
  open-shared: func() -> shared-bucket;
}
world base { import cache: store; }
world command { include base with { cache as one } import two: store; }
''');
        final functions = wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('command')!,
        );
        WASIComponentWitFunctionBinding named(String name) =>
            functions.singleWhere((function) => function.qualifiedName == name);
        final one = named('one.bucket.constructor').signature.result!;
        final two = named('two.bucket.constructor').signature.result!;
        final method = named('one.bucket.read').signature.params.single.type;
        expect(one.resourceIdentity, isNotNull);
        expect(one.resourceIdentity, isNot(same(two.resourceIdentity)));
        expect(method.resourceIdentity, same(one.resourceIdentity));
        expect(method.isBorrowedResource, isTrue);
        expect(
          named('one.open-shared').signature.result!.resourceIdentity,
          same(named('two.open-shared').signature.result!.resourceIdentity),
        );
      },
    );
  });

  group('WIT borrowed resource reexports', () {
    for (final renamed in [false, true]) {
      test('resolves local two-hop use chains renamed=$renamed', () {
        final intermediate = renamed ? 'shared-token' : 'token';
        final selected = renamed ? 'selected-token' : 'token';
        final bridgeUse = renamed ? 'token as $intermediate' : 'token';
        final apiUse = renamed ? '$intermediate as $selected' : 'token';
        final document = WASIComponentWitDocument.parse('''
interface definitions { resource token; }
interface bridge { use definitions.{$bridgeUse}; }
interface api {
  use bridge.{$apiUse};
  roundtrip: func(value: borrow<$selected>) -> $selected;
}
world command { import api; }
''');
        final functions = wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('command')!,
        );
        expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
        final signature = functions.single.signature;
        final borrowed = signature.params.single.type;
        final owned = signature.result!;
        final owner = document
            .interfaceNamed('definitions')!
            .resourceNamed('token');
        expect(borrowed.resourceIdentity, same(owner));
        expect(owned.resourceIdentity, same(owner));
        expect(borrowed.resourceName, selected);
        expect(borrowed.isBorrowedResource, isTrue);
        expect(owned.isBorrowedResource, isFalse);
        var calls = 0;
        final program = WASIComponentWitAdapterProgram.bind(
          functions,
          imports: {
            'api.roundtrip': (args) {
              calls++;
              return args.single;
            },
          },
        );
        expect(program.invokeImport('api.roundtrip', [17]), 17);
        expect(calls, 1);
        expect(
          () => program.invokeImport('api.roundtrip', [-1]),
          throwsStateError,
        );
        expect(calls, 1);
      });
    }

    test('resolves stable io streams error to its declaring resource', () {
      final document = WASIComponentWitDocument.parse('''
interface filesystem {
  use wasi:io/streams@0.2.12.{error as stream-error};
  inspect: func(value: borrow<stream-error>) -> stream-error;
}
world command { import filesystem; }
''');
      final functions = wasiComponentWitWorldFunctions(
        document,
        document.worldNamed('command')!,
        resolveTarget: resolveWASIComponentStandardWitTarget,
      );
      expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
      final owner = resolveWASIComponentStandardWitTarget(
        'wasi:io/error@0.2.12',
      )!.document.interfaceNamed('error')!.resourceNamed('error');
      final signature = functions.single.signature;
      final borrowed = signature.params.single.type;
      expect(borrowed.isBorrowedResource, isTrue);
      expect(borrowed.resourceName, 'stream-error');
      expect(borrowed.resourceIdentity, same(owner));
      expect(signature.result!.resourceIdentity, same(owner));
      expect(signature.result!.isBorrowedResource, isFalse);
    });

    test('keeps same-named declaring resources nominally distinct', () {
      final document = WASIComponentWitDocument.parse('''
interface left { resource token; }
interface right { resource token; }
interface left-bridge { use left.{token}; }
interface right-bridge { use right.{token}; }
interface api {
  use left-bridge.{token as left-token};
  use right-bridge.{token as right-token};
  inspect: func(left: borrow<left-token>, right: borrow<right-token>)
    -> tuple<left-token, right-token>;
}
world command { import api; }
''');
      final functions = wasiComponentWitWorldFunctions(
        document,
        document.worldNamed('command')!,
      );
      expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
      final signature = functions.single.signature;
      final left = signature.params[0].type.resourceIdentity;
      final right = signature.params[1].type.resourceIdentity;
      expect(left, same(document.interfaceNamed('left')!.resources.single));
      expect(right, same(document.interfaceNamed('right')!.resources.single));
      expect(left, isNot(same(right)));
      expect(signature.result!.elements[0].resourceIdentity, same(left));
      expect(signature.result!.elements[1].resourceIdentity, same(right));
    });

    for (final throughUse in [false, true]) {
      test('resolves bare resource aliases throughUse=$throughUse', () {
        const definitions = '''
  resource token;
  type first = token;
  type second = first;
''';
        final selected = throughUse ? 'imported-token' : 'second';
        final document = WASIComponentWitDocument.parse('''
${throughUse ? 'interface definitions { $definitions }' : ''}
interface api {
  ${throughUse ? 'use definitions.{second as imported-token};' : definitions}
  roundtrip: func(value: borrow<$selected>) -> $selected;
}
world command { import api; }
''');
        final functions = wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('command')!,
        );
        expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
        final owner = document
            .interfaceNamed(throughUse ? 'definitions' : 'api')!
            .resourceNamed('token');
        final signature = functions.single.signature;
        expect(signature.params.single.type.resourceIdentity, same(owner));
        final resourceName = throughUse ? selected : 'token';
        expect(signature.params.single.type.resourceName, resourceName);
        expect(signature.params.single.type.text, 'borrow<$selected>');
        expect(signature.params.single.type.isBorrowedResource, isTrue);
        expect(signature.result!.resourceIdentity, same(owner));
        expect(signature.result!.resourceName, resourceName);
        expect(signature.result!.isBorrowedResource, isFalse);
      });

      for (final handle in ['borrow', 'own']) {
        test(
          'rejects borrowing a $handle handle alias throughUse=$throughUse',
          () {
            final definitions =
                '''
  resource token;
  type handle = $handle<token>;
''';
            final document = WASIComponentWitDocument.parse('''
${throughUse ? 'interface definitions { $definitions }' : ''}
interface api {
  ${throughUse ? 'use definitions.{handle};' : definitions}
  inspect: func(value: borrow<handle>);
  ${handle == 'borrow' ? 'plain: func(value: handle);' : ''}
}
world command { import api; }
''');
            final functions = wasiComponentWitWorldFunctions(
              document,
              document.worldNamed('command')!,
            );
            final errors = wasiComponentWitAdapterBindingErrors(functions);
            expect(errors, hasLength(1));
            expect(errors.single.function.qualifiedName, 'api.inspect');
            expect(errors.single.reason, isNotEmpty);
            expect(errors.single.reason.length, lessThan(512));
            var calls = 0;
            final program = WASIComponentWitAdapterProgram.bind(
              functions,
              imports: {
                for (final function in functions)
                  function.qualifiedName: (_) {
                    calls++;
                    return null;
                  },
              },
            );
            expect(
              () => program.invokeImport('api.inspect', [1]),
              throwsStateError,
            );
            expect(calls, 0);
            if (handle == 'borrow') {
              final plain = functions.last.signature;
              final owner = document
                  .interfaceNamed(throughUse ? 'definitions' : 'api')!
                  .resourceNamed('token');
              expect(plain.params.single.type.isBorrowedResource, isTrue);
              expect(plain.params.single.type.resourceIdentity, same(owner));
              expect(program.invokeImport('api.plain', [17]), isNull);
              expect(calls, 1);
            }
          },
        );
      }
    }

    test(
      'unrenamed borrowed aliases retain the existing owned resource name',
      () {
        final document = WASIComponentWitDocument.parse('''
interface definitions { resource token; type alias = token; }
interface api {
  use definitions.{alias};
  inspect: func(value: borrow<alias>) -> alias;
}
world command { import api; }
''');
        final functions = wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('command')!,
        );
        expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
        final signature = functions.single.signature;
        final borrowed = signature.params.single.type;
        final owned = signature.result!;
        expect(borrowed.text, 'borrow<alias>');
        expect(borrowed.resourceName, 'token');
        expect(owned.resourceName, 'token');
        expect(borrowed.resourceIdentity, same(owned.resourceIdentity));
      },
    );

    for (final partial in [false, true]) {
      test(
        'shares local and qualified package resource views partial=$partial',
        () {
          final document = WASIComponentWitDocument.parse('''
world command {
  import acme:store/front@1.0.0;
  import acme:store/back@1.0.0;
}
''');
          const package = 'package acme:store@1.0.0;';
          const front = '''
interface front {
  use back.{token};
  via: func(value: borrow<token>) -> token;
}
''';
          const back = '''
interface back {
  resource token;
  direct: func(value: borrow<token>) -> token;
}
''';
          final sources = {
            'acme:store/front@1.0.0': partial
                ? '$package interface back { resource token; } $front'
                : '$package $front $back',
            'acme:store/back@1.0.0': partial
                ? '$package $back'
                : '$package $front $back',
          };
          final functions = wasiComponentWitWorldFunctions(
            document,
            document.worldNamed('command')!,
            resolveTarget: (target) => WASIComponentWitResolvedTarget(
              document: WASIComponentWitDocument.parse(sources[target]!),
              memberName: target.contains('/front@') ? 'front' : 'back',
            ),
          );
          expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
          final via = functions
              .singleWhere(
                (f) => f.qualifiedName == 'acme:store/front@1.0.0.via',
              )
              .signature;
          final direct = functions
              .singleWhere(
                (f) => f.qualifiedName == 'acme:store/back@1.0.0.direct',
              )
              .signature;
          final owner = via.params.single.type.resourceIdentity;
          expect(via.result!.resourceIdentity, same(owner));
          expect(direct.params.single.type.resourceIdentity, same(owner));
          expect(direct.result!.resourceIdentity, same(owner));
        },
      );
    }

    test('shares qualified resource identity when the resolver reparses', () {
      final document = WASIComponentWitDocument.parse('''
interface api {
  use acme:relay/types@1.0.0.{token};
  use acme:origin/types@2.0.0.{token as other-token};
  pair: func(a: borrow<token>, b: borrow<token>) -> token;
  next: func(value: borrow<token>) -> token;
  other: func(value: borrow<other-token>) -> other-token;
}
interface consumer {
  use acme:origin/types@1.0.0.{token};
  roundtrip: func(value: borrow<token>) -> token;
}
world base { import api; }
world command { include base; import consumer; }
''');
      const sources = {
        'acme:relay/types@1.0.0': '''
package acme:relay@1.0.0;
interface types { use acme:origin/types@1.0.0.{token}; }
''',
        'acme:origin/types@1.0.0': '''
package acme:origin@1.0.0;
interface types { resource token; }
''',
        'acme:origin/types@2.0.0': '''
package acme:origin@2.0.0;
interface types { resource token; }
''',
      };
      final functions = wasiComponentWitWorldFunctions(
        document,
        document.worldNamed('command')!,
        resolveTarget: (target) => WASIComponentWitResolvedTarget(
          document: WASIComponentWitDocument.parse(sources[target]!),
          memberName: 'types',
        ),
      );
      expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
      WASIComponentWitAdapterSignature signature(String name) => functions
          .singleWhere((function) => function.qualifiedName == name)
          .signature;
      final pair = signature('api.pair');
      final owner = pair.params[0].type.resourceIdentity;
      expect(owner, isNotNull);
      expect(pair.params[1].type.resourceIdentity, same(owner));
      expect(pair.result!.resourceIdentity, same(owner));
      for (final name in ['api.next', 'consumer.roundtrip']) {
        final next = signature(name);
        expect(next.params.single.type.resourceIdentity, same(owner));
        expect(next.result!.resourceIdentity, same(owner));
      }
      final other = signature('api.other');
      final otherOwner = other.params.single.type.resourceIdentity;
      expect(otherOwner, isNot(same(owner)));
      expect(other.result!.resourceIdentity, same(otherOwner));
    });

    test(
      'fresh qualified resources stay shared across distinct local copies',
      () {
        final document = WASIComponentWitDocument.parse('''
interface store {
  resource local;
  type local-alias = local;
  use acme:origin/types@1.0.0.{token as shared};
  roundtrip: func(value: borrow<local-alias>, common: borrow<shared>)
    -> tuple<local-alias, shared>;
}
world command { import one: store; import two: store; }
''');
        final functions = wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('command')!,
          resolveTarget: (_) => WASIComponentWitResolvedTarget(
            document: WASIComponentWitDocument.parse('''
package acme:origin@1.0.0;
interface types { resource token; }
'''),
            memberName: 'types',
          ),
        );
        expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
        final one = functions[0].signature;
        final two = functions[1].signature;
        final local = one.params[0].type.resourceIdentity;
        final otherLocal = two.params[0].type.resourceIdentity;
        final shared = one.params[1].type.resourceIdentity;
        expect(local, isNot(same(otherLocal)));
        expect(one.result!.elements[0].resourceIdentity, same(local));
        expect(two.result!.elements[0].resourceIdentity, same(otherLocal));
        expect(one.result!.elements[1].resourceIdentity, same(shared));
        expect(two.params[1].type.resourceIdentity, same(shared));
        expect(two.result!.elements[1].resourceIdentity, same(shared));
        expect(shared, isNot(same(local)));
        expect(shared, isNot(same(otherLocal)));
      },
    );

    test('rejects a qualified cycle when the resolver reparses documents', () {
      final document = WASIComponentWitDocument.parse('''
interface api {
  use acme:first/bridge@1.0.0.{token};
  inspect: func(value: borrow<token>);
}
world command { import api; }
''');
      const sources = {
        'acme:first/bridge@1.0.0': '''
package acme:first@1.0.0;
interface bridge { use acme:second/bridge@1.0.0.{token}; }
''',
        'acme:second/bridge@1.0.0': '''
package acme:second@1.0.0;
interface bridge { use acme:first/bridge@1.0.0.{token}; }
''',
      };
      var resolutions = 0;
      final functions = wasiComponentWitWorldFunctions(
        document,
        document.worldNamed('command')!,
        resolveTarget: (target) {
          if (++resolutions > 4) {
            throw StateError('Resource cycle did not terminate.');
          }
          return WASIComponentWitResolvedTarget(
            document: WASIComponentWitDocument.parse(sources[target]!),
            memberName: 'bridge',
          );
        },
      );
      final errors = wasiComponentWitAdapterBindingErrors(functions);
      expect(errors, hasLength(1));
      expect(errors.single.reason, contains('recursive'));
      expect(errors.single.reason.length, lessThan(512));
      expect(resolutions, lessThanOrEqualTo(3));
    });

    for (final entry in <String, (String, String)>{
      'cycle': (
        '''
interface first { use second.{token}; }
interface second { use first.{token}; }
interface bridge { use first.{token}; }
''',
        'recursive',
      ),
      'bare alias cycle': (
        'interface bridge { type token = other; type other = token; }',
        'recursive',
      ),
      'missing target': (
        'interface bridge { use missing.{token}; }',
        'missing',
      ),
      'missing member': (
        '''
interface definitions { resource present; }
interface bridge { use definitions.{missing as token}; }
''',
        'missing',
      ),
      'nonresource': (
        '''
interface definitions { type token = u32; }
interface bridge { use definitions.{token}; }
''',
        'resource',
      ),
    }.entries) {
      test('rejects ${entry.key} before invoking a callback', () {
        final document = WASIComponentWitDocument.parse('''
${entry.value.$1}
interface api {
  use bridge.{token};
  inspect: func(value: borrow<token>);
}
world command { import api; }
''');
        final functions = wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('command')!,
        );
        final errors = wasiComponentWitAdapterBindingErrors(functions);
        expect(errors, hasLength(1));
        expect(errors.single.reason, contains(entry.value.$2));
        expect(errors.single.reason.length, lessThan(512));
        var calls = 0;
        final program = WASIComponentWitAdapterProgram.bind(
          functions,
          imports: {
            'api.inspect': (_) {
              calls++;
              return null;
            },
          },
        );
        expect(
          () => program.invokeImport('api.inspect', [1]),
          throwsStateError,
        );
        expect(calls, 0);
      });
    }
  });

  group('WIT map adapter runtime', () {
    test('preserves ordered duplicate keys through nested record and list', () {
      final map = _runtimeMap(<Object?>[
        _runtimePair('same', _runtimeList(<Object?>[_u32(1)])),
        _runtimePair('same', _runtimeList(<Object?>[_u32(2), _u32(3)])),
      ]);
      final record = _runtimeRecord(<Object?>[
        _runtimeList(<Object?>[map]),
      ]);
      final program = _bindMapWorld((args) => args.single);

      final result = program.invokeImport('tables.update', <Object?>[record]);

      expect(result, same(record));
      expect(map.itemValues, hasLength(2));
      expect(
        map.itemValues.map(
          (item) => (item! as WasmComponentValueData).itemValues.first,
        ),
        <Object?>['same', 'same'],
      );
    });

    test('rejects malformed map entries and validates keys and values', () {
      var calls = 0;
      final program = _bindMapWorld((args) {
        calls++;
        return args.single;
      });
      for (final map in <WasmComponentValueData>[
        _runtimeList(const <Object?>[]),
        _runtimeMap(<Object?>[
          _runtimeList(<Object?>['key', _u32(1)]),
        ]),
        _runtimeMap(<Object?>[_runtimePair(7, _runtimeList(<Object?>[]))]),
        _runtimeMap(<Object?>[
          _runtimePair('key', _runtimeList(<Object?>[_u32(-1)])),
        ]),
        _runtimeMap(<Object?>[
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.tuple,
            rawBytes: Uint8List(0),
            runtimeItems: const <Object?>['key'],
          ),
        ]),
      ]) {
        final value = _runtimeRecord(<Object?>[
          _runtimeList(<Object?>[map]),
        ]);
        expect(
          () => program.invokeImport('tables.update', <Object?>[value]),
          throwsStateError,
        );
      }
      expect(calls, 0);
    });

    test('validates returned map values', () {
      final argument = _runtimeRecord(<Object?>[
        _runtimeList(<Object?>[_runtimeMap(const <Object?>[])]),
      ]);
      final program = _bindMapWorld(
        (_) => _runtimeRecord(<Object?>[
          _runtimeList(<Object?>[
            _runtimeMap(<Object?>[_runtimePair('key', _u32(9))]),
          ]),
        ]),
      );

      expect(
        () => program.invokeImport('tables.update', <Object?>[argument]),
        throwsStateError,
      );
    });

    test('accepts component value tuple entries', () {
      final map = WasmComponentValueData(
        kind: WasmComponentValueDataKind.map,
        rawBytes: Uint8List(0),
        items: <WasmComponentValueData>[
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.tuple,
            rawBytes: Uint8List(0),
            items: <WasmComponentValueData>[
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.string,
                rawBytes: Uint8List(0),
                string: 'key',
              ),
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.list,
                rawBytes: Uint8List(0),
                items: <WasmComponentValueData>[_u32(5)],
              ),
            ],
          ),
        ],
      );
      final argument = _runtimeRecord(<Object?>[
        _runtimeList(<Object?>[map]),
      ]);
      final program = _bindMapWorld((args) => args.single);

      expect(
        program.invokeImport('tables.update', <Object?>[argument]),
        same(argument),
      );
    });
  });

  group('Preview3 WIT adapter runtime composites', () {
    test('validates stream endpoints inside records', () {
      final program = _bindRuntimeCompositeWorld(
        accept: (args) => args.single,
        collect: (_) => _runtimeList(const <Object?>[]),
      );
      final stream = WASIComponentStream<int>('record-stream');
      final record = _runtimeRecord(<Object?>[stream.readable, _u32(7)]);

      final result =
          program.invokeImport('runtime.accept', <Object?>[record])
              as WasmComponentValueData;

      expect(result, same(record));
      expect(result.items, isEmpty);
      expect(result.itemValues, hasLength(2));
      expect(result.itemValues.first, same(stream.readable));
      expect((result.itemValues.last as WasmComponentValueData).integer, 7);
    });

    test('validates future endpoints inside lists', () {
      final first = WASIComponentFuture<int>('first-future');
      final second = WASIComponentFuture<int>('second-future');
      final futures = _runtimeList(<Object?>[first.readable, second.readable]);
      final program = _bindRuntimeCompositeWorld(
        accept: (args) => args.single,
        collect: (_) => futures,
      );

      final result =
          program.invokeImport('runtime.collect', const <Object?>[])
              as WasmComponentValueData;

      expect(result, same(futures));
      expect(result.items, isEmpty);
      expect(result.itemValues, <Object?>[
        same(first.readable),
        same(second.readable),
      ]);
    });
  });
}

WASIComponentWitAdapterProgram _bindMapWorld(
  WASIComponentWitAdapterCallback update,
) {
  final document = WASIComponentWitDocument.parse('''
interface tables {
  type key = string;
  record batch { values: list<map<key, list<u32>>> }
  update: func(value: batch) -> batch;
}
world command { import tables; }
''');
  final functions = wasiComponentWitWorldFunctions(
    document,
    document.worldNamed('command')!,
  );
  expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
  return WASIComponentWitAdapterProgram.bind(
    functions,
    imports: <String, WASIComponentWitAdapterCallback>{'tables.update': update},
  );
}

WasmComponentValueData _runtimeMap(List<Object?> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.map,
    rawBytes: Uint8List(0),
    runtimeItems: List<Object?>.unmodifiable(items),
  );
}

WasmComponentValueData _runtimePair(Object? key, Object? value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    runtimeItems: <Object?>[key, value],
  );
}

WASIComponentWitAdapterProgram _bindRuntimeCompositeWorld({
  required WASIComponentWitAdapterCallback accept,
  required WASIComponentWitAdapterCallback collect,
}) {
  const source = '''
package acme:runtime@0.3.0;

interface runtime {
  record transfer {
    source: stream<u8>,
    sequence: u32,
  }

  accept: func(value: transfer) -> transfer;
  collect: func() -> list<future<u32>>;
}

world command {
  import runtime;
}
''';
  final plan = WASIPreview3ComponentHost().prepareWitWorld(
    WASIComponentWitDocument.parse(source),
    worldName: 'command',
  );
  expect(plan.canBindAdapters, isTrue, reason: plan.bindingErrors.toString());
  return plan.bindAdapters(
    imports: <String, WASIComponentWitAdapterCallback>{
      'runtime.accept': accept,
      'runtime.collect': collect,
    },
  );
}

WasmComponentValueData _runtimeRecord(List<Object?> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    runtimeItems: List<Object?>.unmodifiable(items),
  );
}

WasmComponentValueData _runtimeList(List<Object?> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    runtimeItems: List<Object?>.unmodifiable(items),
  );
}

WasmComponentValueData _u32(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}
