@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wasd/wasi.dart';

import '../tool/wasi_testsuite_preview1_gate.dart' as gate;

void main() {
  test('Preview1 freezes its own WITX and complete official inventory', () {
    final contract = gate.readPreview1Contract();
    final abi = contract['abi'] as Map;
    final suite = contract['testsuite'] as Map;
    expect(abi['commit'], 'fae981bae14809d91f9bc2d63852d461f331d161');
    expect(abi['module'], 'wasi_snapshot_preview1');
    expect((abi['files'] as List).length, 2);
    expect((abi['functions'] as List).length, 46);
    expect(
      (abi['functions'] as List).toSet(),
      WASI().imports['wasi_snapshot_preview1']!.keys.toSet(),
    );
    expect(suite['source_commit'], '6600796756adce3632409d7e207a9834c9d99ff8');
    expect(suite['fixture_commit'], 'c63d52e69316d1aa2c9e7db6251892775204e7e0');
    expect(suite['fixture_count'], 72);
    expect(suite['inputs'], hasLength(137));
    expect((suite['suites'] as List).map((s) => (s['cases'] as List).length), [
      12,
      14,
      46,
    ]);
    expect(
      gate.preview1ExpectedCases(contract).values.expand((v) => v).length,
      72,
    );
  });

  test('the frozen lock has an independent code anchor', () async {
    final directory = await Directory.systemTemp.createTemp('wasd-p1-anchor-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/contract.json');
    final contract = gate.readPreview1Contract();
    contract['testsuite']['source_commit'] = 'different-source';
    contract['testsuite']['inputs'][0]['sha256'] = 'matching-new-input-hash';
    await file.writeAsString(jsonEncode(contract));
    expect(
      () => gate.readPreview1Contract(file: file),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('frozen contract'),
        ),
      ),
    );
  });

  for (final invalid in ['invalid-record', 'duplicate-record']) {
    test('$invalid remains in input failure totals', () async {
      final directory = await Directory.systemTemp.createTemp('wasd-p1-count-');
      addTearDown(() => directory.delete(recursive: true));
      final bytes = utf8.encode('pinned test input');
      await Directory('${directory.path}/a').create();
      await File('${directory.path}/a/a.wasm').writeAsBytes(bytes);
      final input = _input('a/a.wasm', bytes);
      final contract = _contract(
        inputs: [input],
        suites: [
          _suite('a', ['a']),
        ],
      );
      (contract['testsuite']['inputs'] as List).add(
        invalid == 'invalid-record' ? <String, dynamic>{} : {...input},
      );
      final totals = <String, int>{};
      expect(
        () => gate.verifyPreview1Fixtures(contract, directory, totals: totals),
        throwsStateError,
      );
      expect(totals['files_total'], 2);
      expect(totals['files_verified'], 1);
      expect(totals['files_failed'], 1);
    });
  }

  for (final mutation in ['none', 'missing', 'hash', 'blob', 'extra']) {
    test('fixture inventory checks $mutation inputs', () async {
      final directory = await Directory.systemTemp.createTemp('wasd-p1-hash-');
      addTearDown(() => directory.delete(recursive: true));
      final bytes = utf8.encode('pinned test input');
      final file = File('${directory.path}/a/a.wasm');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      final input = _input('a/a.wasm', bytes);
      final contract = _contract(
        inputs: [input],
        suites: [
          _suite('a', ['a']),
        ],
      );
      if (mutation == 'missing') await file.delete();
      if (mutation == 'hash') input['sha256'] = 'bad';
      if (mutation == 'blob') input['git_blob'] = 'bad';
      if (mutation == 'extra') {
        await File('${directory.path}/a/extra.wasm').writeAsBytes(bytes);
      }
      if (mutation == 'none') {
        expect(gate.verifyPreview1Fixtures(contract, directory), 1);
      } else {
        expect(
          () => gate.verifyPreview1Fixtures(contract, directory),
          throwsA(anyOf(isA<StateError>(), isA<FileSystemException>())),
        );
      }
    });
  }

  test('runner inputs are pinned independently of the P3 checkout', () async {
    final directory = await Directory.systemTemp.createTemp('wasd-p1-runner-');
    addTearDown(() => directory.delete(recursive: true));
    final bytes = utf8.encode('official runner');
    final source = File('${directory.path}/runner.py');
    await source.writeAsBytes(bytes);
    final contract = _contract();
    (contract['testsuite'] as Map)['runner_inputs'] = [
      _input('runner.py', bytes),
    ];
    gate.verifyPreview1Runner(contract, directory);
    await source.writeAsString('different runner');
    expect(
      () => gate.verifyPreview1Runner(contract, directory),
      throwsStateError,
    );
  });

  for (final invalid in [
    'empty',
    'duplicate-suite',
    'duplicate-case',
    'count',
  ]) {
    test('contract rejects $invalid case inventory', () {
      final suites = [
        _suite('a', ['one', 'two']),
      ];
      if (invalid == 'empty') suites.clear();
      if (invalid == 'duplicate-suite') suites.add(_suite('a', ['three']));
      if (invalid == 'duplicate-case') suites[0]['cases'] = ['one', 'one'];
      final contract = _contract(suites: suites);
      if (invalid == 'count') {
        (contract['testsuite'] as Map)['fixture_count'] = 99;
      }
      expect(() => gate.preview1ExpectedCases(contract), throwsStateError);
    });
  }

  final contract = _contract(
    suites: [
      _suite('a', ['one', 'two']),
    ],
  );
  test('official results require every unique case to execute and pass', () {
    final report = gate.validatePreview1Results(_results(), contract);
    expect(report['status'], 'passed');
    expect((report['totals'] as Map)['passed'], 2);
    expect((report['totals'] as Map)['executed'], 2);
  });

  test('invalid result records remain in total and failed counts', () {
    final raw = _results();
    raw['results'][0]['tests'][0] = null;
    final report = gate.validatePreview1Results(raw, contract);
    expect(report['status'], 'failed');
    expect((report['totals'] as Map)['total'], 2);
    expect((report['totals'] as Map)['passed'], 1);
    expect((report['totals'] as Map)['failed'], 1);
  });

  test('duplicate suite cases are counted as rejected results', () {
    final raw = _results();
    (raw['results'] as List).add(jsonDecode(jsonEncode(raw['results'][0])));
    final report = gate.validatePreview1Results(raw, contract);
    expect(report['status'], 'failed');
    expect((report['totals'] as Map)['total'], 4);
    expect((report['totals'] as Map)['passed'], 2);
    expect((report['totals'] as Map)['failed'], 2);
  });

  for (final corruption in [
    'empty',
    'duplicate-suite',
    'duplicate-case',
    'missing',
    'extra',
    'not-executed',
    'skip',
    'xfail',
    'xpass',
    'fail',
    'failures',
    'summary',
    'runtime',
    'exit',
  ]) {
    test(
      'official acceptance rejects $corruption even with passing counts',
      () {
        final raw = _results();
        final results = raw['results'] as List;
        final suite = results.single as Map;
        final tests = suite['tests'] as List;
        switch (corruption) {
          case 'empty':
            results.clear();
          case 'duplicate-suite':
            results.add(jsonDecode(jsonEncode(suite)));
          case 'duplicate-case':
            tests[1]['name'] = 'one';
          case 'missing':
            tests.removeLast();
          case 'extra':
            tests.add({...tests[0] as Map, 'name': 'extra'});
          case 'not-executed':
            tests[0]['executed'] = false;
          case 'skip':
          case 'xfail':
          case 'xpass':
          case 'fail':
            tests[0]['outcome'] = corruption;
          case 'failures':
            tests[0]['failures'] = ['unreported failure'];
          case 'summary':
            suite['passed'] = 1;
          case 'runtime':
            suite['runtime'] = {'name': 'a different runtime'};
          case 'exit':
            break;
        }
        final report = gate.validatePreview1Results(
          raw,
          contract,
          runnerExitCode: corruption == 'exit' ? 1 : 0,
        );
        expect(report['status'], 'failed');
        expect(report['failures'], isNotEmpty);
      },
    );
  }
}

