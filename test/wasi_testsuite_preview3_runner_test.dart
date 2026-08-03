import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

import '../tool/wasi_testsuite_preview3_component_runner.dart'
    as component_runner;

void main() {
  test('wasd official adapter advertises Preview3 worlds and runner', () async {
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
    "version": adapter.get_version(),
    "versions": adapter.get_wasi_versions(),
    "worlds": adapter.get_wasi_worlds(),
    "p3": adapter.compute_argv(
        "p3.wasm",
        (["a", "b"], {"foo": "bar"}, "/tmp/root"),
        ["http"],
        "wasi:http/service",
        "wasm32-wasip3",
    ),
}
print(json.dumps(payload))
''',
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final payload =
        json.decode(result.stdout as String) as Map<String, Object?>;
    expect(payload['version'], 'local');
    final versions = (payload['versions'] as List<Object?>).cast<String>();
    final worlds = (payload['worlds'] as List<Object?>).cast<String>();
    final p3 = (payload['p3'] as List<Object?>).cast<String>();

    expect(
      versions,
      containsAll(<String>['wasm32-wasip1', 'wasm32-wasip2', 'wasm32-wasip3']),
    );
    expect(
      worlds,
      containsAll(<String>['wasi:cli/command', 'wasi:http/service']),
    );
    expect(
      p3,
      contains(endsWith('wasi_testsuite_preview3_component_runner.dart')),
    );
    expect(
      p3,
      containsAll(<String>[
        '--world',
        'wasi:http/service',
        '--proposal',
        'http',
        '--env',
        'foo=bar',
        '--copy-dir',
        '/tmp/root::/',
        'p3.wasm',
        'a',
        'b',
      ]),
    );
  });

  test('Preview3 runner isolates copied preopens and cleans them', () async {
    final temp = await Directory.systemTemp.createTemp(
      'wasd_wasip3_preopen_test_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final source = Directory('${temp.path}/source');
    await source.create();
    final sourceFile = File('${source.path}/source.txt');
    await sourceFile.writeAsString('source');
    final ignoredPollution = File('${source.path}/parent.cleanup');
    await ignoredPollution.writeAsString('pre-existing');
    final copiedPaths = <String>[];

    await component_runner.withPreparedPreview3Preopens(
      directPreopens: <String, String>{'/direct': source.path},
      copiedPreopens: <String, String>{
        '/copied-a': source.path,
        '/copied-b': source.path,
      },
      run: (preopens) async {
        expect(preopens['/direct'], source.path);
        copiedPaths.addAll(<String>[
          preopens['/copied-a']!,
          preopens['/copied-b']!,
        ]);
        expect(copiedPaths[0], isNot(source.path));
        expect(copiedPaths[1], isNot(source.path));
        expect(copiedPaths[0], isNot(copiedPaths[1]));
        expect(
          await File('${copiedPaths[0]}/source.txt').readAsString(),
          'source',
        );
        final copiedNames = await Directory(
          copiedPaths[0],
        ).list().map((entity) => _basename(entity.path)).toList();
        copiedNames.sort();
        expect(copiedNames, <String>['parent.cleanup', 'source.txt']);
        await File(
          '${copiedPaths[0]}/guest-created.txt',
        ).writeAsString('guest');
        expect(
          File('${copiedPaths[1]}/guest-created.txt').existsSync(),
          isFalse,
        );
        await File('${copiedPaths[0]}/source.txt').delete();
      },
    );

    expect(await sourceFile.readAsString(), 'source');
    expect(await ignoredPollution.readAsString(), 'pre-existing');
    expect(File('${source.path}/guest-created.txt').existsSync(), isFalse);
    expect(copiedPaths, hasLength(2));
    for (final copiedPath in copiedPaths) {
      expect(Directory(copiedPath).existsSync(), isFalse);
    }

    String? failedCopyPath;
    await expectLater(
      component_runner.withPreparedPreview3Preopens<void>(
        directPreopens: const <String, String>{},
        copiedPreopens: <String, String>{'/': source.path},
        run: (preopens) async {
          failedCopyPath = preopens['/'];
          throw StateError('fixture failed');
        },
      ),
      throwsStateError,
    );
    expect(failedCopyPath, isNotNull);
    expect(Directory(failedCopyPath!).existsSync(), isFalse);
  });

  test('Preview3 component runner pumps live stdin until EOF', () async {
    final source = StreamController<List<int>>();
    final input = WASIComponentStream<int>('runner-stdin-test');
    final subscription = component_runner.pumpPreview3Stdin(
      source.stream,
      input.writable,
    );
    addTearDown(subscription.cancel);

    final pending = input.readable.readWhenAvailable(64);
    source.add(const <int>[108, 105, 118, 101]);
    expect(await pending, const <int>[108, 105, 118, 101]);

    await source.close();
    expect(await input.readable.readWhenAvailable(64), isEmpty);
  });

  test(
    'Preview3 runner does not flush live compatibility output twice',
    () async {
      final liveStdout = <int>[];
      final host = WASIPreview3ComponentHost(stdout: liveStdout.addAll);
      final compatibility = host.preview2CompatibilityHost;
      await compatibility.componentHost.table.runScoped<void>(() async {
        final stdoutHandle =
            compatibility.standardImports['wasi:cli/stdout@0.2.0.get-stdout']!(
                  const <Object?>[],
                )
                as int;
        compatibility
            .standardImports['wasi:io/streams@0.2.0.output-stream.check-write']!(
          <Object?>[stdoutHandle],
        );
        compatibility
            .standardImports['wasi:io/streams@0.2.0.output-stream.write']!(
          <Object?>[
            stdoutHandle,
            _u8ListValue(const <int>[111, 107]),
          ],
        );
      });
      expect(liveStdout, const <int>[111, 107]);

      final temp = await Directory.systemTemp.createTemp(
        'wasd_wasip3_live_output_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final stdoutFile = File('${temp.path}/stdout');
      final stderrFile = File('${temp.path}/stderr');
      final stdoutSink = stdoutFile.openWrite();
      final stderrSink = stderrFile.openWrite();
      final emptyComponent = WasmComponent.decode(
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
        component_runner.runPreview3CommandWithBufferedOutput(
          host,
          emptyComponent,
          stdout: stdoutSink,
          stderr: stderrSink,
          flushCompatibilityOutput: false,
        ),
        throwsA(anything),
      );
      await Future.wait(<Future<void>>[stdoutSink.close(), stderrSink.close()]);

      expect(await stdoutFile.readAsBytes(), isEmpty);
      expect(await stderrFile.readAsBytes(), isEmpty);
      expect(liveStdout, const <int>[111, 107]);
    },
  );

  test('Preview3 service bridge preserves request and response data', () async {
    late WASIPreview3HttpRequest captured;
    final server = await component_runner.startPreview3HttpServiceServer((
      request,
    ) async {
      captured = request;
      final requestBody = <int>[];
      while (true) {
        final bytes = await request.contents!.readable.readWhenAvailable(64);
        if (bytes.isEmpty) {
          break;
        }
        requestBody.addAll(bytes);
      }
      final responseBody = WASIComponentStream<int>('runner-response');
      responseBody.writable.writeAll(requestBody);
      responseBody.writable.close();
      return WASIPreview3HttpResult<WASIPreview3HttpResponse>.ok(
        WASIPreview3HttpResponse.noTrailers(
          headers: WASIPreview3HttpFields(
            entries: const <WASIPreview3HttpFieldEntry>[
              WASIPreview3HttpFieldEntry('x-service', <int>[111, 107]),
            ],
          ),
          contents: responseBody,
        )..statusCode = 201,
      );
    });
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.port}/echo?mode=test'),
    );
    request.headers.set('x-echo', 'ping');
    request.add(const <int>[104, 101, 108, 108, 111]);
    final response = await request.close();
    final responseBody = await response.fold<List<int>>(<int>[], (
      bytes,
      chunk,
    ) {
      bytes.addAll(chunk);
      return bytes;
    });

    expect(response.statusCode, 201);
    expect(response.headers.value('x-service'), 'ok');
    expect(responseBody, const <int>[104, 101, 108, 108, 111]);
    expect(captured.method.wireName, 'POST');
    expect(captured.pathWithQuery, '/echo?mode=test');
    expect(captured.scheme!.wireName, 'http');
    expect(captured.authority, '127.0.0.1:${server.port}');
    expect(
      captured.headers.values('x-echo').map(String.fromCharCodes),
      <String>['ping'],
    );
  });

  test(
    'Preview3 testsuite runner requires every discovered fixture to pass',
    () async {
      final temp = await Directory.systemTemp.createTemp('wasd_wasip3_suite_');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final suite = Directory(
        '${temp.path}/tests/rust/testsuite/wasm32-wasip3',
      );
      await suite.create(recursive: true);
      await File(
        '${suite.path}/manifest.json',
      ).writeAsString('{"name":"fake Preview3","version":"wasm32-wasip3"}');
      await File('${suite.path}/fixture.wasm').writeAsBytes(const <int>[0]);

      final runnerPackage = Directory(
        '${temp.path}/test-runner/wasi_test_runner',
      );
      await runnerPackage.create(recursive: true);
      await File('${runnerPackage.path}/__init__.py').writeAsString('');
      await File('${runnerPackage.path}/__main__.py').writeAsString(r'''
import argparse
import json
import os

parser = argparse.ArgumentParser()
parser.add_argument('--test-suite', action='append')
parser.add_argument('--runtime-adapter')
parser.add_argument('--json-output-location')
parser.add_argument('--disable-colors', action='store_true')
args = parser.parse_args()
if os.path.exists(args.json_output_location):
    raise RuntimeError('stale official report was not removed')
with open(args.json_output_location, 'w', encoding='utf-8') as output:
    json.dump({
        'results': [{
            'name': 'fake Preview3',
            'tests': [{
                'name': 'fixture.wasm',
                'outcome': 'pass',
                'failures': [],
            }],
        }],
    }, output)
''');

      final jsonPath = '${temp.path}/report.json';
      final markdownPath = '${temp.path}/report.md';
      await File('$jsonPath.raw-official.json').writeAsString(
        '{"results":[{"tests":[{"name":"stale","outcome":"pass"}]}]}',
      );
      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview3_runner.dart',
        '--testsuite-dir',
        temp.path,
        '--runner-dir',
        '${temp.path}/test-runner',
        '--python',
        'python3',
        '--json',
        jsonPath,
        '--markdown',
        markdownPath,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final report =
          json.decode(await File(jsonPath).readAsString())
              as Map<String, Object?>;
      expect(report['suite'], 'official-wasi-testsuite-preview3');
      expect(report['status'], 'passed');
      expect(report['fixture_count'], 1);
      expect(report['totals'], <String, Object?>{
        'total': 1,
        'passed': 1,
        'failed': 0,
        'skipped': 0,
        'xfailed': 0,
        'xpassed': 0,
      });
      expect(await File(markdownPath).readAsString(), contains('100%'));
    },
  );
}

String _basename(String path) => path
    .split(Platform.pathSeparator)
    .where((segment) => segment.isNotEmpty)
    .last;

WasmComponentValueData _u8ListValue(List<int> bytes) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: <WasmComponentValueData>[
      for (final byte in bytes)
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: byte,
        ),
    ],
  );
}
