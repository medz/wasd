import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/wasi_testsuite_preview1_gate.dart' as gate;

import 'support/wasm_fixtures.dart';

void main() {
  test('Preview1 native runner keeps a single path and literal argv', () async {
    if (Platform.isWindows) {
      markTestSkipped('native gate targets Linux and macOS');
      return;
    }
    final temp = await Directory.systemTemp.createTemp('wasd-p1-aot-argv-');
    addTearDown(() => temp.delete(recursive: true));
    final executable = File('${temp.path}/runner with spaces');
    await executable.writeAsString('''#!/usr/bin/env python3
import json,sys
print(json.dumps(sys.argv[1:]))
''');
    expect((await Process.run('chmod', ['+x', executable.path])).exitCode, 0);
    final marker = File('${temp.path}/must-not-exist');
    final literal = '\$(touch "${marker.path}")';
    final result = await _adapterProbe(
      environment: {'WASD_PREVIEW1_RUNNER': executable.path},
      extraPython: '''
import subprocess
payload["executed"] = json.loads(subprocess.run(payload["wasm32-wasip1"], check=True, capture_output=True, text=True).stdout)
''',
      arguments: ['guest argument', '--guest-flag', literal],
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final payload = jsonDecode(result.stdout as String) as Map;
    final expected = [
      '--env',
      'key=value with spaces',
      '--dir',
      '/tmp/root with spaces::/',
      'fixture with spaces.wasm',
      'guest argument',
      '--guest-flag',
      literal,
    ];
    expect(payload['wasm32-wasip1'], [executable.path, ...expected]);
    expect(payload['executed'], expected);
    expect(marker.existsSync(), false);
    expect(payload['timeout'], 30.0);
    for (final (version, file) in [
      ('wasm32-wasip2', 'wasi_testsuite_preview2_component_runner.dart'),
      ('wasm32-wasip3', 'wasi_testsuite_preview3_component_runner.dart'),
    ]) {
      expect((payload[version] as List).take(3), [
        'dart',
        '--enable-asserts',
        File('tool/$file').absolute.path,
      ]);
    }
  });

  test(
    'Preview1 default command stays JIT and Preview3 opt-in stays scoped',
    () async {
      const p3 = '/tmp/Preview3 runner with spaces';
      final result = await _adapterProbe(
        environment: {'WASD_PREVIEW3_RUNNER': p3},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final payload = jsonDecode(result.stdout as String) as Map;
      expect(payload['wasm32-wasip1'], [
        'dart',
        '--enable-asserts',
        File('tool/wasi_testsuite_preview1_runner.dart').absolute.path,
        '--env',
        'key=value with spaces',
        '--dir',
        '/tmp/root with spaces::/',
        'fixture with spaces.wasm',
        'guest argument',
        '--guest-flag',
      ]);
      expect(payload['wasm32-wasip3'], [
        p3,
        '--world',
        'wasi:http/service',
        '--proposal',
        'http',
        '--env',
        'key=value with spaces',
        '--copy-dir',
        '/tmp/root with spaces::/',
        'fixture with spaces.wasm',
        'guest argument',
        '--guest-flag',
      ]);
    },
  );

  test('Preview1 basename selects the verified cwd file before PATH', () async {
    if (Platform.isWindows) {
      markTestSkipped('native gate targets Linux and macOS');
      return;
    }
    final temp = await Directory.systemTemp.createTemp('wasd-p1-aot-basename-');
    addTearDown(() => temp.delete(recursive: true));
    final cwd = Directory('${temp.path}/cwd')..createSync();
    final path = Directory('${temp.path}/path')..createSync();
    final cwdRunner = File('${cwd.path}/same-runner');
    final pathRunner = File('${path.path}/same-runner');
    for (final (file, identity) in [(cwdRunner, 'cwd'), (pathRunner, 'PATH')]) {
      await file.writeAsString('''#!/usr/bin/env python3
import json
print(json.dumps("$identity"))
''');
    }
    expect(
      (await Process.run('chmod', [
        '+x',
        cwdRunner.path,
        pathRunner.path,
      ])).exitCode,
      0,
    );
    final result = await _adapterProbe(
      environment: {'WASD_PREVIEW1_RUNNER': 'same-runner'},
      setupPython:
          '''
os.chdir(${jsonEncode(cwd.path)})
os.environ["PATH"] = ${jsonEncode(path.path)} + os.pathsep + os.environ.get("PATH", "")
''',
      extraPython: '''
import subprocess
payload["selected"] = json.loads(subprocess.run(payload["wasm32-wasip1"], check=True, capture_output=True, text=True).stdout)
''',
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final payload = jsonDecode(result.stdout as String) as Map;
    expect(payload['selected'], 'cwd');
    expect(
      (payload['wasm32-wasip1'] as List).first,
      cwdRunner.resolveSymbolicLinksSync(),
    );
  });

  test('Preview1 invalid opt-in paths fail without JIT fallback', () async {
    final temp = await Directory.systemTemp.createTemp('wasd-p1-aot-invalid-');
    addTearDown(() => temp.delete(recursive: true));
    final notExecutable = File('${temp.path}/not executable');
    await notExecutable.writeAsString('not executable');
    for (final path in [
      '',
      '${temp.path}/missing runner',
      temp.path,
      notExecutable.path,
      '${Platform.resolvedExecutable} --enable-asserts',
    ]) {
      final result = await _adapterProbe(
        environment: {'WASD_PREVIEW1_RUNNER': path},
      );
      expect(result.exitCode, isNot(0), reason: path);
      expect(result.stderr, contains('WASD_PREVIEW1_RUNNER'), reason: path);
    }
  });

  test('Preview1 gate records distinct JIT and native AOT identities', () {
    final jit = gate.preview1RunnerMetadata();
    expect(jit['profile'], 'jit');
    expect(jit.containsKey('executable'), false);
    final aot = gate.preview1RunnerMetadata(
      nativeRunner: Platform.resolvedExecutable,
    );
    expect(aot['profile'], 'native-aot');
    expect(aot['executable'], Platform.resolvedExecutable);
    expect(
      aot['executable_sha256'],
      sha256
          .convert(File(Platform.resolvedExecutable).readAsBytesSync())
          .toString(),
    );
    expect(aot['entrypoint_sha256'], jit['entrypoint_sha256']);
    expect(
      jit['entrypoint_sha256'],
      sha256
          .convert(
            File('tool/wasi_testsuite_preview1_runner.dart').readAsBytesSync(),
          )
          .toString(),
    );
  });

  test('Preview1 gate never classifies an invalid opt-in as JIT', () {
    for (final path in [
      '',
      '/missing/preview1-runner',
      Directory.current.path,
    ]) {
      expect(
        () => gate.preview1RunnerMetadata(nativeRunner: path),
        throwsStateError,
      );
    }
  });

  test('Preview1 testsuite runner executes WASI command modules', () async {
    final temp = await Directory.systemTemp.createTemp('wasd_wasi_runner_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final module = File('${temp.path}/read_preopen.wasm');
    await module.writeAsBytes(wasiReadPreopenFileModuleBytes());
    await File('${temp.path}/input.txt').writeAsString('wasd');

    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/wasi_testsuite_preview1_runner.dart',
      '--dir',
      '${temp.path}::/',
      module.path,
      'guest-arg',
    ]);

    expect(result.exitCode, 0);
    expect(result.stderr, isEmpty);
  });
}

Future<ProcessResult> _adapterProbe({
  Map<String, String> environment = const {},
  List<String> arguments = const ['guest argument', '--guest-flag'],
  String extraPython = '',
  String setupPython = '',
}) => Process.run('python3', [
  '-c',
  '''
import os,importlib.util,json
os.environ.pop("WASD_PREVIEW1_RUNNER", None)
os.environ.pop("WASD_PREVIEW3_RUNNER", None)
os.environ["DART"] = "dart --enable-asserts"
os.environ.update(${jsonEncode(environment)})
spec = importlib.util.spec_from_file_location("adapter", ${jsonEncode(File('tool/wasi_testsuite_wasd_adapter.py').absolute.path)})
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
$setupPython
payload = {
    version: adapter.compute_argv(
        "fixture with spaces.wasm", (${jsonEncode(arguments)}, {"key": "value with spaces"}, "/tmp/root with spaces"),
        ["http"] if version == "wasm32-wasip3" else [],
        "wasi:http/service" if version == "wasm32-wasip3" else "wasi:cli/command", version,
    ) for version in adapter.get_wasi_versions()
}
payload["timeout"] = adapter.get_timeout_seconds()
$extraPython
print(json.dumps(payload))
''',
]);
