import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';

void main() {
  group('WASIComponentWitDocument', () {
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
        'func()->u32',
        'func(path:string)->descriptor',
        'func(handle:borrow<descriptor>)->u32',
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
  });
}
