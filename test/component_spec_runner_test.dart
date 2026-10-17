import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/unicode_scalar.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/execution_error.dart';

import '../tool/component_spec_runner.dart' as runner;

const _fixture = 'test/fixtures/component_spec/strings';
const _numerics = 'test/fixtures/component_spec/numerics';

Map<String, dynamic> _script() =>
    jsonDecode(File('$_fixture/script.json').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _numericScript() =>
    jsonDecode(File('$_numerics/script.json').readAsStringSync())
        as Map<String, dynamic>;

Future<Map<String, Object?>> _runNumerics(Map<String, dynamic> script) =>
    runner.executeComponentSpecScript(script, directory: Directory(_numerics));

Future<Map<String, Object?>> _run(Map<String, dynamic> script) =>
    runner.executeComponentSpecScript(script, directory: Directory(_fixture));

void main() {
  test('complete frozen strings file executes 8 initializations, 5 returns, '
      'and 4 traps through WASD', () async {
    final temp = await _copyFixtures();
    addTearDown(() => temp.delete(recursive: true));
    final report = await runner.runComponentSpecManifest(
      File('${temp.path}/manifest.json'),
      usePreparedInputs: true,
    );
    expect(report['engine'], 'wasd');
    expect(report['status'], 'passed');
    final totals = report['totals'] as Map;
    expect(totals['commands_seen'], 17);
    expect(totals['commands_passed'], 17);
    expect(totals['commands_failed'], 0);
    expect(totals['commands_skipped'], 0);
    expect(totals['instantiations_passed'], 8);
    expect(totals['returns_passed'], 5);
    expect(totals['traps_passed'], 4);
    final files = report['files'] as List;
    final source = (files.single as Map)['source'] as Map;
    expect(source['revision'], '0220da84209397d9067c19cac83dae969aa85a7b');
    expect(
      source['sha256'],
      'a70c90a0ede0e2364040da75f4c2c0e56c2d34fdac746a11b6347fdbac60283c',
    );
    expect((files.single as Map)['commands'], hasLength(17));
  });

  test('complete frozen numerics file executes 9 initializations, '
      '1 definition, 13 returns, and 3 traps through WASD', () async {
    final report = await _runNumerics(_numericScript());
    expect(report['status'], 'passed');
    final totals = report['totals'] as Map;
    expect(totals['commands_seen'], 26);
    expect(totals['commands_passed'], 26);
    expect(totals['commands_failed'], 0);
    expect(totals['commands_skipped'], 0);
    expect(totals['instantiations_passed'], 9);
    expect(totals['definitions_passed'], 1);
    expect(totals['returns_passed'], 13);
    expect(totals['traps_passed'], 3);
  });

  test('both complete frozen files execute all 43 commands', () async {
    final report = await runner.runComponentSpecManifest(
      File('test/fixtures/component_spec/manifest.json'),
      usePreparedInputs: true,
    );
    expect(report['status'], 'passed');
    final totals = report['totals'] as Map;
    expect(totals['files_total'], 2);
    expect(totals['files_passed'], 2);
    expect(totals['commands_passed'], 43);
    expect(totals['commands_failed'], 0);
    expect(totals['commands_skipped'], 0);
    expect(totals['instantiations_passed'], 17);
    expect(totals['definitions_passed'], 1);
    expect(totals['returns_passed'], 18);
    expect(totals['traps_passed'], 7);
  });

  test('definition registration retains current state and each instance '
      'initializes fresh even with the same name', () async {
    Map<String, Object?> next(String value) => {
      'type': 'assert_return',
      'action': {'type': 'invoke', 'field': 'next', 'args': <Object>[]},
      'expected': [
        {'type': 'string', 'value': value},
      ],
    };
    final report = await runner.executeComponentSpecScript({
      'commands': [
        {'type': 'module', 'filename': 'stateful_string.wasm'},
        next('a'),
        {
          'type': 'module_definition',
          'name': 'Counter',
          'filename': 'stateful_string.wasm',
        },
        next('b'),
        {'type': 'module_instance', 'module': 'Counter', 'instance': 'counter'},
        next('a'),
        next('b'),
        {'type': 'module_instance', 'module': 'Counter', 'instance': 'counter'},
        next('a'),
      ],
    }, directory: Directory('test/fixtures/component_spec/regression'));
    expect(report['status'], 'passed');
    final totals = report['totals'] as Map;
    expect(totals['commands_passed'], 9);
    expect(totals['instantiations_passed'], 3);
    expect(totals['definitions_passed'], 1);
  });

  test('missing definition clears the current instance and cannot satisfy '
      'a char trap', () async {
    final report = await _runNumerics({
      'commands': [
        (_numericScript()['commands'] as List)[2],
        {'type': 'module_instance', 'module': 'Missing', 'instance': 'ct'},
        {
          'type': 'assert_trap',
          'action': {'type': 'invoke', 'field': 'absent', 'args': <Object>[]},
          'text': 'invalid `char` bit pattern',
        },
      ],
    });
    final commands = report['commands'] as List;
    expect(commands[0]['passed'], true);
    expect(commands[1]['passed'], false);
    expect(commands[1]['error'], contains('Unknown component definition'));
    expect(commands[2]['passed'], false);
    expect(commands[2]['error'], contains('No initialized component'));
  });

  for (final (field, args, message) in [
    ('absent', <Object>[], 'not found'),
    (
      'i-to-b',
      <Object>[
        {'type': 'u32', 'value': '0'},
      ],
      'did not trap',
    ),
    ('i-to-b', <Object>[], 'argument count mismatch'),
  ]) {
    test('char trap rejects $field with $message', () async {
      final commands = _numericScript()['commands'] as List;
      final report = await _runNumerics({
        'commands': [
          commands[2],
          {
            'type': 'assert_trap',
            'action': {'type': 'invoke', 'field': field, 'args': args},
            'text': 'invalid `char` bit pattern',
          },
        ],
      });
      final records = report['commands'] as List;
      expect(records[0]['passed'], true);
      expect(records[1]['passed'], false);
      expect(records[1]['error'], contains(message));
    });
  }

  test('flags expectations compare labels as a set', () async {
    final script = _numericScript();
    final commands = script['commands'] as List;
    final expected = commands.last['expected'][0] as Map;
    expected['value'] = ['f9', 'f1', 'f5'];
    final report = await _runNumerics({'commands': commands.sublist(24)});
    expect(report['status'], 'passed');
  });

  for (final (name, type, value) in <(String, String, Object?)>[
    ('integer JSON value', 'u32', 0),
    ('negative unsigned', 'u32', '-1'),
    ('unsigned overflow', 'u32', '4294967296'),
    ('nondecimal', 'u32', '0x0'),
    ('fraction', 'u32', '0.0'),
    ('unknown type', 'future', '0'),
    ('wrong declared argument type', 'u8', '0'),
  ]) {
    test('scalar arguments reject $name', () async {
      final commands = _numericScript()['commands'] as List;
      final assertion = commands[3] as Map;
      assertion['action']['args'] = [
        {'type': type, 'value': value},
      ];
      final report = await _runNumerics({
        'commands': [commands[2], assertion],
      });
      final records = report['commands'] as List;
      expect(records[0]['passed'], true);
      expect(records[1]['passed'], false);
      expect(records[1]['error'], isA<String>());
    });
  }

  for (final (type, value) in <(String, Object?)>[
    ('u8', '256'),
    ('u8', '-1'),
    ('u8', 1),
    ('u32', '1'),
    ('bool', 1),
  ]) {
    test('scalar expectation rejects $type value $value', () async {
      final commands = _numericScript()['commands'] as List;
      final assertion = commands[5] as Map;
      assertion['expected'] = [
        {'type': type, 'value': value},
      ];
      final report = await _runNumerics({
        'commands': [commands[2], assertion],
      });
      final records = report['commands'] as List;
      expect(records[0]['passed'], true);
      expect(records[1]['passed'], false);
    });
  }

  test('wrong scalar value and duplicate flags fail assertions', () async {
    final commands = _numericScript()['commands'] as List;
    commands[5]['expected'][0]['value'] = '2';
    var report = await _runNumerics({
      'commands': [commands[2], commands[5]],
    });
    expect((report['commands'] as List)[1]['passed'], false);
    commands.last['expected'][0]['value'] = ['f1', 'f1', 'f5', 'f9'];
    report = await _runNumerics({'commands': commands.sublist(24)});
    expect((report['commands'] as List)[1]['passed'], false);
  });

  for (final value in ['', 'ab', String.fromCharCode(0xd800)]) {
    test('malformed char argument cannot satisfy a char trap $value', () async {
      final commands = _numericScript()['commands'] as List;
      final report = await _runNumerics({
        'commands': [
          commands[11],
          {
            'type': 'assert_trap',
            'action': {
              'type': 'invoke',
              'field': 'roundtrip',
              'args': [
                {'type': 'char', 'value': value},
              ],
            },
            'text': 'invalid `char` bit pattern',
          },
        ],
      });
      final records = report['commands'] as List;
      expect(records[0]['passed'], true);
      expect(records[1]['passed'], false);
      expect(records[1]['error'], contains('Invalid char value'));
    });
  }

  test('char traps recognize only the typed failure through typed causes', () {
    const message =
        'WASI component canonical adapter value canonical[0].flags '
        'expected a Unicode scalar.';
    final invalidChar = WASIComponentInvalidCharException(message);
    expect(runner.matchesComponentCharTrap(invalidChar), true);
    expect(
      runner.matchesComponentCharTrap(
        _ExecutionError(_ExecutionError(invalidChar)),
      ),
      true,
    );
    for (final error in [
      StateError(message),
      _ExecutionError(StateError(message)),
      _UnknownCause(invalidChar),
      TypeError(),
      const FormatException(message),
    ]) {
      expect(runner.matchesComponentCharTrap(error), false);
    }
    final cycle = _ExecutionError(invalidChar);
    cycle.cause = cycle;
    expect(runner.matchesComponentCharTrap(cycle), false);
  });

  for (final encoding in ['text', 'future', 0]) {
    test('definitions reject unknown encoding $encoding', () async {
      final report = await _runNumerics({
        'commands': [
          {
            'type': 'module_definition',
            'name': 'CharTraps',
            'filename': 'script.4.wasm',
            'module_type': encoding,
          },
          {'type': 'module_instance', 'module': 'CharTraps', 'instance': 'ct'},
        ],
      });
      final records = report['commands'] as List;
      expect(records[0]['passed'], false);
      expect(records[1]['passed'], false);
      expect((report['totals'] as Map)['definitions_seen'], 1);
    });
  }

  for (final name in <Object?>[null, '', 1]) {
    test('definitions reject invalid name $name', () async {
      final report = await _runNumerics({
        'commands': [
          {
            'type': 'module_definition',
            'name': name,
            'filename': 'script.4.wasm',
          },
        ],
      });
      expect(report['status'], 'failed');
      expect((report['commands'] as List).single['passed'], false);
    });
  }

  for (final field in ['module', 'action', 'value']) {
    test('unknown $field schema fields fail strictly', () async {
      final commands = _numericScript()['commands'] as List;
      if (field == 'module') {
        commands[2]['unexpected'] = true;
      } else if (field == 'action') {
        commands[3]['action']['unexpected'] = true;
      } else {
        commands[3]['action']['args'][0]['unexpected'] = true;
      }
      final report = await _runNumerics({
        'commands': [commands[2], commands[3]],
      });
      expect(report['status'], 'failed');
      final records = report['commands'] as List;
      expect(records[1]['passed'], false);
    });
  }

  test(
    'numeric source anchor rejects coordinated source and hash drift',
    () async {
      final temp = await _copyFixtures(stringsOnly: false);
      addTearDown(() => temp.delete(recursive: true));
      final manifest = File('${temp.path}/manifest.json');
      final inventory = jsonDecode(await manifest.readAsString()) as Map;
      final entry = (inventory['files'] as List).last as Map;
      final source = File('${temp.path}/${entry['source']}');
      await source.writeAsString('${await source.readAsString()}\n;; drift\n');
      final bytes = await source.readAsBytes();
      entry['sha256'] = sha256.convert(bytes).toString();
      entry['blob'] = sha1.convert([
        ...utf8.encode('blob ${bytes.length}\u0000'),
        ...bytes,
      ]).toString();
      await manifest.writeAsString(jsonEncode(inventory));
      final report = await runner.runComponentSpecManifest(
        manifest,
        usePreparedInputs: true,
      );
      final files = report['files'] as List;
      expect(files[0]['status'], 'passed');
      expect(files[1]['status'], 'failed');
      expect(
        files[1]['error'],
        contains('Frozen Component source identity mismatch'),
      );
    },
  );

  test(
    'prepared component definitions require verified binary hashes',
    () async {
      final temp = await _copyFixtures(stringsOnly: false);
      addTearDown(() => temp.delete(recursive: true));
      final manifest = File('${temp.path}/manifest.json');
      final inventory = jsonDecode(await manifest.readAsString()) as Map;
      final entry = (inventory['files'] as List).last as Map;
      (entry['inputs'] as List).removeWhere(
        (input) => input['path'] == 'numerics/script.4.wasm',
      );
      await manifest.writeAsString(jsonEncode(inventory));
      final report = await runner.runComponentSpecManifest(
        manifest,
        usePreparedInputs: true,
      );
      expect(report['status'], 'failed');
      expect(
        (report['files'] as List).last['error'],
        contains('Binary has no verified hash'),
      );
    },
  );

  test('byte-pinned fixtures survive an autocrlf checkout', () async {
    final checkout = await Directory.systemTemp.createTemp(
      'wasd-component-crlf-',
    );
    addTearDown(() => checkout.delete(recursive: true));
    Future<void> git(List<String> args) async {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: checkout.path,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    }

    const paths = [
      '$_fixture/strings.wast',
      '$_fixture/script.json',
      '$_numerics/numerics.wast',
      '$_numerics/script.json',
    ];
    await File('.gitattributes').copy('${checkout.path}/.gitattributes');
    for (final path in paths) {
      final target = File('${checkout.path}/$path');
      await target.parent.create(recursive: true);
      await File(path).copy(target.path);
    }
    await git(['init', '-q']);
    await git(['config', 'core.autocrlf', 'true']);
    await git(['add', '.gitattributes', ...paths]);
    for (final path in paths) {
      await File('${checkout.path}/$path').delete();
    }
    await git(['checkout', '--', ...paths]);
    for (final path in paths) {
      expect(
        await File('${checkout.path}/$path').readAsBytes(),
        await File(path).readAsBytes(),
        reason: path,
      );
    }
  });

  for (final encoding in ['text', 'future', '', 0, false]) {
    test(
      'unknown module encoding $encoding fails and preserves counts',
      () async {
        final script = _script();
        (script['commands'] as List)[0]['module_type'] = encoding;
        final report = await _run(script);
        final commands = report['commands'] as List;
        expect(report['status'], 'failed');
        expect(commands[0]['passed'], false);
        expect(
          commands[0]['error'],
          contains('Only unnamed binary components'),
        );
        final totals = report['totals'] as Map;
        expect(totals['commands_seen'], 17);
        expect(totals['instantiations_seen'], 8);
        expect(totals['commands_skipped'], 0);
      },
    );
  }

  test('explicit binary module encoding executes', () async {
    final script = _script();
    for (final command in script['commands'] as List) {
      if (command['type'] == 'module') command['module_type'] = 'binary';
    }
    expect((await _run(script))['status'], 'passed');
  });

  test('wrong string expectation fails', () async {
    final script = _script();
    ((script['commands'] as List)[1]['expected'] as List)[0]['value'] = 'wrong';
    final report = await _run(script);
    expect(report['status'], 'failed');
    expect((report['commands'] as List)[1]['passed'], false);
  });

  test('successful return cannot satisfy an expected trap', () async {
    final script = _script();
    final command = (script['commands'] as List)[1] as Map;
    command['type'] = 'assert_trap';
    command.remove('expected');
    command['text'] = 'invalid utf-8';
    final report = await _run(script);
    expect(report['status'], 'failed');
    expect((report['commands'] as List)[1]['error'], contains('did not trap'));
  });

  test('missing export cannot satisfy an expected trap', () async {
    final script = _script();
    final command = (script['commands'] as List)[1] as Map;
    command['type'] = 'assert_trap';
    command.remove('expected');
    command['text'] = 'invalid utf-8';
    (command['action'] as Map)['field'] = 'absent';
    expect((await _run(script))['status'], 'failed');
  });

  for (final type in ['unknown_command', 'unknown_expected', 'unknown_trap']) {
    test('$type fails strictly', () async {
      final script = _script();
      final command = (script['commands'] as List)[1] as Map;
      if (type == 'unknown_command') {
        command['type'] = 'silently_skip_me';
      } else if (type == 'unknown_expected') {
        (command['expected'] as List)[0]['type'] = 'future';
      } else {
        command['type'] = 'assert_trap';
        command.remove('expected');
        command['text'] = 'any error';
      }
      expect((await _run(script))['status'], 'failed');
    });
  }

  test('different UTF-8 trap categories are not interchangeable', () async {
    final script = _script();
    (script['commands'] as List)[10]['text'] = 'incomplete utf-8 byte sequence';
    expect((await _run(script))['status'], 'failed');
  });

  test('empty prepared JSON is a failed file', () async {
    final report = await _run({'commands': <Object>[]});
    expect(report['status'], 'failed');
    expect(report['error'], contains('empty'));
  });

  test('missing binary and core header fail initialization', () async {
    final temp = await Directory.systemTemp.createTemp('wasd-component-input-');
    addTearDown(() => temp.delete(recursive: true));
    for (final create in [false, true]) {
      if (create) {
        await File(
          '${temp.path}/bad.wasm',
        ).writeAsBytes([0, 97, 115, 109, 1, 0, 0, 0]);
      }
      final report = await runner.executeComponentSpecScript({
        'commands': [
          {'type': 'module', 'filename': 'bad.wasm', 'line': 1},
          {
            'type': 'assert_trap',
            'line': 2,
            'action': {'type': 'invoke', 'field': 'f', 'args': <Object>[]},
            'text': 'invalid utf-8',
          },
        ],
      }, directory: temp);
      expect(report['status'], 'failed');
      expect(
        (report['commands'] as List).every((c) => c['passed'] == false),
        true,
      );
    }
  });

  test('host programming errors are not string traps', () {
    for (final error in [
      TypeError(),
      NoSuchMethodError.withInvocation(
        Object(),
        Invocation.method(#missing, []),
      ),
      const FormatException('invalid component'),
      RangeError.range(1, 0, 0, 'different boundary'),
    ]) {
      for (final expected in [
        'invalid utf-8',
        'incomplete utf-8 byte sequence',
        'string pointer/length out of bounds of memory',
      ]) {
        expect(runner.matchesComponentStringTrap(error, expected), false);
      }
    }
  });

  test(
    'one script retains instance state and module replacement resets it',
    () async {
      final report = await runner.executeComponentSpecScript({
        'commands': [
          {'type': 'module', 'filename': 'stateful_string.wasm', 'line': 1},
          for (final value in ['a', 'b', 'c'])
            {
              'type': 'assert_return',
              'action': {'type': 'invoke', 'field': 'next', 'args': <Object>[]},
              'expected': [
                {'type': 'string', 'value': value},
              ],
            },
          {'type': 'module', 'filename': 'stateful_string.wasm', 'line': 2},
          {
            'type': 'assert_return',
            'action': {'type': 'invoke', 'field': 'next', 'args': <Object>[]},
            'expected': [
              {'type': 'string', 'value': 'a'},
            ],
          },
        ],
      }, directory: Directory('test/fixtures/component_spec/regression'));
      expect(report['status'], 'passed');
      expect((report['totals'] as Map)['commands_passed'], 6);
    },
  );

  test('link and truncated decoding failures cannot satisfy traps', () async {
    final temp = await _copyFixtures();
    addTearDown(() => temp.delete(recursive: true));
    await File(
      '${temp.path}/regression/truncated.wasm',
    ).writeAsBytes([0, 97, 115, 109, 13, 0, 1, 0, 1, 127]);
    for (final (name, trap) in [
      for (final name in ['unlinked.wasm', 'truncated.wasm'])
        for (final trap in ['invalid utf-8', 'invalid `char` bit pattern'])
          (name, trap),
    ]) {
      final report = await runner.executeComponentSpecScript({
        'commands': [
          {'type': 'module', 'filename': name, 'line': 1},
          {
            'type': 'assert_trap',
            'action': {'type': 'invoke', 'field': 'f', 'args': <Object>[]},
            'text': trap,
          },
        ],
      }, directory: Directory('${temp.path}/regression'));
      final commands = report['commands'] as List;
      expect(report['status'], 'failed');
      expect(commands[0]['passed'], false);
      expect(commands[1]['passed'], false);
      expect(commands[1]['error'], contains('No initialized component'));
    }
  });

  for (final corruption in [
    'source',
    'prepared',
    'missing-binary',
    'git-blob',
  ]) {
    test('verified manifest rejects $corruption', () async {
      final temp = await _copyFixtures();
      addTearDown(() => temp.delete(recursive: true));
      final manifest = File('${temp.path}/manifest.json');
      if (corruption == 'source' || corruption == 'prepared') {
        final path = corruption == 'source' ? 'strings.wast' : 'script.json';
        await File('${temp.path}/strings/$path').writeAsString('changed');
      } else if (corruption == 'missing-binary') {
        await File('${temp.path}/strings/script.0.wasm').delete();
      } else {
        final inventory = jsonDecode(await manifest.readAsString()) as Map;
        inventory['files'][0]['blob'] =
            '0000000000000000000000000000000000000000';
        await manifest.writeAsString(jsonEncode(inventory));
      }
      final report = await runner.runComponentSpecManifest(
        manifest,
        usePreparedInputs: true,
      );
      expect(report['status'], 'failed');
      expect((report['totals'] as Map)['files_failed'], 1);
      final error = ((report['files'] as List).single as Map)['error'];
      expect(
        error,
        contains(
          corruption == 'git-blob'
              ? 'Frozen Component source identity mismatch'
              : corruption == 'missing-binary'
              ? 'Cannot open file'
              : 'SHA-256 mismatch',
        ),
      );
    });
  }

  for (final mutation in ['source-and-hashes', 'official-path']) {
    test(
      'frozen source identity rejects coordinated $mutation drift',
      () async {
        final temp = await _copyFixtures();
        addTearDown(() => temp.delete(recursive: true));
        final manifest = File('${temp.path}/manifest.json');
        final inventory = jsonDecode(await manifest.readAsString()) as Map;
        final entry = inventory['files'][0] as Map;
        if (mutation == 'source-and-hashes') {
          final source = File('${temp.path}/strings/strings.wast');
          await source.writeAsString(
            '${await source.readAsString()}\n;; drift\n',
          );
          final bytes = await source.readAsBytes();
          entry['sha256'] = sha256.convert(bytes).toString();
          entry['blob'] = sha1.convert([
            ...utf8.encode('blob ${bytes.length}\u0000'),
            ...bytes,
          ]).toString();
        } else {
          entry['path'] = 'test/values/other.wast';
        }
        await manifest.writeAsString(jsonEncode(inventory));
        final report = await runner.runComponentSpecManifest(
          manifest,
          usePreparedInputs: true,
        );
        expect(report['status'], 'failed');
        expect((report['totals'] as Map)['files_failed'], 1);
        expect(
          ((report['files'] as List).single as Map)['error'],
          contains('Frozen Component source identity mismatch'),
        );
      },
    );
  }

  test(
    'malformed file entries are counted and later files still execute',
    () async {
      final temp = await _copyFixtures();
      addTearDown(() => temp.delete(recursive: true));
      final manifest = File('${temp.path}/manifest.json');
      final inventory = jsonDecode(await manifest.readAsString()) as Map;
      final entry = inventory['files'][0];
      inventory['files'] = [entry, null, entry];
      await manifest.writeAsString(jsonEncode(inventory));
      final report = await runner.runComponentSpecManifest(
        manifest,
        usePreparedInputs: true,
      );
      expect(report['status'], 'failed');
      final totals = report['totals'] as Map;
      expect(totals['files_total'], 3);
      expect(totals['files_passed'], 2);
      expect(totals['files_failed'], 1);
      expect(totals['commands_passed'], 34);
      final files = report['files'] as List;
      expect(files, hasLength(3));
      expect(files[1]['status'], 'failed');
      expect(files[1]['error'], contains('File entry must be an object'));
      expect(files[2]['status'], 'passed');
    },
  );

  test(
    'cleanup failures retain the completed report and mark it failed',
    () async {
      final temp = await _copyFixtures();
      final marker = File('${temp.path}/conversion-path.txt');
      addTearDown(() async {
        if (await marker.exists()) {
          final path = (await marker.readAsString()).trim();
          await Process.run('chmod', ['700', path]);
          final conversion = Directory(path).parent;
          if (await conversion.exists()) {
            await conversion.delete(recursive: true);
          }
        }
        await temp.delete(recursive: true);
      });
      final converter = File('${temp.path}/converter.sh');
      await converter.writeAsString('''#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "wasm-tools 1.262.0 cleanup test converter"
  exit 0
fi
output=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift; output="\$1" ;; esac
  shift
done
cp '${temp.path}/strings/script.json' "\$output"
cp '${temp.path}/strings/'*.wasm .
printf '%s' "\$PWD" > '${marker.path}'
chmod 500 "\$PWD"
''');
      await Process.run('chmod', ['+x', converter.path]);
      final report = await runner.runComponentSpecManifest(
        File('${temp.path}/manifest.json'),
        converter: converter.path,
      );
      expect(report['status'], 'failed');
      expect(report['cleanup_error'], isA<String>());
      final totals = report['totals'] as Map;
      expect(totals['files_total'], 1);
      expect(totals['files_passed'], 1);
      expect(totals['commands_passed'], 17);
    },
    skip: Platform.isWindows ? 'Uses POSIX directory permissions.' : false,
  );

  for (final mixed in [false, true]) {
    test(
      'fresh converter empty output fails even with passing file mixed=$mixed',
      () async {
        final temp = await _copyFixtures();
        addTearDown(() => temp.delete(recursive: true));
        final manifest = File('${temp.path}/manifest.json');
        final inventory = jsonDecode(await manifest.readAsString()) as Map;
        if (mixed) (inventory['files'] as List).add(inventory['files'][0]);
        await manifest.writeAsString(jsonEncode(inventory));
        final converter = File('${temp.path}/converter.sh');
        await converter.writeAsString('''#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "wasm-tools 1.262.0 test converter"
  exit 0
fi
output=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift; output="\$1" ;; esac
  shift
done
case "\$PWD" in
  */0) printf '{"commands":[]}' > "\$output" ;;
  *) cp '${temp.path}/strings/script.json' "\$output"
     cp '${temp.path}/strings/'*.wasm . ;;
esac
''');
        await Process.run('chmod', ['+x', converter.path]);
        final report = await runner.runComponentSpecManifest(
          manifest,
          converter: converter.path,
        );
        expect(report['status'], 'failed');
        final totals = report['totals'] as Map;
        expect(totals['files_total'], mixed ? 2 : 1);
        expect(totals['files_failed'], 1);
        expect(totals['files_passed'], mixed ? 1 : 0);
        expect(totals['commands_passed'], mixed ? 17 : 0);
        expect(totals['commands_skipped'], 0);
        final converterReport = report['converter'] as Map;
        expect(converterReport['version'], contains('1.262.0 test converter'));
        expect(
          converterReport['executable_sha256'],
          sha256.convert(await converter.readAsBytes()).toString(),
        );
      },
    );
  }
}

Future<Directory> _copyFixtures({bool stringsOnly = true}) async {
  final temp = await Directory.systemTemp.createTemp(
    'wasd-component-manifest-',
  );
  final source = Directory('test/fixtures/component_spec');
  for (final entity in source.listSync(recursive: true).whereType<File>()) {
    final target = File(
      '${temp.path}/${entity.path.substring(source.path.length + 1)}',
    );
    await target.parent.create(recursive: true);
    await entity.copy(target.path);
  }
  final manifest = File('${temp.path}/manifest.json');
  final inventory = jsonDecode(await manifest.readAsString()) as Map;
  if (stringsOnly) {
    inventory['files'] = (inventory['files'] as List)
        .where((entry) => entry['path'] == 'test/values/strings.wast')
        .toList();
  }
  await manifest.writeAsString(jsonEncode(inventory));
  return temp;
}

final class _ExecutionError implements WasmExecutionErrorContext {
  _ExecutionError(this.cause);

  @override
  Object cause;
}

final class _UnknownCause implements Exception {
  _UnknownCause(this.cause);

  final Object cause;
}
