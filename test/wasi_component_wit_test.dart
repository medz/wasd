import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/wit_adapter.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';

void main() {
  group('WASIComponentWitDocument', () {
    test('retains external IDs without interpreting quoted URL comments', () {
      final document = WASIComponentWitDocument.parse(r'''
interface store {
  @external-id("https://host/a/*b*/(c)")
  get: func() -> u32;
  @external-id("DB.Bucket")
  resource bucket {
    @external-id("read/1")
    read: func() -> u32;
  }
  @external-id("Alias") type count = u32;
  @external-id("Record") record entry { value: u32 }
  @external-id("Variant") variant choice { none, some(u32) }
  @external-id("Flags") flags options { enabled }
  @external-id("Enum") enum status { ready }
}
world command {
  @external-id("https://host/one") import one: store;
  @external-id("☃") export two: store;
}
''');
      final store = document.interfaceNamed('store')!;
      expect(store.functions.first.externalId, 'https://host/a/*b*/(c)');
      expect(store.functions.last.externalId, 'read/1');
      expect(store.functions.last.name, 'bucket.read');
      expect(store.functions.last.signature, 'func(self:borrow<bucket>)->u32');
      expect(store.resources.single.externalId, 'DB.Bucket');
      expect(
        [
          store.typeAliases.single.externalId,
          store.records.single.externalId,
          store.variants.single.externalId,
          store.flags.single.externalId,
          store.enums.single.externalId,
        ],
        ['Alias', 'Record', 'Variant', 'Flags', 'Enum'],
      );
      final world = document.worldNamed('command')!;
      expect(world.imports.single.name, 'one');
      expect(world.imports.single.target.text, 'store');
      expect(world.imports.single.externalId, 'https://host/one');
      expect(world.exports.single.externalId, '☃');
    });

    test('decodes Core name string escapes and empty external IDs', () {
      final document = WASIComponentWitDocument.parse(r'''
interface store {
  @external-id("\e2\98\83\u{1f642}\n\t\r\"\'\\") get: func();
  @external-id("") put: func();
}
world command { import store; }
''');
      final functions = document.interfaceNamed('store')!.functions;
      expect(functions.first.externalId, '☃🙂\n\t\r"\'\\');
      expect(functions.last.externalId, '');
    });

    test(
      'rejects raw WIT controls and bidi characters in every lexer path',
      () {
        for (final scalar in <int>[0x202e, 0x202d, 0x0085, 0x009f, 0x0000]) {
          final character = String.fromCharCode(scalar);
          for (final source in <String>[
            'interface store { @external-id("A${character}B") get: func(); }',
            'interface store { $character get: func(); }',
            '// A${character}B\ninterface store {}',
            '/* A${character}B */ interface store {}',
          ]) {
            expect(
              () => WASIComponentWitDocument.parse(source),
              throwsA(isA<WASIComponentWitParseException>()),
              reason: 'raw U+${scalar.toRadixString(16)}',
            );
          }
        }
      },
    );

    test('preserves escaped control and bidi external ID values', () {
      for (final spelling in <String>[
        r'\u{202e}',
        r'\e2\80\ae',
        r'\u{85}',
        r'\c2\85',
      ]) {
        final document = WASIComponentWitDocument.parse(
          'interface store { @external-id("$spelling") get: func(); }',
        );
        expect(
          document.interfaces.single.functions.single.externalId,
          spelling.contains('202e') || spelling.contains('ae')
              ? String.fromCharCode(0x202e)
              : String.fromCharCode(0x85),
        );
      }
      expect(
        WASIComponentWitDocument.parse(
          'interface store {\n\r\tget: func(); }',
        ).interfaces.single.functions.single.name,
        'get',
      );
    });

    test('rejects malformed external IDs instead of discarding metadata', () {
      for (final annotation in <String>[
        '@external-id(42)',
        '@external-id("one", "two")',
        '@external-id("one") @external-id("two")',
        r'@external-id("\ff")',
        r'@external-id("\u{d800}")',
        r'@external-id("\u{_61}")',
        r'@external-id("\u{61_}")',
        r'@external-id("\q")',
        '@external-id("unterminated)',
      ]) {
        expect(
          () => WASIComponentWitDocument.parse(
            'interface store { $annotation get: func(); }',
          ),
          throwsA(isA<WASIComponentWitParseException>()),
          reason: annotation,
        );
      }
    });

    test(
      'keeps direct function and inline interface external ID boundaries',
      () {
        final document = WASIComponentWitDocument.parse('''
world command {
  @external-id("https://host/slugify") import slugify: func(text: string) -> string;
  @external-id("Handler") export handler: interface { run: func(); }
}
''');
        final world = document.worldNamed('command')!;
        expect(world.imports.single.name, 'slugify');
        expect(world.imports.single.externalId, 'https://host/slugify');
        expect(world.exports.single.name, 'handler');
        expect(world.exports.single.externalId, 'Handler');
      },
    );

    test('distinguishes a namespace token from a spaced plain label', () {
      expect(
        () => WASIComponentWitDocument.parse('''
interface store {}
world command { import one:store; }
'''),
        throwsA(isA<WASIComponentWitParseException>()),
      );
    });

    test('external IDs are rejected on declarations without a linking name', () {
      for (final source in <String>[
        '@external-id("X") interface store {}',
        'interface store {} world command { @external-id("X") import store; }',
        'interface store {} world command { @external-id("X") include command; }',
        'interface types { type t = u32; } interface store { @external-id("X") use types.{t}; }',
      ]) {
        expect(
          () => WASIComponentWitDocument.parse(source),
          throwsA(isA<WASIComponentWitParseException>()),
          reason: source,
        );
      }
    });

    test('retains include renaming and qualified named interface targets', () {
      final document = WASIComponentWitDocument.parse('''
interface store { get: func() -> u32; }
world base { import cache: store; }
world command {
  include base with { cache as primary }
  import remote: acme:db/store@1.0.0;
}
''');
      final world = document.worldNamed('command')!;
      expect(world.includes.single.target.text, 'base');
      expect(world.includes.single.renames, {'cache': 'primary'});
      expect(world.imports.single.name, 'remote');
      expect(world.imports.single.target.text, 'acme:db/store@1.0.0');
    });

    test('binds map signatures with aliases and nested record values', () {
      final document = WASIComponentWitDocument.parse('''
package acme:maps;
interface tables {
  type key = string;
  record entry { values: list<u32> }
  type entries = map<key, entry>;
  update: func(value: entries) -> list<map<bool, entries>>;
}
world command { import tables; }
''');
      final functions = wasiComponentWitWorldFunctions(
        document,
        document.worldNamed('command')!,
      );

      expect(functions.single.signature.canBind, isTrue);
      expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
      final parameter = functions.single.signature.params.single.type;
      expect(parameter.kind, WASIComponentWitAdapterValueKind.map);
      expect(parameter.key?.text, 'string');
      expect(parameter.value?.kind, WASIComponentWitAdapterValueKind.record);
      final result = functions.single.signature.result!;
      expect(result.kind, WASIComponentWitAdapterValueKind.list);
      expect(result.element?.kind, WASIComponentWitAdapterValueKind.map);
    });

    test('accepts each scalar map key type', () {
      for (final key in const [
        'bool',
        's8',
        'u8',
        's16',
        'u16',
        's32',
        'u32',
        's64',
        'u64',
        'char',
        'string',
      ]) {
        final document = WASIComponentWitDocument.parse('''
interface tables { read: func(value: map<$key, u32>); }
world command { import tables; }
''');
        final functions = wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('command')!,
        );
        expect(functions.single.signature.canBind, isTrue, reason: key);
      }
    });

    test('rejects invalid map key types arity and nested async payloads', () {
      for (final type in const [
        'map<f32, u32>',
        'map<f64, u32>',
        'map<list<u8>, u32>',
        'map<tuple<u8>, u32>',
        'map<option<u32>, u32>',
        'map<map<u32, u32>, u32>',
        'map<future<u32>, u32>',
        'map<u32>',
        'map<u32, u32, u32>',
        'stream<map<string, future<u8>>>',
      ]) {
        final document = WASIComponentWitDocument.parse('''
interface tables { read: func(value: $type); }
world command { import tables; }
''');
        final functions = wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('command')!,
        );
        expect(functions.single.signature.canBind, isFalse, reason: type);
      }
    });

    test('rejects aliased composite map key types', () {
      final document = WASIComponentWitDocument.parse('''
interface tables {
  type key = tuple<u32>;
  read: func(value: map<key, u32>);
}
world command { import tables; }
''');
      final functions = wasiComponentWitWorldFunctions(
        document,
        document.worldNamed('command')!,
      );

      expect(functions.single.signature.canBind, isFalse);
      expect(
        functions.single.signature.unsupportedReason,
        contains('map key type key'),
      );
    });

    test('parses package interfaces and world import/export boundaries', () {
      const source = '''
package wasi:cli@0.3.0;

interface environment {
  get-environment: func() -> list<tuple<string, string>>;
}

interface run {
  run: func() -> result;
}

world command {
  import environment;
  import wasi:filesystem/types@0.3.0;
  export run;
}
''';

      final document = WASIComponentWitDocument.parse(
        source,
        sourceName: 'command.wit',
      );

      expect(document.package?.namespace, 'wasi');
      expect(document.package?.name, 'cli');
      expect(document.package?.version, '0.3.0');
      expect(document.interfaces.map((interface) => interface.name), [
        'environment',
        'run',
      ]);

      final world = document.worldNamed('command')!;
      expect(world.imports.map((item) => item.target.text), [
        'environment',
        'wasi:filesystem/types@0.3.0',
      ]);
      expect(world.imports.first.target.isLocal, isTrue);
      expect(world.imports.last.target.isQualified, isTrue);
      expect(world.exports.single.target.text, 'run');
      expect(world.exports.single.target.isLocal, isTrue);
    });

    test('parses local record type declarations', () {
      const source = '''
package acme:env@0.2.0;

interface environment {
  record entry {
    name: string,
    value: string,
  }

  get: func() -> list<entry>;
}

world command {
  import environment;
}
''';

      final document = WASIComponentWitDocument.parse(source);
      final environment = document.interfaceNamed('environment')!;

      expect(environment.records.map((record) => record.name), ['entry']);
      expect(environment.records.single.fields.map((field) => field.name), [
        'name',
        'value',
      ]);
      expect(environment.records.single.fields.map((field) => field.type), [
        'string',
        'string',
      ]);
      expect(environment.functions.single.signature, 'func()->list<entry>');
    });

    test('parses local variant enum and flags type declarations', () {
      const source = '''
package acme:env@0.2.0;

interface environment {
  flags permissions {
    read,
    write,
    execute,
  }

  enum color {
    red,
    blue,
  }

  variant lookup {
    none,
    name(string),
    permissions(permissions),
  }

  describe: func(mode: lookup, color: color) -> permissions;
}

world command {
  import environment;
}
''';

      final document = WASIComponentWitDocument.parse(source);
      final environment = document.interfaceNamed('environment')!;

      expect(environment.flags.map((flags) => flags.name), ['permissions']);
      expect(environment.flags.single.labels.map((label) => label.name), [
        'read',
        'write',
        'execute',
      ]);
      expect(environment.enums.map((enum_) => enum_.name), ['color']);
      expect(environment.enums.single.cases.map((case_) => case_.name), [
        'red',
        'blue',
      ]);
      expect(environment.variants.map((variant) => variant.name), ['lookup']);
      expect(environment.variants.single.cases.map((case_) => case_.name), [
        'none',
        'name',
        'permissions',
      ]);
      expect(environment.variants.single.cases.map((case_) => case_.type), [
        isNull,
        'string',
        'permissions',
      ]);
      expect(
        environment.functions.single.signature,
        'func(mode:lookup,color:color)->permissions',
      );
    });

    test('parses local resource type declarations', () {
      const source = '''
package acme:files@0.2.0;

interface files {
  resource descriptor {
    read: func() -> u32;
  }

  open: func(path: string) -> descriptor;
  stat: func(handle: borrow<descriptor>) -> u32;
}

world command {
  import files;
}
''';

      final document = WASIComponentWitDocument.parse(source);
      final files = document.interfaceNamed('files')!;

      expect(files.resources.map((resource) => resource.name), ['descriptor']);
      expect(files.functions.map((function) => function.name), [
        'descriptor.read',
        'open',
        'stat',
      ]);
      expect(files.functions.map((function) => function.signature), [
        'func(self:borrow<descriptor>)->u32',
        'func(path:string)->descriptor',
        'func(handle:borrow<descriptor>)->u32',
      ]);
    });

    test('parses type aliases and use declarations in interfaces', () {
      const source = '''
package wasi:clocks@0.2.0;

interface monotonic-clock {
  use wasi:io/poll@0.2.0.{pollable};

  type instant = u64;
  type duration = u64;

  now: func() -> instant;
  subscribe-instant: func(when: instant) -> pollable;
}

world imports {
  import monotonic-clock;
}
''';

      final document = WASIComponentWitDocument.parse(source);
      final clock = document.interfaceNamed('monotonic-clock')!;

      expect(clock.typeAliases.map((alias) => alias.name), [
        'instant',
        'duration',
      ]);
      expect(clock.typeAliases.map((alias) => alias.target), ['u64', 'u64']);
      expect(clock.uses.single.target.text, 'wasi:io/poll@0.2.0');
      expect(clock.uses.single.items.map((item) => item.name), ['pollable']);
      expect(clock.uses.single.items.map((item) => item.alias), ['pollable']);
      expect(clock.functions.map((function) => function.signature), [
        'func()->instant',
        'func(when:instant)->pollable',
      ]);
    });

    test('parses annotated Preview3 async functions and world includes', () {
      const source = '''
package wasi:cli@0.3.0;

@since(version = 0.3.0)
interface run {
  @since(version = 0.3.0)
  run: async func() -> result;
}

interface stdout {
  write-via-stream: func(data: stream<u8>) -> future<result>;
}

@since(version = 0.3.0)
world command {
  @since(version = 0.3.0)
  import run;
  include wasi:filesystem/imports@0.3.0;
  export stdout;
}
''';

      final document = WASIComponentWitDocument.parse(
        source,
        sourceName: 'wasi-cli.wit',
      );
      final run = document.interfaceNamed('run')!;
      final stdout = document.interfaceNamed('stdout')!;
      final world = document.worldNamed('command')!;

      expect(run.functions.single.name, 'run');
      expect(run.functions.single.isAsync, isTrue);
      expect(run.functions.single.usesPreview3AsyncFeatures, isTrue);
      expect(stdout.functions.single.name, 'write-via-stream');
      expect(stdout.functions.single.isAsync, isFalse);
      expect(stdout.functions.single.usesPreview3AsyncFeatures, isTrue);
      expect(world.imports.single.target.text, 'run');
      expect(
        world.includes.single.target.text,
        'wasi:filesystem/imports@0.3.0',
      );
      expect(world.exports.single.target.text, 'stdout');
    });

    test('parses nested resource async function boundaries', () {
      const source = '''
package wasi:filesystem@0.3.0;

interface types {
  resource descriptor {
    read-via-stream: func(offset: u64) -> tuple<stream<u8>, future<result>>;
    sync-data: async func() -> result;
  }
}

world imports {
  import types;
}
''';

      final document = WASIComponentWitDocument.parse(source);
      final types = document.interfaceNamed('types')!;

      expect(types.functions.map((function) => function.name), [
        'descriptor.read-via-stream',
        'descriptor.sync-data',
      ]);
      expect(
        types.functions.every((function) => function.usesPreview3AsyncFeatures),
        isTrue,
      );
    });

    test('skips comments and nested interface declarations', () {
      const source = '''
package wasi:demo@0.3.0;

// Nested braces inside an interface must not terminate the top-level parser.
interface types {
  record descriptor {
    id: u32,
  }
}

/* Block comments are legal between declarations. */
world demo {
  import types;
}
''';

      final document = WASIComponentWitDocument.parse(source);

      expect(document.interfaceNamed('types'), isNotNull);
      expect(document.worldNamed('demo')?.imports.single.target.text, 'types');
    });

    test('parses escaped identifiers and inline world item blocks', () {
      const source = '''
package wasi:demo@0.3.0;

interface %type {}

world demo {
  import %type;
  export handler: interface {
    run: func();
  }
}
''';

      final document = WASIComponentWitDocument.parse(source);
      final world = document.worldNamed('demo')!;

      expect(document.interfaceNamed('%type'), isNotNull);
      expect(world.imports.single.target.text, '%type');
      expect(world.exports.single.target.text, 'handler:interface');
    });

    test('rejects duplicate interfaces with boundary diagnostics', () {
      const source = '''
package wasi:demo@0.3.0;
interface io {}
interface io {}
''';

      expect(
        () =>
            WASIComponentWitDocument.parse(source, sourceName: 'duplicate.wit'),
        throwsA(
          isA<WASIComponentWitParseException>()
              .having((error) => error.diagnostic.line, 'line', 3)
              .having(
                (error) => error.toString(),
                'message',
                allOf(
                  contains('duplicate.wit:3:11'),
                  contains("duplicate interface 'io'"),
                  contains('first declared at duplicate.wit:2:11'),
                ),
              ),
        ),
      );
    });

    test('rejects unresolved local world references', () {
      const source = '''
package wasi:demo@0.3.0;

world demo {
  import missing;
}
''';

      expect(
        () => WASIComponentWitDocument.parse(source, sourceName: 'missing.wit'),
        throwsA(
          isA<WASIComponentWitParseException>()
              .having((error) => error.diagnostic.line, 'line', 4)
              .having(
                (error) => error.toString(),
                'message',
                allOf(
                  contains('missing.wit:4:10'),
                  contains(
                    "world 'demo' import references unknown local interface "
                    "'missing'",
                  ),
                ),
              ),
        ),
      );
    });

    test('rejects unresolved qualified world targets during expansion', () {
      const source = '''
package wasi:demo@0.3.0;

world demo {
  include wasi:missing/imports@0.3.0;
}
''';

      final document = WASIComponentWitDocument.parse(
        source,
        sourceName: 'unresolved-qualified.wit',
      );

      expect(
        () => wasiComponentWitWorldFunctions(
          document,
          document.worldNamed('demo')!,
          resolveTarget: (_) => null,
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('wasi:missing/imports@0.3.0'),
          ),
        ),
      );
    });
  });
}
