import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'wasd official adapter advertises Preview2 CLI command support',
    () async {
      final adapterPath = File(
        'tool/wasi_testsuite_wasd_adapter.py',
      ).absolute.path;
      final result = await Process.run('python3', <String>[
        '-c',
        '''
import importlib.util
import json

spec = importlib.util.spec_from_file_location("adapter", ${json.encode(adapterPath)})
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
payload = {
    "versions": adapter.get_wasi_versions(),
    "worlds": adapter.get_wasi_worlds(),
    "p1": adapter.compute_argv(
        "p1.wasm",
        (["a", "b"], {"foo": "bar"}, "/tmp/root"),
        [],
        "wasi:cli/command",
        "wasm32-wasip1",
    ),
    "p2": adapter.compute_argv(
        "p2.wasm",
        (["a", "b"], {"foo": "bar"}, "/tmp/root"),
        [],
        "wasi:cli/command",
        "wasm32-wasip2",
    ),
}
print(json.dumps(payload))
''',
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final payload =
          json.decode(result.stdout as String) as Map<String, Object?>;
      final versions = (payload['versions'] as List<Object?>).cast<String>();
      final worlds = (payload['worlds'] as List<Object?>).cast<String>();
      final p1 = (payload['p1'] as List<Object?>).cast<String>();
      final p2 = (payload['p2'] as List<Object?>).cast<String>();

      expect(versions, containsAll(<String>['wasm32-wasip1', 'wasm32-wasip2']));
      expect(worlds, ['wasi:cli/command']);
      expect(p1, contains(endsWith('wasi_testsuite_preview1_runner.dart')));
      expect(
        p2,
        contains(endsWith('wasi_testsuite_preview2_component_runner.dart')),
      );
      expect(
        p2,
        containsAll(<String>[
          '--env',
          'foo=bar',
          '--dir',
          '/tmp/root::/',
          'p2.wasm',
          'a',
          'b',
        ]),
      );
    },
  );

  test(
    'Preview2 component runner rejects components without command exports',
    () async {
      final temp = await Directory.systemTemp.createTemp('wasd_wasip2_runner_');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final component = File('${temp.path}/empty.component.wasm');
      await component.writeAsBytes(const <int>[
        0x00,
        0x61,
        0x73,
        0x6d,
        0x0d,
        0x00,
        0x01,
        0x00,
      ]);

      final version = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview2_component_runner.dart',
        '--version',
      ]);
      expect(
        version.exitCode,
        0,
        reason: '${version.stdout}\n${version.stderr}',
      );
      expect(version.stdout, contains('wasd-preview2-runner local'));

      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview2_component_runner.dart',
        '--env=foo=bar',
        '--dir=${temp.path}::/',
        component.path,
        'a',
        'b',
      ]);

      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stderr, contains('does not export wasi:cli/run@0.2.x'));
    },
  );

  test(
    'Preview2 component runner executes a minimal command component',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_wasip2_command_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final component = File('${temp.path}/run.component.wasm');
      await component.writeAsBytes(_minimalPreview2CommandComponentBytes());

      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview2_component_runner.dart',
        '--dir=${temp.path}::/',
        component.path,
        'a',
        'b',
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  test(
    'Preview2 component runner executes a lowered standard import',
    () async {
      final temp = await Directory.systemTemp.createTemp('wasd_wasip2_lower_');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final component = await _compileComponentWat(
        temp,
        'random_call',
        _loweredRandomCommandWat,
      );

      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview2_component_runner.dart',
        component.path,
        'a',
        'b',
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

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

Future<File> _compileComponentWat(
  Directory directory,
  String name,
  String source,
) async {
  final wat = File('${directory.path}/$name.wat');
  final wasm = File('${directory.path}/$name.wasm');
  await wat.writeAsString(source);
  final result = await Process.run('.toolchains/bin/wasm-tools', <String>[
    'parse',
    wat.path,
    '-o',
    wasm.path,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return wasm;
}

const String _loweredRandomCommandWat = r'''
(component
  (type $get_ty (func (result u64)))
  (type $random_ty (instance
    (export "get-random-u64" (func (type $get_ty)))))
  (import "wasi:random/random@0.2.0" (instance $random (type $random_ty)))
  (alias export $random "get-random-u64" (func $get_random_u64))
  (core func $get_random_u64_core (canon lower (func $get_random_u64)))
  (core instance $random_core
    (export "get-random-u64" (func $get_random_u64_core)))

  (core module $main
    (import "random" "get-random-u64"
      (func $get_random_u64 (result i64)))
    (func (export "run") (result i32)
      call $get_random_u64
      drop
      i32.const 0))
  (core instance $main_i
    (instantiate $main (with "random" (instance $random_core))))
  (alias core export $main_i "run" (core func $run_core))
  (type $run_ty (func (result (result))))
  (func $run (type $run_ty) (canon lift (core func $run_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.2.0" (instance $run_instance))
)
''';

List<int> _minimalPreview2CommandComponentBytes() => const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x01,
  0x2f,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x05,
  0x01,
  0x60,
  0x00,
  0x01,
  0x7f,
  0x03,
  0x02,
  0x01,
  0x00,
  0x07,
  0x07,
  0x01,
  0x03,
  0x72,
  0x75,
  0x6e,
  0x00,
  0x00,
  0x0a,
  0x06,
  0x01,
  0x04,
  0x00,
  0x41,
  0x00,
  0x0b,
  0x00,
  0x09,
  0x04,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x00,
  0x02,
  0x01,
  0x6d,
  0x02,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x06,
  0x09,
  0x01,
  0x00,
  0x00,
  0x01,
  0x00,
  0x03,
  0x72,
  0x75,
  0x6e,
  0x07,
  0x08,
  0x02,
  0x6a,
  0x00,
  0x00,
  0x40,
  0x00,
  0x00,
  0x00,
  0x08,
  0x06,
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x05,
  0x0a,
  0x01,
  0x01,
  0x01,
  0x00,
  0x03,
  0x72,
  0x75,
  0x6e,
  0x01,
  0x00,
  0x0b,
  0x18,
  0x01,
  0x00,
  0x12,
  0x77,
  0x61,
  0x73,
  0x69,
  0x3a,
  0x63,
  0x6c,
  0x69,
  0x2f,
  0x72,
  0x75,
  0x6e,
  0x40,
  0x30,
  0x2e,
  0x32,
  0x2e,
  0x30,
  0x05,
  0x00,
  0x00,
  0x00,
  0x55,
  0x0e,
  0x63,
  0x6f,
  0x6d,
  0x70,
  0x6f,
  0x6e,
  0x65,
  0x6e,
  0x74,
  0x2d,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x01,
  0x0d,
  0x00,
  0x00,
  0x01,
  0x00,
  0x08,
  0x72,
  0x75,
  0x6e,
  0x5f,
  0x63,
  0x6f,
  0x72,
  0x65,
  0x01,
  0x06,
  0x00,
  0x11,
  0x01,
  0x00,
  0x01,
  0x6d,
  0x01,
  0x06,
  0x00,
  0x12,
  0x01,
  0x00,
  0x01,
  0x69,
  0x01,
  0x07,
  0x01,
  0x01,
  0x00,
  0x03,
  0x72,
  0x75,
  0x6e,
  0x01,
  0x0a,
  0x03,
  0x01,
  0x01,
  0x06,
  0x72,
  0x75,
  0x6e,
  0x5f,
  0x74,
  0x79,
  0x01,
  0x10,
  0x05,
  0x01,
  0x00,
  0x0c,
  0x72,
  0x75,
  0x6e,
  0x5f,
  0x69,
  0x6e,
  0x73,
  0x74,
  0x61,
  0x6e,
  0x63,
  0x65,
];
