import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

import '../tool/wasi_testsuite_preview2_component_runner.dart'
    as component_runner_tool;

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
    'Preview2 runner flushes buffered output when execution fails',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_wasip2_failed_output_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final host = WASIPreview2ComponentHost.native();
      _writeCliOutput(host, 'stdout', [111, 117, 116]);
      _writeCliOutput(host, 'stderr', [101, 114, 114]);
      final stdoutFile = File('${temp.path}/stdout.txt');
      final stderrFile = File('${temp.path}/stderr.txt');
      final stdout = stdoutFile.openWrite();
      final stderr = stderrFile.openWrite();
      final component = WasmComponent.decode(
        Uint8List.fromList(const <int>[
          0x00,
          0x61,
          0x73,
          0x6d,
          0x0d,
          0x00,
          0x01,
          0x00,
        ]),
      );

      await expectLater(
        component_runner_tool.runPreview2CommandWithBufferedOutput(
          host,
          component,
          stdout: stdout,
          stderr: stderr,
        ),
        throwsA(isA<WASIPreview2ComponentExecutionException>()),
      );
      await Future.wait(<Future<void>>[stdout.close(), stderr.close()]);

      expect(await stdoutFile.readAsString(), 'out');
      expect(await stderrFile.readAsString(), 'err');
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
    'Preview2 component runner executes canonical resource builtins',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_wasip2_resource_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final component = await _compileComponentWat(
        temp,
        'resource_builtin',
        _resourceBuiltinCommandWat,
      );

      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview2_component_runner.dart',
        component.path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  test('Preview2 component runner stores indirect canonical results', () async {
    final temp = await Directory.systemTemp.createTemp(
      'wasd_wasip2_indirect_result_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final component = await _compileComponentWat(
      temp,
      'get_arguments',
      _getArgumentsCommandWat,
    );

    final result = await Process.run(Platform.resolvedExecutable, <String>[
      'run',
      'tool/wasi_testsuite_preview2_component_runner.dart',
      component.path,
      'a',
      'b',
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test(
    'Preview2 component runner materializes aliased resource types',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_wasip2_type_alias_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final component = await _compileComponentWat(
        temp,
        'type_alias',
        _typeAliasCommandWat,
      );

      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview2_component_runner.dart',
        component.path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  test('component type exports preserve abstract resource identity', () async {
    final temp = await Directory.systemTemp.createTemp(
      'wasd_component_resource_identity_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final fixture = await _compileComponentWat(
      temp,
      'resource_identity',
      _resourceTypeIdentityComponentWat,
    );
    final component = WasmComponent.decode(await fixture.readAsBytes());
    final resources = component.componentTypeIndexDefinitions.where(
      (definition) => definition.kind == WasmComponentTypeKind.resource,
    );

    expect(resources, hasLength(2));
    expect(identical(resources.first, resources.last), isTrue);
  });

  test(
    'Preview2 component runner executes a synchronous lifted start',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_wasip2_sync_start_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final component = await _compileComponentWat(
        temp,
        'synchronous_start',
        _synchronousStartCommandWat,
      );
      await _insertEmptyComponentStart(component, functionIndex: 0);

      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview2_component_runner.dart',
        component.path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  test(
    'Preview2 component runner synchronously composes lift and lower in start',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_wasip2_sync_lift_lower_start_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final component = await _compileComponentWat(
        temp,
        'synchronous_lift_lower_start',
        _synchronousLiftLowerStartCommandWat,
      );
      await _insertEmptyComponentStart(component, functionIndex: 1);

      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview2_component_runner.dart',
        component.path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  test('component start fixture rejects multi-byte function indexes', () async {
    await expectLater(
      _insertEmptyComponentStart(File('unused'), functionIndex: 0x80),
      throwsRangeError,
    );
  });

  test('Preview2 command drops imported stdout resources', () async {
    final temp = await Directory.systemTemp.createTemp(
      'wasd_wasip2_stdout_drop_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final fixture = await _compileComponentWat(
      temp,
      'stdout_drop',
      _stdoutDropCommandWat,
    );
    final component = WasmComponent.decode(await fixture.readAsBytes());
    final host = WASIPreview2ComponentHost.native();

    final result = await WASIPreview2CommandRunner(host).run(component);

    expect(result.exitCode, 0);
    expect(host.cliHost.stdoutBytes, isEmpty);
    final nextHandle =
        host.standardImports['wasi:cli/stdout@0.2.0.get-stdout']!(
              const <Object?>[],
            )
            as int;
    expect(host.componentHost.table.contains(nextHandle), isTrue);
  });

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
  final wasmTools = _wasmToolsPath();
  final result = await Process.run(wasmTools, <String>[
    'parse',
    wat.path,
    '-o',
    wasm.path,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  final validation = await Process.run(wasmTools, <String>[
    'validate',
    '--features',
    'component-model',
    wasm.path,
  ]);
  expect(
    validation.exitCode,
    0,
    reason: '${validation.stdout}\n${validation.stderr}',
  );
  return wasm;
}

void _writeCliOutput(
  WASIPreview2ComponentHost host,
  String stream,
  List<int> bytes,
) {
  final handle =
      host.standardImports['wasi:cli/$stream@0.2.0.get-$stream']!(const [])
          as int;
  host.standardImports['wasi:io/streams@0.2.0.output-stream.check-write']!([
    handle,
  ]);
  host.standardImports['wasi:io/streams@0.2.0.output-stream.write']!([
    handle,
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.list,
      rawBytes: Uint8List(0),
      items: [
        for (final byte in bytes)
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.integer,
            rawBytes: Uint8List(0),
            integer: byte,
          ),
      ],
    ),
  ]);
}

String _wasmToolsPath() {
  final executable = File(
    '.toolchains/bin/${Platform.isWindows ? 'wasm-tools.exe' : 'wasm-tools'}',
  );
  if (!executable.existsSync()) {
    fail(
      'Missing wasm-tools executable at ${executable.path}; '
      'run tool/ensure_toolchains.sh first.',
    );
  }
  return executable.path;
}

Future<void> _insertEmptyComponentStart(
  File componentFile, {
  required int functionIndex,
}) async {
  RangeError.checkValueInInterval(functionIndex, 0, 0x7f, 'functionIndex');
  final sourceBytes = await componentFile.readAsBytes();
  final component = WasmComponent.decode(sourceBytes);
  final bytes = sourceBytes.toList();
  final canonicalSection = component.sections.lastWhere(
    (section) => section.id == 8,
  );
  final insertionOffset =
      canonicalSection.payloadOffset + canonicalSection.payloadSize;
  bytes.insertAll(insertionOffset, <int>[9, 3, functionIndex, 0, 0]);
  await componentFile.writeAsBytes(bytes);
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

const String _resourceBuiltinCommandWat = r'''
(component
  (type $r (resource (rep i32)))
  (core func $new (canon resource.new $r))
  (core module $main
    (import "" "new" (func $new (param i32) (result i32)))
    (func (export "run") (result i32)
      i32.const 42
      call $new
      drop
      i32.const 0))
  (core instance $builtins
    (export "new" (func $new)))
  (core instance $main_i
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main_i "run" (core func $run_core))
  (type $run_ty (func (result (result))))
  (func $run (type $run_ty) (canon lift (core func $run_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.2.0" (instance $run_instance))
)
''';

const String _getArgumentsCommandWat = r'''
(component
  (core module $libc
    (memory (export "memory") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      i32.const 1024))
  (core instance $libc_i (instantiate $libc))
  (alias core export $libc_i "memory" (core memory $memory))
  (alias core export $libc_i "realloc" (core func $realloc))

  (type $args_ty (func (result (list string))))
  (type $env_ty (instance
    (export "get-arguments" (func (type $args_ty)))))
  (import "wasi:cli/environment@0.2.0"
    (instance $env (type $env_ty)))
  (alias export $env "get-arguments" (func $get_arguments))
  (core func $get_arguments_core
    (canon lower (func $get_arguments)
      (memory $memory)
      (realloc $realloc)))
  (core instance $env_core
    (export "get-arguments" (func $get_arguments_core)))

  (core module $main
    (import "env" "get-arguments" (func $get_arguments (param i32)))
    (func (export "run") (result i32)
      i32.const 0
      call $get_arguments
      i32.const 0))
  (core instance $main_i
    (instantiate $main (with "env" (instance $env_core))))
  (alias core export $main_i "run" (core func $run_core))
  (type $run_ty (func (result (result))))
  (func $run (type $run_ty) (canon lift (core func $run_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.2.0" (instance $run_instance))
)
''';

const String _typeAliasCommandWat = r'''
(component
  (type $streams_ty (instance
    (export "input-stream" (type (sub resource)))))
  (import "wasi:io/streams@0.2.0"
    (instance $streams (type $streams_ty)))
  (alias export $streams "input-stream" (type $input_stream))

  (core module $main
    (func (export "run") (result i32) i32.const 0))
  (core instance $main_i (instantiate $main))
  (alias core export $main_i "run" (core func $run_core))
  (type $run_ty (func (result (result))))
  (func $run (type $run_ty) (canon lift (core func $run_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.2.0" (instance $run_instance))
)
''';

const String _synchronousStartCommandWat = r'''
(component
  (core module $main
    (func (export "start"))
    (func (export "run") (result i32) i32.const 0))
  (core instance $main_i (instantiate $main))
  (alias core export $main_i "start" (core func $start_core))
  (alias core export $main_i "run" (core func $run_core))
  (type $start_ty (func))
  (func $start (type $start_ty) (canon lift (core func $start_core)))
  (type $run_ty (func (result (result))))
  (func $run (type $run_ty) (canon lift (core func $run_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.2.0" (instance $run_instance))
)
''';

const String _resourceTypeIdentityComponentWat = r'''
(component
  (type $interface (instance
    (export "resource" (type (sub resource)))
    (export "same-resource" (type (eq 0)))))
  (import "interface" (instance $interface_import (type $interface)))
  (alias export $interface_import "resource" (type $resource))
  (alias export $interface_import "same-resource" (type $same_resource))
)
''';

const String _synchronousLiftLowerStartCommandWat = r'''
(component
  (core module $inner_module
    (func (export "call")))
  (core instance $inner_i (instantiate $inner_module))
  (alias core export $inner_i "call" (core func $inner_core))
  (type $empty_ty (func))
  (func $inner (type $empty_ty) (canon lift (core func $inner_core)))
  (core func $inner_lowered (canon lower (func $inner)))
  (core instance $inner_adapter
    (export "inner" (func $inner_lowered)))

  (core module $main
    (import "" "inner" (func $inner))
    (func (export "start") call $inner)
    (func (export "run") (result i32) i32.const 0))
  (core instance $main_i
    (instantiate $main (with "" (instance $inner_adapter))))
  (alias core export $main_i "start" (core func $start_core))
  (alias core export $main_i "run" (core func $run_core))
  (func $start (type $empty_ty) (canon lift (core func $start_core)))
  (type $run_ty (func (result (result))))
  (func $run (type $run_ty) (canon lift (core func $run_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.2.0" (instance $run_instance))
)
''';

const String _stdoutDropCommandWat = r'''
(component
  (type $streams_ty (instance
    (export "output-stream" (type (sub resource)))))
  (import "wasi:io/streams@0.2.12"
    (instance $streams (type $streams_ty)))
  (alias export $streams "output-stream" (type $output_stream))

  (type $stdout_ty (instance
    (alias outer 1 $output_stream (type $outer_output_stream))
    (export "output-stream" (type (eq $outer_output_stream)))
    (type $owned_output_stream (own $outer_output_stream))
    (type $get_stdout_ty (func (result $owned_output_stream)))
    (export "get-stdout" (func (type $get_stdout_ty)))))
  (import "wasi:cli/stdout@0.2.12"
    (instance $stdout (type $stdout_ty)))
  (alias export $stdout "get-stdout" (func $get_stdout))
  (core func $get_stdout_core (canon lower (func $get_stdout)))
  (core func $drop_stdout (canon resource.drop $output_stream))
  (core instance $host
    (export "get-stdout" (func $get_stdout_core))
    (export "drop-stdout" (func $drop_stdout)))

  (core module $main
    (import "host" "get-stdout" (func $get_stdout (result i32)))
    (import "host" "drop-stdout" (func $drop_stdout (param i32)))
    (func (export "run") (result i32)
      call $get_stdout
      call $drop_stdout
      i32.const 0))
  (core instance $main_i
    (instantiate $main (with "host" (instance $host))))
  (alias core export $main_i "run" (core func $run_core))
  (type $run_ty (func (result (result))))
  (func $run (type $run_ty) (canon lift (core func $run_core)))
  (instance $run_instance (export "run" (func $run)))
  (export "wasi:cli/run@0.2.12" (instance $run_instance))
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
