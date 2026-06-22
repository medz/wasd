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
