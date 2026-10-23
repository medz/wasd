import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/versioned_host.dart';
import 'package:wasd/src/wasi/component/wit_adapter.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';
import 'package:wasd/src/wasi/version.dart';

const _interfaces = '''
package test:world@1.0.0;
interface dep { resource token; ping: func(); }
interface service { use dep.{token}; run: func(value: borrow<token>); }
''';

List<WASIComponentWitFunctionBinding> _functions(String worlds) {
  final document = WASIComponentWitDocument.parse('$_interfaces$worlds');
  return wasiComponentWitWorldFunctions(
    document,
    document.worldNamed('command')!,
  );
}

List<String> _surface(List<WASIComponentWitFunctionBinding> functions) => [
  for (final function in functions)
    '${function.direction.name}:${function.qualifiedName}',
];

void main() {
  group('WIT world dependency elaboration', () {
    test('imports dependencies and binds their callbacks', () {
      final functions = _functions('world command { import service; }');
      expect(_surface(functions), ['import:dep.ping', 'import:service.run']);
      var calls = 0;
      final program = WASIComponentWitAdapterProgram.bind(
        functions,
        imports: {
          'dep.ping': (_) {
            calls++;
            return null;
          },
          'service.run': (_) => null,
        },
      );
      program.invokeImport('dep.ping', []);
      expect(calls, 1);
    });

    test('implicit local dependencies accept canonical callback keys', () {
      final functions = _functions('world command { import service; }');
      final calls = <String>[];
      Object? canonical(List<Object?> _) {
        calls.add('canonical');
        return null;
      }

      Object? local(List<Object?> _) {
        calls.add('local');
        return null;
      }

      final callbacks = {
        'test:world/dep@1.0.0.ping': canonical,
        'service.run': (List<Object?> _) => null,
      };
      WASIComponentWitAdapterProgram.bind(
        functions,
        imports: callbacks,
      ).invokeImport('dep.ping', []);
      WASIComponentWitAdapterProgram.bind(
        functions,
        imports: {...callbacks, 'dep.ping': local},
      ).invokeImport('dep.ping', []);
      expect(calls, ['canonical', 'local']);
      expect(_surface(functions), ['import:dep.ping', 'import:service.run']);
    });

    test('explicit named copies still require their own callbacks', () {
      final functions = _functions('world command { import named: dep; }');
      expect(
        () => WASIComponentWitAdapterProgram.bind(
          functions,
          imports: {'test:world/dep@1.0.0.ping': (_) => null},
        ),
        throwsStateError,
      );
    });

    test('export dependencies default to imports', () {
      expect(_surface(_functions('world command { export service; }')), [
        'import:dep.ping',
        'export:service.run',
      ]);
    });

    test(
      'canonical exports satisfy exported but not imported dependencies',
      () {
        for (final items in [
          'export service; export dep;',
          'export dep; export service;',
        ]) {
          expect(
            _surface(_functions('world command { $items }')),
            unorderedEquals(['export:service.run', 'export:dep.ping']),
          );
        }
        expect(
          _surface(_functions('world command { export dep; import service; }')),
          unorderedEquals([
            'export:dep.ping',
            'import:dep.ping',
            'import:service.run',
          ]),
        );
      },
    );

    test('plain instances do not provide canonical dependencies', () {
      expect(
        _surface(
          _functions('world command { import named: dep; import service; }'),
        ),
        ['import:named.ping', 'import:dep.ping', 'import:service.run'],
      );
      expect(
        _surface(
          _functions('world command { export named: dep; export service; }'),
        ),
        ['export:named.ping', 'import:dep.ping', 'export:service.run'],
      );
    });

    test('includes retain dependencies elaborated in their own world', () {
      for (final world in [
        'world command { include base; export dep; }',
        'world other { export dep; } world command { include base; include other; }',
      ]) {
        expect(
          _surface(_functions('world base { export service; } $world')),
          unorderedEquals([
            'import:dep.ping',
            'export:service.run',
            'export:dep.ping',
          ]),
        );
      }
    });

    test('included exports can supply direct exported dependencies', () {
      expect(
        _surface(
          _functions('''
world base { export dep; }
world command { export service; include base; }
'''),
        ),
        unorderedEquals(['export:service.run', 'export:dep.ping']),
      );
    });

    test('canonical include diamonds deduplicate complete interfaces', () {
      expect(
        _surface(
          _functions('''
world first { import service; }
world second { import service; }
world command { include first; include second; include first; }
'''),
        ),
        ['import:dep.ping', 'import:service.run'],
      );
    });

    test('plain include collisions fail in each direction', () {
      for (final direction in ['import', 'export']) {
        expect(
          () => _functions('''
world base { $direction named: dep; }
world command { include base; include base; }
'''),
          throwsA(isA<WASIComponentWitTargetResolutionException>()),
        );
      }
      expect(
        _surface(
          _functions('world command { import named: dep; export named: dep; }'),
        ),
        ['import:named.ping', 'export:named.ping'],
      );
    });

    test('renamed copies coexist with the canonical dependency', () {
      final functions = _functions('''
world base { import named: dep; }
world command {
  include base with { named as first }
  include base with { named as second }
  import service;
}
''');
      expect(_surface(functions), [
        'import:first.ping',
        'import:second.ping',
        'import:dep.ping',
        'import:service.run',
      ]);
    });

    test('duplicate direct canonical declarations are rejected', () {
      expect(
        () => _functions('world command { import service; import service; }'),
        throwsA(isA<WASIComponentWitTargetResolutionException>()),
      );
      expect(
        _surface(
          _functions('''
world base { import service; }
world command { import service; include base; }
'''),
        ),
        unorderedEquals(['import:dep.ping', 'import:service.run']),
      );
    });

    test('qualified dependencies inherit resolved callback prefixes', () {
      final dependency = WASIComponentWitDocument.parse(_interfaces);
      final document = WASIComponentWitDocument.parse('''
world command { import test:world/service@1.0.0; }
''');
      final functions = wasiComponentWitWorldFunctions(
        document,
        document.worldNamed('command')!,
        resolveTarget: (_) => WASIComponentWitResolvedTarget(
          document: dependency,
          memberName: 'service',
        ),
      );
      expect(_surface(functions), [
        'import:test:world/dep@1.0.0.ping',
        'import:test:world/service@1.0.0.run',
      ]);
    });

    test('world plans preserve resource-only and empty interface boundaries', () {
      final document = WASIComponentWitDocument.parse('''
package test:world@1.0.0;
interface dep { resource token; }
interface service { use dep.{token}; }
interface empty {}
world base { import named: empty; }
world command { include base with { named as renamed } export service; }
''');
      final plan = WASIComponentVersionedHost(
        version: WASIVersion.preview2,
      ).prepareWitWorld(document, worldName: 'command');
      expect(plan.canIngest, isTrue);
      expect(plan.functions, isEmpty);
      expect(
        plan.interfaces.map(
          (binding) =>
              '${binding.direction.name}:${binding.interfaceName}:${binding.canonicalName}',
        ),
        [
          'import:renamed:test:world/empty@1.0.0',
          'import:dep:test:world/dep@1.0.0',
          'export:service:test:world/service@1.0.0',
        ],
      );
      expect(plan.interfaces[1].interface.resources.single.name, 'token');
      expect(() => plan.interfaces.clear(), throwsUnsupportedError);
    });

    group('elaborated version profiles', () {
      const asyncDependency = '''
interface dep { resource token; work: async func(); }
interface api { use dep.{token}; run: func(value: borrow<token>); }
''';
      const preview3TypeDependency = '''
interface api { use wasi:clocks/types@0.3.0.{duration}; }
''';

      void expectPreview2Rejected(
        WASIComponentVersionedWitWorldPlan plan,
        String target,
      ) {
        expect(plan.canIngest, isFalse);
        expect(plan.canBindAdapters, isFalse);
        expect(
          plan.versionErrors.map((error) => error.targetName),
          contains(target),
        );
        expect(
          () => plan.bindAdapters(),
          throwsA(isA<WASIComponentVersionedWitWorldUnsupportedException>()),
        );
      }

      for (final target in ['dep', 'api']) {
        test('Preview2 rejects async dependency imported via $target', () {
          final document = WASIComponentWitDocument.parse('''
$asyncDependency
world command { import $target; }
''');
          final plan = WASIComponentVersionedHost(
            version: WASIVersion.preview2,
          ).prepareWitWorld(document, worldName: 'command');
          expect(
            plan.functions
                .singleWhere((binding) => binding.qualifiedName == 'dep.work')
                .signature
                .isAsync,
            isTrue,
          );
          expectPreview2Rejected(plan, 'dep.work');
        });
      }

      for (final target in ['wasi:clocks/types@0.3.0', 'api']) {
        test('type-only dependency via $target retains its WASI profile', () {
          final document = WASIComponentWitDocument.parse('''
$preview3TypeDependency
world command { import $target; }
''');
          final preview3 = WASIComponentVersionedHost(
            version: WASIVersion.preview3,
          ).prepareWitWorld(document, worldName: 'command');
          expect(preview3.functions, isEmpty);
          expect(preview3.versionErrors, isEmpty);
          expect(preview3.canIngest, isTrue);
          expect(preview3.canBindAdapters, isTrue);
          expect(() => preview3.bindAdapters(), returnsNormally);

          final preview2 = WASIComponentVersionedHost(
            version: WASIVersion.preview2,
          ).prepareWitWorld(document, worldName: 'command');
          expect(preview2.functions, isEmpty);
          expect(
            preview2.interfaces.map((binding) => binding.canonicalName),
            contains('wasi:clocks/types@0.3.0'),
          );
          expectPreview2Rejected(preview2, 'wasi:clocks/types@0.3.0');
        });
      }

      test('exported interfaces cannot hide imported async dependencies', () {
        final document = WASIComponentWitDocument.parse('''
$asyncDependency
world command { export api; }
''');
        final plan = WASIComponentVersionedHost(
          version: WASIVersion.preview2,
        ).prepareWitWorld(document, worldName: 'command');
        expect(_surface(plan.functions), ['import:dep.work', 'export:api.run']);
        expectPreview2Rejected(plan, 'dep.work');
      });

      test('includes cannot hide type-only Preview3 dependencies', () {
        final document = WASIComponentWitDocument.parse('''
$preview3TypeDependency
world base { export api; }
world command { include base; }
''');
        final preview3 = WASIComponentVersionedHost(
          version: WASIVersion.preview3,
        ).prepareWitWorld(document, worldName: 'command');
        expect(preview3.functions, isEmpty);
        expect(preview3.versionErrors, isEmpty);
        expect(preview3.canIngest, isTrue);
        expect(preview3.canBindAdapters, isTrue);

        final preview2 = WASIComponentVersionedHost(
          version: WASIVersion.preview2,
        ).prepareWitWorld(document, worldName: 'command');
        expect(preview2.functions, isEmpty);
        expect(
          preview2.interfaces.map(
            (binding) => '${binding.direction.name}:${binding.canonicalName}',
          ),
          ['import:wasi:clocks/types@0.3.0', 'export:api'],
        );
        expectPreview2Rejected(preview2, 'wasi:clocks/types@0.3.0');
      });

      for (final entry in {
        'self': 'world command { include command; }',
        'mutual': '''
world other { include command; }
world command { include other; }
''',
      }.entries) {
        test(
          '${entry.key} include metadata terminates without exhausting the stack',
          () {
            // These malformed graphs check termination, not WIT validity.
            final document = WASIComponentWitDocument.parse(entry.value);
            try {
              WASIComponentVersionedHost(
                version: WASIVersion.preview2,
              ).prepareWitWorld(document, worldName: 'command');
            } on WASIComponentWitTargetResolutionException catch (error) {
              expect(error.reason, isNotEmpty);
            }
          },
        );
      }
    });

    test('transitive unused scalar uses still elaborate dependencies', () {
      final document = WASIComponentWitDocument.parse('''
interface dep { type number = u32; ping: func(); }
interface middle { use dep.{number}; }
interface first { use middle.{number}; one: func(); }
interface second { use dep.{number}; two: func(); }
world command { import first; import second; }
''');
      final expansion = wasiComponentWitWorldBindings(
        document,
        document.worldNamed('command')!,
      );
      expect(expansion.interfaces.map((binding) => binding.interfaceName), [
        'dep',
        'middle',
        'first',
        'second',
      ]);
      expect(_surface(expansion.functions), [
        'import:dep.ping',
        'import:first.one',
        'import:second.two',
      ]);
    });

    test('unused unresolved dependencies make the world plan incomplete', () {
      final document = WASIComponentWitDocument.parse('''
interface service { use missing.{token}; run: func(); }
world command { import service; }
''');
      final plan = WASIComponentVersionedHost(
        version: WASIVersion.preview2,
      ).prepareWitWorld(document);
      expect(plan.canIngest, isFalse);
      expect(plan.versionErrors.single.targetName, 'missing');
      expect(plan.versionErrors.single.reason, contains('dependency'));
      // The existing low-level API still returns the function boundary.
      expect(plan.functions.single.qualifiedName, 'service.run');
      expect(
        () => plan.bindAdapters(),
        throwsA(isA<WASIComponentVersionedWitWorldUnsupportedException>()),
      );
    });

    test(
      'unused missing use members are reported without hiding functions',
      () {
        final document = WASIComponentWitDocument.parse('''
interface dep { resource token; }
interface service { use dep.{absent}; run: func(); }
world command { import service; }
''');
        final plan = WASIComponentVersionedHost(
          version: WASIVersion.preview2,
        ).prepareWitWorld(document);
        expect(plan.canIngest, isFalse);
        expect(plan.versionErrors.single.reason, contains("type 'absent'"));
        expect(plan.functions.single.qualifiedName, 'service.run');
      },
    );

    test(
      'empty canonical includes merge while plain rename collisions fail',
      () {
        final document = WASIComponentWitDocument.parse('''
interface empty {}
world base { import empty; }
world command { include base; include base; }
''');
        final expansion = wasiComponentWitWorldBindings(
          document,
          document.worldNamed('command')!,
        );
        expect(expansion.interfaces.single.interfaceName, 'empty');
        expect(expansion.functions, isEmpty);
        final duplicate = WASIComponentWitDocument.parse('''
interface empty {}
world base { import first: empty; import second: empty; }
world command { include base with { first as same, second as same } }
''');
        expect(
          () => wasiComponentWitWorldBindings(
            duplicate,
            duplicate.worldNamed('command')!,
          ),
          throwsA(isA<WASIComponentWitTargetResolutionException>()),
        );
      },
    );

    test(
      'named and dependency resource instances retain separate identities',
      () {
        final document = WASIComponentWitDocument.parse('''
package test:world@1.0.0;
interface dep {
  resource token;
  inspect: func(value: borrow<token>) -> token;
}
interface service {
  use dep.{token};
  run: func(value: borrow<token>) -> token;
}
world base { import named: dep; }
world command {
  include base with { named as first }
  include base with { named as second }
  import service;
}
''');
        final functions = wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('command')!,
        );
        Object owner(String key) => functions
            .singleWhere((function) => function.qualifiedName == key)
            .signature
            .result!
            .resourceIdentity!;
        final first = owner('first.inspect');
        final second = owner('second.inspect');
        final shared = owner('dep.inspect');
        expect(first, isNot(same(second)));
        expect(first, isNot(same(shared)));
        expect(second, isNot(same(shared)));
        expect(owner('service.run'), same(shared));
        for (final function in functions) {
          expect(
            function.signature.params.single.type.resourceIdentity,
            same(function.signature.result!.resourceIdentity),
          );
        }
      },
    );

    test('existing explicit callbacks keep their declared order', () {
      expect(
        _surface(_functions('world command { import service; import dep; }')),
        ['import:service.run', 'import:dep.ping'],
      );
      expect(
        _surface(
          _functions('''
world base { export service; }
world command { include base; import dep; }
'''),
        ),
        ['export:service.run', 'import:dep.ping'],
      );
    });
  });
}