Map<String, dynamic> _contract({
  List<Map<String, dynamic>> inputs = const [],
  List<Map<String, dynamic>>? suites,
}) {
  final selected =
      suites ??
      [
        _suite('a', ['a']),
      ];
  return {
    'testsuite': {
      'fixture_count': selected.fold<int>(
        0,
        (count, suite) => count + (suite['cases'] as List).length,
      ),
      'suites': selected,
      'inputs': inputs,
    },
  };
}

Map<String, dynamic> _suite(String name, List<String> cases) => {
  'name': name,
  'path': name,
  'cases': cases,
};

Map<String, dynamic> _input(String path, List<int> bytes) => {
  'path': path,
  'git_blob': sha1.convert([
    ...utf8.encode('blob ${bytes.length}\u0000'),
    ...bytes,
  ]).toString(),
  'sha256': sha256.convert(bytes).toString(),
};

Map<String, dynamic> _results() => {
  'results': <dynamic>[
    {
      'name': 'a',
      'runtime': {'name': 'wasd', 'version': 'test'},
      'passed': 2,
      'failed': 0,
      'skipped': 0,
      'xfailed': 0,
      'xpassed': 0,
      'tests': <dynamic>[
        for (final name in ['one', 'two'])
          {'name': name, 'executed': true, 'outcome': 'pass', 'failures': []},
      ],
    },
  ],
};
