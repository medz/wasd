import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/unicode_scalar.dart';
import 'package:wasd/src/wasi/component/value_memory.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/wasm.dart' show Memory, MemoryDescriptor;
import 'package:wasd/src/wasm/backend/native/interpreter/execution_error.dart';

import '../tool/component_spec_runner.dart' as runner;

const _fixture = 'test/fixtures/component_spec/strings';
const _numerics = 'test/fixtures/component_spec/numerics';
const _realloc = 'test/fixtures/component_spec/realloc';

Map<String, dynamic> _reallocScript() =>
    jsonDecode(File('$_realloc/script.json').readAsStringSync())
        as Map<String, dynamic>;

Future<Map<String, Object?>> _runRealloc(Map<String, dynamic> script) =>
    runner.executeComponentSpecScript(script, directory: Directory(_realloc));

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
  test('official sync-streams returns 42 after caller continuation', () async {
    final directory = Directory('test/fixtures/component_spec/sync_streams');
    final binary = File('${directory.path}/script.0.wasm').readAsBytesSync();
    expect(
      sha256.convert(binary).toString(),
      'b8c9769becaf9aab0d89460c9c2e6fa559ece766ce812efc49b1eb13cc9cd555',
    );
    final scriptBytes = File('${directory.path}/script.json').readAsBytesSync();
    expect(
      sha256.convert(scriptBytes).toString(),
      '3ecdacc33e0f3688a8bedbcec88b52e95fd2820163f106f023334a5dff56e02c',
    );
    final script = jsonDecode(utf8.decode(scriptBytes)) as Map<String, dynamic>;
    expect(script['commands'], hasLength(2));
    final report = await runner
        .executeComponentSpecScript(script, directory: directory)
        .timeout(const Duration(seconds: 2));
    final records = report['commands'] as List;
    expect(records, hasLength(2));
    expect(records[0]['phase'], 'initialize');
    expect(records[0]['status'], 'passed');
    expect(records[1]['type'], 'assert_return');
    expect(records[1]['export'], 'run');
    expect(
      records[1]['status'],
      'passed',
      reason:
          'The original full call must return u32 42: ${jsonEncode(records[1])}',
    );
    final totals = report['totals'] as Map;
    expect(totals['commands_seen'], 2);
    expect(totals['commands_passed'], 2);
    expect(totals['returns_passed'], 1);
    expect(totals['commands_unsupported'], 0);
    expect(totals['commands_not_executed'], 0);
    expect(totals['commands_skipped'], 0);
  });

  group('negative spec commands', () {
    late Directory directory;
    setUp(() async {
      directory = await _negativeFixtures();
      addTearDown(() => directory.delete(recursive: true));
    });

    Future<Map<String, Object?>> run(List<Map<String, Object?>> commands) =>
        runner.executeComponentSpecScript(
          jsonDecode(jsonEncode({'commands': commands}))
              as Map<String, dynamic>,
          directory: directory,
        );

    for (final (type, filename, expected, phase) in [
      (
        'assert_invalid',
        'invalid.wasm',
        'type index out of bounds',
        'validate',
      ),
      (
        'assert_malformed',
        'truncated.wasm',
        'unexpected end-of-file',
        'decode',
      ),
      ('assert_uninstantiable', 'start.wasm', 'unreachable', 'initialize'),
    ]) {
      test('$type matches its phase and preserves current state', () async {
        final report = await run([
          {'type': 'module', 'filename': 'stateful_void.wasm'},
          _bump(5, []),
          _negative(type, filename, expected),
          _count(5),
        ]);
        expect(report['status'], 'passed');
        final records = report['commands'] as List;
        expect(records[2]['status'], 'passed');
        expect(records[2]['phase'], phase);
        expect(records[2]['expected_diagnostic'], expected);
        expect(records[2]['binary_sha256'], matches(r'^[0-9a-f]{64}$'));
        final totals = report['totals'] as Map;
        expect(totals['commands_seen'], 4);
        expect(totals['commands_passed'], 4);
      });
    }

    for (final (type, filename, expected) in [
      ('assert_invalid', 'empty.wasm', 'type index out of bounds'),
      ('assert_invalid', 'truncated.wasm', 'unexpected end-of-file'),
      ('assert_invalid', 'invalid.wasm', 'function index out of bounds'),
      ('assert_malformed', 'empty.wasm', ''),
      ('assert_malformed', 'invalid.wasm', 'type index out of bounds'),
      ('assert_malformed', 'truncated.wasm', 'malformed UTF-8 encoding'),
      ('assert_uninstantiable', 'empty.wasm', 'unreachable'),
      ('assert_uninstantiable', 'invalid.wasm', 'type index out of bounds'),
      ('assert_uninstantiable', 'unlinked.wasm', 'unreachable'),
      ('assert_uninstantiable', 'start.wasm', 'invalid `char` bit pattern'),
    ]) {
      test(
        '$type rejects wrong phase or category: $filename / $expected',
        () async {
          final report = await run([_negative(type, filename, expected)]);
          expect(report['status'], 'failed');
          expect((report['commands'] as List).single['passed'], false);
        },
      );
    }

    for (final (filename, expected) in [
      ('bad-magic.wasm', 'magic header not detected'),
      ('bad-length.wasm', 'integer too large'),
    ]) {
      test('structural $filename matches only its own diagnostic', () async {
        final report = await run([
          _negative('assert_malformed', filename, expected),
          _negative('assert_malformed', filename, ''),
          _negative('assert_malformed', filename, 'unexpected end-of-file'),
        ]);
        final records = report['commands'] as List;
        expect(records[0]['passed'], true);
        expect(records[1]['passed'], true);
        expect(records[2]['passed'], false);
      });
    }

    for (final filename in [
      'bad-version.wasm',
      'bad-layer.wasm',
      'bad-layer-2.wasm',
      'bad-layer-257.wasm',
      'nested-bad-version.wasm',
      'nested-core-header.wasm',
    ]) {
      test(
        'ambiguous $filename diagnostic cannot satisfy assertions',
        () async {
          final report = await run([
            for (final expected in [
              'unknown binary version',
              'expected a version header for a component',
              '',
            ])
              _negative('assert_malformed', filename, expected),
          ]);
          final records = report['commands'] as List;
          for (final record in records) {
            expect(record['passed'], false);
            expect(record['status'], 'unsupported');
            expect(record['failure_kind'], 'unsupported_diagnostic');
            expect(record['phase'], 'decode');
          }
          expect((report['totals'] as Map)['commands_passed'], 0);
        },
      );
    }

    test(
      'u32 overflow and overlong representation are distinct malformed causes',
      () async {
        final report = await run([
          _negative(
            'assert_malformed',
            'overlong-length.wasm',
            'integer representation too long',
          ),
          _negative(
            'assert_malformed',
            'overlong-length.wasm',
            'integer too large',
          ),
          _negative('assert_malformed', 'bad-length.wasm', 'integer too large'),
          _negative(
            'assert_malformed',
            'bad-length.wasm',
            'integer representation too long',
          ),
        ]);
        final records = report['commands'] as List;
        expect(records[0]['passed'], true);
        expect(records[1]['passed'], false);
        expect(records[2]['passed'], true);
        expect(records[3]['passed'], false);
      },
    );

    for (final type in [
      'assert_invalid',
      'assert_malformed',
      'assert_uninstantiable',
    ]) {
      test('$type reports missing input outside its assertion', () async {
        final report = await run([_negative(type, 'missing.wasm', '')]);
        final record = (report['commands'] as List).single as Map;
        expect(record['passed'], false);
        expect(record['phase'], 'input');
        expect(record['error_type'], 'PathNotFoundException');
      });
    }

    test(
      'unsupported binary features and text remain explicit non-passes',
      () async {
        final report = await run([
          _negative(
            'assert_invalid',
            'forward.wasm',
            '`stream.forward` requires a stream type',
          ),
          _negative('assert_malformed', 'forward.wasm', ''),
          _negative('assert_malformed', 'future-forward.wasm', ''),
          {
            ..._negative(
              'assert_malformed',
              'quote.wat',
              'invalid string escape',
            ),
            'module_type': 'text',
          },
        ]);
        final records = report['commands'] as List;
        expect(records.every((record) => record['passed'] == false), true);
        expect(records[0]['failure_kind'], 'unsupported_feature');
        expect(records[0]['phase'], 'decode');
        expect(records[1]['failure_kind'], 'unsupported_feature');
        expect(records[2]['failure_kind'], 'unsupported_feature');
        expect(records[3]['failure_kind'], 'unsupported_text');
        final totals = report['totals'] as Map;
        expect(totals['commands_unsupported'], 4);
        expect(totals['commands_passed'], 0);
        expect(totals['commands_skipped'], 0);
      },
    );

    test('standalone action invokes once and ignores its result', () async {
      final report = await run([
        {'type': 'module', 'filename': 'stateful_void.wasm'},
        {'type': 'action', 'action': _bump(3, [])['action']},
        {'type': 'action', 'action': _count(0)['action']},
        _count(3),
      ]);
      expect(report['status'], 'passed');
      final totals = report['totals'] as Map;
      expect(totals['actions_passed'], 2);
      expect(totals['returns_passed'], 1);
    });

    test('invalid standalone action cannot mutate state', () async {
      final report = await run([
        {'type': 'module', 'filename': 'stateful_void.wasm'},
        {'type': 'action', 'action': _bump(3, [])['action'], 'expected': []},
        _count(0),
      ]);
      final records = report['commands'] as List;
      expect(records[1]['passed'], false);
      expect(records[1]['phase'], 'input');
      expect(records[2]['passed'], true);
    });

    test(
      'initialization trap matcher rejects host errors and unknown wrappers',
      () {
        final trap = WasmUnreachableTrap();
        final cycle = _ExecutionError(trap);
        cycle.cause = cycle;
        for (final expected in [
          'unreachable',
          'wasm trap: wasm `unreachable` instruction executed',
        ]) {
          expect(
            runner.matchesComponentInitializationTrap(
              _ExecutionError(_ExecutionError(trap)),
              expected,
            ),
            true,
          );
          for (final error in [
            trap,
            StateError('unreachable trap'),
            _ExecutionError(StateError('unreachable trap')),
            _UnknownCause(trap),
            _ExecutionError(_UnknownCause(trap)),
            const FormatException('unreachable'),
            cycle,
          ]) {
            expect(
              runner.matchesComponentInitializationTrap(error, expected),
              false,
            );
          }
        }
        expect(
          runner.matchesComponentInitializationTrap(
            _ExecutionError(trap),
            'any error',
          ),
          false,
        );
      },
    );

    test(
      'failed module records dependencies and independent module recovers',
      () async {
        final report = await run([
          {'type': 'module', 'filename': 'stateful_void.wasm'},
          _bump(9, []),
          {'type': 'module', 'filename': 'unlinked.wasm'},
          _count(9),
          {'type': 'module', 'filename': 'stateful_void.wasm'},
          _count(0),
        ]);
        final records = report['commands'] as List;
        expect(records[2]['status'], 'failed');
        expect(records[3]['status'], 'not_executed');
        expect(records[3]['dependency_index'], 2);
        expect(records[4]['passed'], true);
        expect(records[5]['passed'], true);
        final totals = report['totals'] as Map;
        expect(totals['commands_not_executed'], 1);
        expect(totals['commands_failed'], 1);
        expect(totals['commands_seen'], 6);
      },
    );

    test('failed definition replacement cannot reuse old bytes', () async {
      Map<String, Object?> definition(String file) => {
        'type': 'module_definition',
        'name': 'Counter',
        'filename': file,
      };
      final instance = <String, Object?>{
        'type': 'module_instance',
        'module': 'Counter',
        'instance': 'counter',
      };
      final report = await run([
        {'type': 'module', 'filename': 'stateful_void.wasm'},
        _bump(7, []),
        definition('stateful_void.wasm'),
        definition('invalid.wasm'),
        _count(7),
        instance,
        _count(0),
        definition('stateful_void.wasm'),
        instance,
        _count(0),
      ]);
      final records = report['commands'] as List;
      expect(records[3]['passed'], false);
      expect(records[4]['passed'], true);
      expect(records[5]['status'], 'not_executed');
      expect(records[5]['dependency_index'], 3);
      expect(records[6]['status'], 'not_executed');
      expect(records[6]['dependency_index'], 5);
      expect(records[7]['passed'], true);
      expect(records[8]['passed'], true);
      expect(records[9]['passed'], true);
    });

    for (final (type, encoding) in [
      ('assert_invalid', 'binary'),
      ('assert_malformed', 'binary'),
      ('assert_malformed', 'text'),
      ('assert_uninstantiable', 'binary'),
    ]) {
      test(
        'prepared $type / $encoding input must have a verified hash',
        () async {
          final temp = await _copyFixtures();
          addTearDown(() => temp.delete(recursive: true));
          final manifest = File('${temp.path}/manifest.json');
          final inventory = jsonDecode(await manifest.readAsString()) as Map;
          final entry = (inventory['files'] as List).single as Map;
          final prepared = File('${temp.path}/${entry['prepared']}');
          final script = jsonDecode(await prepared.readAsString()) as Map;
          (script['commands'] as List).add({
            ..._negative(type, 'unverified.input', ''),
            'module_type': encoding,
          });
          await prepared.writeAsString(jsonEncode(script));
          for (final input in entry['inputs'] as List) {
            if (input['path'] == entry['prepared']) {
              input['sha256'] = sha256
                  .convert(await prepared.readAsBytes())
                  .toString();
            }
          }
          await manifest.writeAsString(jsonEncode(inventory));
          final report = await runner.runComponentSpecManifest(
            manifest,
            usePreparedInputs: true,
          );
          final file = (report['files'] as List).single as Map;
          expect(file['status'], 'failed');
          expect(file['error'], contains('has no verified hash'));
          expect(file['commands'], isNull);
        },
      );
    }
  });

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

  test(
    'original two complete frozen files still execute all 43 commands',
    () async {
      final temp = await _copyFixtures(stringsOnly: false);
      addTearDown(() => temp.delete(recursive: true));
      final report = await runner.runComponentSpecManifest(
        File('${temp.path}/manifest.json'),
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
    },
  );

  test('complete frozen realloc file executes 6 initializations, '
      '4 definitions, 1 return, and 5 traps through WASD', () async {
    final report = await _runRealloc(_reallocScript());
    expect(report['status'], 'passed');
    final totals = report['totals'] as Map;
    expect(totals['commands_seen'], 16);
    expect(totals['commands_passed'], 16);
    expect(totals['commands_failed'], 0);
    expect(totals['commands_skipped'], 0);
    expect(totals['instantiations_passed'], 6);
    expect(totals['definitions_passed'], 4);
    expect(totals['returns_passed'], 1);
    expect(totals['traps_passed'], 5);
  });

  test('four complete frozen files execute all 61 commands', () async {
    final report = await runner.runComponentSpecManifest(
      File('test/fixtures/component_spec/manifest.json'),
      usePreparedInputs: true,
    );
    expect(report['status'], 'passed');
    final totals = report['totals'] as Map;
    expect(totals['files_total'], 4);
    expect(totals['files_passed'], 4);
    expect(totals['commands_passed'], 61);
    expect(totals['commands_failed'], 0);
    expect(totals['commands_skipped'], 0);
    expect(totals['instantiations_passed'], 24);
    expect(totals['definitions_passed'], 5);
    expect(totals['returns_passed'], 20);
    expect(totals['traps_passed'], 12);
  });

  for (final (name, argument) in <(String, Object?)>[
    ('wrong outer type', {'type': 'tuple', 'value': <Object>[]}),
    ('non-list payload', {'type': 'list', 'value': 1}),
    (
      'non-value element',
      {
        'type': 'list',
        'value': [1],
      },
    ),
    (
      'wrong element type',
      {
        'type': 'list',
        'value': [
          {'type': 'u8', 'value': '1'},
        ],
      },
    ),
    (
      'negative element',
      {
        'type': 'list',
        'value': [
          {'type': 'u32', 'value': '-1'},
        ],
      },
    ),
    (
      'overflow element',
      {
        'type': 'list',
        'value': [
          {'type': 'u32', 'value': '4294967296'},
        ],
      },
    ),
    (
      'numeric JSON element',
      {
        'type': 'list',
        'value': [
          {'type': 'u32', 'value': 1},
        ],
      },
    ),
    (
      'nondecimal element',
      {
        'type': 'list',
        'value': [
          {'type': 'u32', 'value': '0x1'},
        ],
      },
    ),
    (
      'unknown outer field',
      {'type': 'list', 'value': <Object>[], 'extra': true},
    ),
    (
      'unknown element field',
      {
        'type': 'list',
        'value': [
          {'type': 'u32', 'value': '1', 'extra': true},
        ],
      },
    ),
  ]) {
    test(
      'realloc trap rejects malformed list argument $name before invocation',
      () async {
        final commands = _reallocScript()['commands'] as List;
        final assertion = commands[10] as Map;
        assertion['action']['args'] = [argument];
        final report = await _runRealloc({
          'commands': [commands[8], commands[9], assertion],
        });
        final records = report['commands'] as List;
        expect(records[0]['passed'], true);
        expect(records[1]['passed'], true);
        expect(records[2]['passed'], false);
        expect(
          records[2]['error_type'],
          anyOf('FormatException', 'UnsupportedError'),
        );
        expect(
          records[2]['error'],
          isNot(contains('Unexpected invocation error')),
        );
      },
    );
  }

  for (final elements in <List<String>>[
    [],
    ['0'],
    ['4294967295'],
  ]) {
    test(
      'realloc list arguments accept u32 boundary values $elements',
      () async {
        final commands = _reallocScript()['commands'] as List;
        commands[10]['action']['args'] = [
          {
            'type': 'list',
            'value': [
              for (final value in elements) {'type': 'u32', 'value': value},
            ],
          },
        ];
        final report = await _runRealloc({
          'commands': [commands[8], commands[9], commands[10]],
        });
        expect(report['status'], 'passed');
        expect((report['totals'] as Map)['commands_passed'], 3);
      },
    );
  }

  test(
    'memory trap categories only accept ABI-origin errors through typed causes',
    () {
      final bounds = _listReallocError(-4);
      final alignment = _listReallocError(-1);
      expect(bounds, isA<WASIComponentMemoryBoundsException>());
      expect(alignment, isA<WASIComponentMemoryAlignmentException>());
      for (final expected in [
        'wasm trap: list content out-of-bounds',
        'realloc return: beyond end of memory',
      ]) {
        expect(runner.matchesComponentMemoryTrap(bounds, expected), true);
        expect(
          runner.matchesComponentMemoryTrap(
            _ExecutionError(_ExecutionError(bounds)),
            expected,
          ),
          true,
        );
        expect(runner.matchesComponentMemoryTrap(alignment, expected), false);
      }
      for (final expected in [
        'wasm trap: unaligned pointer',
        'realloc return: result not aligned',
      ]) {
        expect(runner.matchesComponentMemoryTrap(alignment, expected), true);
        expect(
          runner.matchesComponentMemoryTrap(
            _ExecutionError(_ExecutionError(alignment)),
            expected,
          ),
          true,
        );
        expect(runner.matchesComponentMemoryTrap(bounds, expected), false);
      }
      expect(runner.matchesComponentMemoryTrap(bounds, 'any error'), false);
      final cycle = _ExecutionError(bounds);
      cycle.cause = cycle;
      for (final error in [
        _listReallocError(
          -4,
          callbackError: RangeError.range(-4, 0, 65536, 'pointer + byteLength'),
        ),
        _listReallocError(
          -1,
          callbackError: StateError('pointer must be 4-byte aligned.'),
        ),
        _ExecutionError(StateError('pointer must be 4-byte aligned.')),
        _ExecutionError(RangeError.range(-4, 0, 65536, 'pointer + byteLength')),
        _UnknownCause(bounds),
        _UnknownCause(alignment),
        cycle,
        TypeError(),
        const FormatException('unaligned pointer'),
        UnsupportedError('realloc return: beyond end of memory'),
      ]) {
        for (final expected in [
          'wasm trap: list content out-of-bounds',
          'realloc return: beyond end of memory',
          'wasm trap: unaligned pointer',
          'realloc return: result not aligned',
        ]) {
          expect(runner.matchesComponentMemoryTrap(error, expected), false);
        }
      }
    },
  );

  test('an empty list cannot hide a non-u32 export element type', () async {
    final temp = await Directory.systemTemp.createTemp(
      'wasd-component-list-type-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final bytes = await File('$_realloc/script.3.wasm').readAsBytes();
    final lists = [
      for (var i = 0; i + 1 < bytes.length; i++)
        if (bytes[i] == 0x70 && bytes[i + 1] == 0x79) i,
    ];
    expect(lists, hasLength(1));
    bytes[lists.single + 1] =
        0x7d; // Change only the list element from u32 to u8.
    await File('${temp.path}/list-u8.wasm').writeAsBytes(bytes);
    final report = await runner.executeComponentSpecScript({
      'commands': [
        {'type': 'module', 'filename': 'list-u8.wasm'},
        {
          'type': 'assert_trap',
          'action': {
            'type': 'invoke',
            'field': 'f',
            'args': [
              {'type': 'list', 'value': <Object>[]},
            ],
          },
          'text': 'realloc return: beyond end of memory',
        },
      ],
    }, directory: temp);
    final records = report['commands'] as List;
    expect(records[0]['passed'], true);
    expect(records[1]['passed'], false);
    expect(records[1]['error'], contains('Unsupported Component value type'));
  });

  for (final (index, wrongTrap) in [
    (4, 'wasm trap: unaligned pointer'),
    (7, 'wasm trap: list content out-of-bounds'),
    (10, 'realloc return: result not aligned'),
    (15, 'realloc return: beyond end of memory'),
  ]) {
    test(
      'realloc invocation at command $index cannot satisfy $wrongTrap',
      () async {
        final commands = _reallocScript()['commands'] as List;
        commands[index]['text'] = wrongTrap;
        final report = await _runRealloc({
          'commands': commands.sublist(0, index + 1),
        });
        final record = (report['commands'] as List).last as Map;
        expect(record['passed'], false);
        expect(record['error'], contains('Unexpected invocation error'));
      },
    );
  }

  test(
    'memory traps reject missing exports and successful invocations',
    () async {
      for (final field in ['absent', 'run']) {
        final commands = _reallocScript()['commands'] as List;
        final report = await _runRealloc({
          'commands': [
            commands.first,
            {
              'type': 'assert_trap',
              'action': {'type': 'invoke', 'field': field, 'args': <Object>[]},
              'text': 'realloc return: beyond end of memory',
            },
          ],
        });
        final records = report['commands'] as List;
        expect(records.first['passed'], true);
        expect(records.last['passed'], false);
        expect(
          records.last['error'],
          contains(field == 'absent' ? 'not found' : 'did not trap'),
        );
      }
    },
  );

  for (final corruption in [
    'source-and-hashes',
    'missing-binary-hash',
    'command-count',
  ]) {
    test('realloc frozen manifest rejects $corruption', () async {
      final temp = await _copyFixtures(
        stringsOnly: false,
        includeRealloc: true,
      );
      addTearDown(() => temp.delete(recursive: true));
      final manifest = File('${temp.path}/manifest.json');
      final inventory = jsonDecode(await manifest.readAsString()) as Map;
      final entry =
          (inventory['files'] as List).firstWhere(
                (entry) => entry['path'] == 'test/values/realloc.wast',
              )
              as Map;
      inventory['files'] = [entry];
      if (corruption == 'source-and-hashes') {
        final source = File('${temp.path}/${entry['source']}');
        await source.writeAsString(
          '${await source.readAsString()}\n;; drift\n',
        );
        final bytes = await source.readAsBytes();
        entry['sha256'] = sha256.convert(bytes).toString();
        entry['blob'] = sha1.convert([
          ...utf8.encode('blob ${bytes.length}\u0000'),
          ...bytes,
        ]).toString();
      } else if (corruption == 'missing-binary-hash') {
        (entry['inputs'] as List).removeWhere(
          (input) => input['path'] == 'realloc/script.3.wasm',
        );
      } else {
        entry['commands'] = 15;
      }
      await manifest.writeAsString(jsonEncode(inventory));
      final report = await runner.runComponentSpecManifest(
        manifest,
        usePreparedInputs: true,
      );
      expect(report['status'], 'failed');
      final file = (report['files'] as List).single as Map;
      expect(
        file['error'],
        contains(
          corruption == 'missing-binary-hash'
              ? 'Binary has no verified hash'
              : 'Frozen Component source identity mismatch',
        ),
      );
    });
  }

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

  test('void assertions invoke exactly once and retain state', () async {
    final report = await runner.executeComponentSpecScript({
      'commands': [
        {'type': 'module', 'filename': 'stateful_void.wasm'},
        _bump(3, []),
        _count(3),
        _bump(4, []),
        _count(7),
      ],
    }, directory: Directory('test/fixtures/component_spec/regression'));
    expect(report['status'], 'passed');
    expect((report['totals'] as Map)['returns_passed'], 4);
    final records = report['commands'] as List;
    expect(records[1]['actual'], null);
    expect(records[3]['actual'], null);
  });

  for (final expected in <Object?>[
    null,
    <String, Object>{},
    [
      {'type': 'u32', 'value': '0'},
    ],
    [
      {'type': 'u32', 'value': '0'},
      {'type': 'u32', 'value': '0'},
    ],
  ]) {
    test(
      'incompatible void expectation $expected cannot mutate state',
      () async {
        final report = await runner.executeComponentSpecScript({
          'commands': [
            {'type': 'module', 'filename': 'stateful_void.wasm'},
            _bump(3, expected),
            _count(0),
          ],
        }, directory: Directory('test/fixtures/component_spec/regression'));
        final records = report['commands'] as List;
        expect(report['status'], 'failed');
        expect(records[0]['passed'], true);
        expect(records[1]['passed'], false);
        expect(records[2]['passed'], true);
      },
    );
  }

  test('empty expectation rejects a value result before invoking it', () async {
    final report = await runner.executeComponentSpecScript({
      'commands': [
        {'type': 'module', 'filename': 'stateful_string.wasm'},
        {
          'type': 'assert_return',
          'action': {'type': 'invoke', 'field': 'next', 'args': <Object>[]},
          'expected': <Object>[],
        },
        _next('a'),
      ],
    }, directory: Directory('test/fixtures/component_spec/regression'));
    final records = report['commands'] as List;
    expect(report['status'], 'failed');
    expect(records[1]['passed'], false);
    expect(records[2]['passed'], true);
  });

  for (final filename in ['stateful_string.wasm', 'unlinked.wasm']) {
    test('anonymous definition $filename validates without instantiating '
        'or replacing the current instance', () async {
      final report = await runner.executeComponentSpecScript({
        'commands': [
          {'type': 'module', 'filename': 'stateful_string.wasm'},
          _next('a'),
          {'type': 'module_definition', 'filename': filename},
          _next('b'),
        ],
      }, directory: Directory('test/fixtures/component_spec/regression'));
      expect(report['status'], 'passed');
      final totals = report['totals'] as Map;
      expect(totals['commands_passed'], 4);
      expect(totals['instantiations_passed'], 1);
      expect(totals['definitions_passed'], 1);
    });
  }

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
      '$_realloc/realloc.wast',
      '$_realloc/script.json',
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
        for (final trap in [
          'invalid utf-8',
          'invalid `char` bit pattern',
          'wasm trap: list content out-of-bounds',
          'realloc return: result not aligned',
        ])
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

Map<String, Object?> _bump(int amount, Object? expected) => {
  'type': 'assert_return',
  'action': {
    'type': 'invoke',
    'field': 'bump',
    'args': [
      {'type': 'u32', 'value': '$amount'},
    ],
  },
  'expected': expected,
};

Map<String, Object?> _negative(String type, String filename, String text) => {
  'type': type,
  'filename': filename,
  'module_type': 'binary',
  'text': text,
};

Future<Directory> _negativeFixtures() async {
  final directory = await Directory.systemTemp.createTemp(
    'wasd-negative-spec-',
  );
  for (final filename in ['stateful_void.wasm', 'unlinked.wasm']) {
    await File(
      'test/fixtures/component_spec/regression/$filename',
    ).copy('${directory.path}/$filename');
  }
  // Negative inputs from fixed 0220 binary.wast and async/forward.wast;
  // start.wasm is a synthetic Core start containing only unreachable/end.
  for (final entry in const {
    'invalid.wasm': 'AGFzbQ0AAQAHAwFwAA==',
    'truncated.wasm': 'AGFzbQ0AAQAHAwA=',
    'forward.wasm':
        'AGFzbQ0AAQAHBAFlAX0IAwEuAAAfDmNvbXBvbmVudC1uYW1lAQYAAAEAAWYBBgMBAAJGVA==',
    'start.wasm':
        'AGFzbQ0AAQABMQBhc20BAAAAAQQBYAAAAwIBAAgBAAoFAQMAAAsAEwRuYW1lAAIBbQEIAQAFc3RhcnQCBAEAAAAAFw5jb21wb25lbnQtbmFtZQEGABEBAAFt',
    'empty.wasm': 'AGFzbQ0AAQA=',
    'bad-magic.wasm': 'AWFzbQ0AAQA=',
    'bad-version.wasm': 'AGFzbQ4AAQA=',
    'bad-layer.wasm': 'AGFzbQ0AAAA=',
    'bad-layer-2.wasm': 'AGFzbQ0AAgA=',
    'bad-layer-257.wasm': 'AGFzbQ0AAQE=',
    'nested-bad-version.wasm': 'AGFzbQ0AAQAECABhc20MAAEA',
    'nested-core-header.wasm': 'AGFzbQ0AAQAECABhc20BAAAA',
    'bad-length.wasm': 'AGFzbQ0AAQAH/////xA=',
    'overlong-length.wasm': 'AGFzbQ0AAQAHgICAgIAA',
    'future-forward.wasm':
        'AGFzbQ0AAQAHBAFmAX0IAwEvAAAfDmNvbXBvbmVudC1uYW1lAQYAAAEAAWYBBgMBAAJTVA==',
  }.entries) {
    await File(
      '${directory.path}/${entry.key}',
    ).writeAsBytes(base64Decode(entry.value));
  }
  await File('${directory.path}/quote.wat').writeAsString('(component "\\q")');
  return directory;
}

Map<String, Object?> _count(int value) => {
  'type': 'assert_return',
  'action': {'type': 'invoke', 'field': 'count', 'args': <Object>[]},
  'expected': [
    {'type': 'u32', 'value': '$value'},
  ],
};

Map<String, Object?> _next(String value) => {
  'type': 'assert_return',
  'action': {'type': 'invoke', 'field': 'next', 'args': <Object>[]},
  'expected': [
    {'type': 'string', 'value': value},
  ],
};

Future<Directory> _copyFixtures({
  bool stringsOnly = true,
  bool includeRealloc = false,
  bool includeSyncStreams = false,
}) async {
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
  if (!includeSyncStreams) {
    inventory['files'] = (inventory['files'] as List)
        .where((entry) => entry['path'] != 'test/async/sync-streams.wast')
        .toList();
  }
  if (!includeRealloc) {
    inventory['files'] = (inventory['files'] as List)
        .where((entry) => entry['path'] != 'test/values/realloc.wast')
        .toList();
  }
  await manifest.writeAsString(jsonEncode(inventory));
  return temp;
}

Object _listReallocError(int pointer, {Object? callbackError}) {
  final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
    const WasmComponentValueType.typeIndex(0),
    const [
      WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.definedValue,
        definedValue: WasmComponentDefinedValueType(
          kind: WasmComponentDefinedValueTypeKind.list,
          elementType: WasmComponentValueType.primitive(
            WasmComponentPrimitiveValueType.u32,
          ),
        ),
      ),
    ],
  )!;
  final memory = Memory(const MemoryDescriptor(initial: 1));
  try {
    codec.storeFlatList(
      memory,
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.list,
        rawBytes: Uint8List(0),
      ),
      realloc: (_, _, _, _) {
        if (callbackError != null) throw callbackError;
        return pointer;
      },
    );
  } catch (error) {
    return error;
  }
  throw StateError('Expected canonical list realloc to fail.');
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
