import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/component_spec_runner.dart' as runner;

const _fixture = 'test/fixtures/component_spec/strings';

Map<String, dynamic> _script() =>
    jsonDecode(File('$_fixture/script.json').readAsStringSync())
        as Map<String, dynamic>;

Future<Map<String, Object?>> _run(Map<String, dynamic> script) =>
    runner.executeComponentSpecScript(script, directory: Directory(_fixture));

void main() {
  test('complete frozen strings file executes 8 initializations, 5 returns, '
      'and 4 traps through WASD', () async {
    final report = await runner.runComponentSpecManifest(
      File('test/fixtures/component_spec/manifest.json'),
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
    command['text'] = 'invalid utf-8';
    final report = await _run(script);
    expect(report['status'], 'failed');
    expect((report['commands'] as List)[1]['error'], contains('did not trap'));
  });

  test('missing export cannot satisfy an expected trap', () async {
    final script = _script();
    final command = (script['commands'] as List)[1] as Map;
    command['type'] = 'assert_trap';
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
    for (final name in ['unlinked.wasm', 'truncated.wasm']) {
      final report = await runner.executeComponentSpecScript({
        'commands': [
          {'type': 'module', 'filename': name, 'line': 1},
          {
            'type': 'assert_trap',
            'action': {'type': 'invoke', 'field': 'f', 'args': <Object>[]},
            'text': 'invalid utf-8',
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
              ? 'Git blob mismatch'
              : corruption == 'missing-binary'
              ? 'Cannot open file'
              : 'SHA-256 mismatch',
        ),
      );
    });
  }

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

Future<Directory> _copyFixtures() async {
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
  return temp;
}
