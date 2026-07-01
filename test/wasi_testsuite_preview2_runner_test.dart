import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'official Preview2 runner fails when upstream has no P2 tests',
    () async {
      final temp = await Directory.systemTemp.createTemp('wasd_wasip2_empty_');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      await Directory(
        '${temp.path}/tests/rust/testsuite/wasm32-wasip3',
      ).create(recursive: true);
      await File(
        '${temp.path}/tests/rust/testsuite/wasm32-wasip3/random.wasm',
      ).writeAsBytes(const <int>[0]);

      final jsonPath = '${temp.path}/preview2.json';
      final markdownPath = '${temp.path}/preview2.md';
      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview2_runner.dart',
        '--testsuite-dir=${temp.path}',
        '--json=$jsonPath',
        '--markdown=$markdownPath',
      ]);

      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      final payload =
          json.decode(await File(jsonPath).readAsString())
              as Map<String, Object?>;
      final totals = payload['totals'] as Map<String, Object?>;

      expect(payload['status'], 'missing-tests');
      expect(payload['message'], contains('no wasm32-wasip2 test cases'));
      expect(totals['total'], 0);
      expect(
        await File(markdownPath).readAsString(),
        contains('No official `wasm32-wasip2` test directories were found.'),
      );
    },
  );

  test(
    'official Preview2 runner requires every discovered P2 test to pass',
    () async {
      final temp = await Directory.systemTemp.createTemp('wasd_wasip2_pass_');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final suite = Directory(
        '${temp.path}/tests/rust/testsuite/wasm32-wasip2',
      );
      await suite.create(recursive: true);
      await File('${suite.path}/smoke.wasm').writeAsBytes(const <int>[0]);
      final runnerPackage = Directory(
        '${temp.path}/test-runner/wasi_test_runner',
      );
      await runnerPackage.create(recursive: true);
      await File('${runnerPackage.path}/__init__.py').writeAsString('');
      await File('${runnerPackage.path}/__main__.py').writeAsString(r'''
import argparse
import json

parser = argparse.ArgumentParser()
parser.add_argument("--test-suite", action="append", required=True)
parser.add_argument("--runtime-adapter", required=True)
parser.add_argument("--json-output-location", required=True)
parser.add_argument("--disable-colors", action="store_true")
args = parser.parse_args()
with open(args.json_output_location, "w", encoding="utf-8") as f:
    json.dump({
        "results": [{
            "name": args.test_suite[0],
            "runtime": {"name": "fake", "version": "test"},
            "failed": 0,
            "skipped": 0,
            "passed": 1,
            "xfailed": 0,
            "xpassed": 0,
            "tests": [{
                "name": "smoke",
                "executed": True,
                "outcome": "pass",
                "duration_s": 0,
                "failures": []
            }]
        }]
    }, f)
''');
      final adapter = File('${temp.path}/adapter.py');
      await adapter.writeAsString('');

      final jsonPath = '${temp.path}/preview2.json';
      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview2_runner.dart',
        '--testsuite-dir=${temp.path}',
        '--runner-dir=${temp.path}/test-runner',
        '--runtime-adapter=${adapter.path}',
        '--json=$jsonPath',
        '--markdown=${temp.path}/preview2.md',
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final payload =
          json.decode(await File(jsonPath).readAsString())
              as Map<String, Object?>;
      final totals = payload['totals'] as Map<String, Object?>;

      expect(payload['status'], 'passed');
      expect(totals['total'], 1);
      expect(totals['passed'], 1);
      expect(totals['failed'], 0);
      expect(totals['skipped'], 0);
    },
  );
}
