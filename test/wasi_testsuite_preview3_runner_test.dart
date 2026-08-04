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
    final python = await _pythonExecutable();
    if (python == null) {
      markTestSkipped('requires Python 3');
      return;
    }
    final adapterPath = File(
      'tool/wasi_testsuite_wasd_adapter.py',
    ).absolute.path;
    final result = await Process.run(python, <String>[
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
    expect(payload['version'], '0.5.0');
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

  test('Preview3 service does not wait for transmission observation', () async {
    final transmission = WASIComponentFuture<WasmComponentValueData>(
      'runner-unobserved-transmission',
    );
    final response = WASIPreview3HttpResponse(
      headers: WASIPreview3HttpFields(),
      trailers: _completedNoTrailers(),
      transmissionResult: transmission,
    );

    await component_runner
        .writePreview3HttpResponse(_CollectingHttpResponse(), response)
        .timeout(const Duration(milliseconds: 100));

    expect(transmission.readable.isReady, isTrue);
    expect(
      (await transmission.readable.readWhenReady()).associatedValue?.label,
      isNull,
    );
    transmission.readable.drop();
  });

  test(
    'Preview3 service reports response write failures to the guest',
    () async {
      final body = WASIComponentStream<int>('runner-failing-response');
      body.writable
        ..write(1)
        ..close();
      final transmission = WASIComponentFuture<WasmComponentValueData>(
        'runner-failing-transmission',
      );
      final response = WASIPreview3HttpResponse(
        headers: WASIPreview3HttpFields(),
        contents: body,
        trailers: WASIComponentFuture<WasmComponentValueData>(
          'unused-trailers',
        ),
        transmissionResult: transmission,
      );
      final transmissionError = _transmissionErrorLabel(transmission);

      await expectLater(
        component_runner.writePreview3HttpResponse(
          _FailingHttpResponse(),
          response,
        ),
        throwsStateError,
      );

      expect(await transmissionError, 'internal-error');
    },
  );

  test(
    'Preview3 service publishes failure before cancelling the response',
    () async {
      final body = WASIComponentStream<int>('runner-ordered-failure-body');
      body.writable
        ..write(1)
        ..close();
      final transmission = WASIComponentFuture<WasmComponentValueData>(
        'runner-ordered-failure-transmission',
      );
      final response = WASIPreview3HttpResponse(
        headers: WASIPreview3HttpFields(),
        contents: body,
        trailers: WASIComponentFuture<WasmComponentValueData>(
          'runner-ordered-failure-trailers',
        ),
        transmissionResult: transmission,
      );

      await expectLater(
        component_runner.writePreview3HttpResponse(
          _FailingHttpResponse(),
          response,
        ),
        throwsStateError,
      );

      expect(transmission.readable.isReady, isTrue);
      expect(body.readable.isCancelled, isFalse);
      expect(
        (await transmission.readable.readWhenReady()).associatedValue?.label,
        'internal-error',
      );
      await Future<void>.delayed(Duration.zero);
      expect(body.readable.isCancelled, isTrue);
      transmission.readable.drop();
    },
  );

  test('Preview3 service times out a stalled response body', () async {
    final transmission = WASIComponentFuture<WasmComponentValueData>(
      'runner-timeout-transmission',
    );
    final response = WASIPreview3HttpResponse(
      headers: WASIPreview3HttpFields(),
      contents: WASIComponentStream<int>('runner-stalled-response'),
      trailers: WASIComponentFuture<WasmComponentValueData>('unused-trailers'),
      transmissionResult: transmission,
    );
    final transmissionError = _transmissionErrorLabel(transmission);

    await expectLater(
      component_runner.writePreview3HttpResponse(
        _CollectingHttpResponse(),
        response,
        bodyReadTimeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );

    expect(await transmissionError, 'HTTP-response-timeout');
  });

  test('Preview3 service does not start an expired response read', () async {
    final discarded = <int>[];
    final body = WASIComponentStream<int>(
      'runner-expired-response',
      onDiscard: discarded.add,
    );
    body.writable.write(7);
    final response = WASIPreview3HttpResponse.noTrailers(
      headers: WASIPreview3HttpFields(),
      contents: body,
    );

    await expectLater(
      component_runner.writePreview3HttpResponse(
        _CollectingHttpResponse(),
        response,
        bodyReadTimeout: Duration.zero,
      ),
      throwsA(isA<TimeoutException>()),
    );

    await Future<void>.delayed(Duration.zero);
    expect(discarded, <int>[7]);
  });

  test('Preview3 service bounds a continuously streaming response', () async {
    final body = WASIComponentStream<int>('runner-endless-response');
    final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
      if (body.writable.isClosed) {
        return;
      }
      body.writable.write(1);
    });
    addTearDown(timer.cancel);
    final response = WASIPreview3HttpResponse(
      headers: WASIPreview3HttpFields(),
      contents: body,
      trailers: WASIComponentFuture<WasmComponentValueData>('unused-trailers'),
    );

    await expectLater(
      component_runner
          .writePreview3HttpResponse(
            _CollectingHttpResponse(),
            response,
            bodyReadTimeout: const Duration(milliseconds: 20),
          )
          .timeout(
            const Duration(milliseconds: 100),
            onTimeout: () => throw StateError(
              'response transmission did not enforce its total timeout',
            ),
          ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('Preview3 service bounds response output close', () async {
    final transmission = WASIComponentFuture<WasmComponentValueData>(
      'runner-close-timeout-transmission',
    );
    final response = WASIPreview3HttpResponse(
      headers: WASIPreview3HttpFields(),
      trailers: _completedNoTrailers(),
      transmissionResult: transmission,
    );
    final transmissionError = _transmissionErrorLabel(transmission);

    await expectLater(
      component_runner
          .writePreview3HttpResponse(
            _StallingCloseHttpResponse(),
            response,
            bodyReadTimeout: const Duration(milliseconds: 10),
          )
          .timeout(
            const Duration(milliseconds: 100),
            onTimeout: () => throw StateError(
              'response output close was not covered by the total timeout',
            ),
          ),
      throwsA(isA<TimeoutException>()),
    );
    expect(await transmissionError, 'HTTP-response-timeout');
  });

  test('Preview3 service waits for response trailers', () async {
    final transmission = WASIComponentFuture<WasmComponentValueData>(
      'runner-trailers-timeout-transmission',
    );
    final response = WASIPreview3HttpResponse(
      headers: WASIPreview3HttpFields(),
      trailers: WASIComponentFuture<WasmComponentValueData>(
        'runner-pending-trailers',
      ),
      transmissionResult: transmission,
    );
    final transmissionError = _transmissionErrorLabel(transmission);

    await expectLater(
      component_runner.writePreview3HttpResponse(
        _CollectingHttpResponse(),
        response,
        bodyReadTimeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(await transmissionError, 'HTTP-response-timeout');
  });

  test('Preview3 service rejects unsupported response trailers', () async {
    final transmission = WASIComponentFuture<WasmComponentValueData>(
      'runner-trailers-rejected-transmission',
    );
    final trailers = WASIComponentFuture<WasmComponentValueData>(
      'runner-present-trailers',
    );
    trailers.writable.complete(_ok(_some(_integerValue(1))));
    var trailersTaken = 0;
    final response = WASIPreview3HttpResponse(
      headers: WASIPreview3HttpFields(),
      trailers: trailers,
      transmissionResult: transmission,
      takeTrailers: (handle) {
        expect(handle, 1);
        trailersTaken++;
        return WASIPreview3HttpFields();
      },
    );
    final transmissionError = _transmissionErrorLabel(transmission);

    await expectLater(
      component_runner.writePreview3HttpResponse(
        _CollectingHttpResponse(),
        response,
      ),
      throwsStateError,
    );
    expect(await transmissionError, 'HTTP-protocol-error');
    expect(trailersTaken, 1);
    expect(trailers.writable.isDropped, isTrue);
  });

  test('Preview3 service shutdown accepts SIGTERM', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final signals = StreamController<ProcessSignal>();
    addTearDown(signals.close);

    final stopped = component_runner.servePreview3HttpUntilInterrupted(
      server,
      signalStreams: <Stream<ProcessSignal>>[signals.stream],
    );
    signals.add(ProcessSignal.sigterm);

    await stopped.timeout(const Duration(seconds: 1));
  });

  test('Preview3 service reports an unexpected listener shutdown', () async {
    final server = await component_runner.startPreview3HttpServiceServer((_) {
      throw StateError('request handler must not run');
    });
    final signals = StreamController<ProcessSignal>();
    addTearDown(signals.close);
    await server.close(force: true);

    await expectLater(
      component_runner
          .servePreview3HttpUntilInterrupted(
            server,
            signalStreams: <Stream<ProcessSignal>>[signals.stream],
          )
          .timeout(const Duration(seconds: 1)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Preview3 HTTP listener stopped unexpectedly.',
        ),
      ),
    );
  });

  test(
    'Preview3 testsuite runner requires every discovered fixture to pass',
    () async {
      final python = await _pythonExecutable();
      if (python == null) {
        markTestSkipped('requires Python 3');
        return;
      }
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

      final jsonPath = '${temp.path}/reports/report.json';
      final markdownPath = '${temp.path}/reports/report.md';
      await File(jsonPath).parent.create(recursive: true);
      await File('$jsonPath.raw-official.json').writeAsString(
        '{"results":[{"tests":[{"name":"stale","outcome":"pass"}]}]}',
      );
      await File(jsonPath).parent.delete(recursive: true);
      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview3_runner.dart',
        '--testsuite-dir',
        temp.path,
        '--runner-dir',
        '${temp.path}/test-runner',
        '--python',
        python,
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

  test(
    'Preview3 testsuite runner bounds pipes held after normal exit',
    () async {
      if (Platform.isWindows) {
        markTestSkipped('requires POSIX process groups');
        return;
      }
      final python = await _pythonExecutable();
      if (python == null) {
        markTestSkipped('requires Python 3');
        return;
      }
      final temp = await Directory.systemTemp.createTemp(
        'wasd_wasip3_runner_pipe_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      await _createPreview3Fixture(temp);
      final childPidPath = '${temp.path}/runtime-child.pid';
      await _writeOfficialRunner(temp, '''
import json
import subprocess
import sys

child = subprocess.Popen([
    sys.executable,
    '-c',
    ${json.encode(_pipeHoldingChildProgram)},
])
with open(${json.encode(childPidPath)}, 'w', encoding='utf-8') as output:
    output.write(str(child.pid))
with open(args.json_output_location, 'w', encoding='utf-8') as output:
    json.dump({
        'results': [{
            'tests': [{
                'name': 'fixture.wasm',
                'outcome': 'pass',
                'failures': [],
            }],
        }],
    }, output)
''');
      final jsonPath = '${temp.path}/reports/report.json';
      final markdownPath = '${temp.path}/reports/report.md';
      final stopwatch = Stopwatch()..start();

      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview3_runner.dart',
        '--testsuite-dir=${temp.path}',
        '--runner-dir=${temp.path}/test-runner',
        '--python=$python',
        '--runner-timeout-seconds=5',
        '--json=$jsonPath',
        '--markdown=$markdownPath',
      ]);
      stopwatch.stop();

      final childPid = int.parse(await File(childPidPath).readAsString());
      addTearDown(() async {
        if (await _processIsRunning(childPid)) {
          Process.killPid(childPid, ProcessSignal.sigkill);
        }
      });
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 6)));
      expect(await _waitForProcessStop(childPid), isTrue);
    },
  );

  test('Preview3 testsuite runner reports a missing official runner', () async {
    final temp = await Directory.systemTemp.createTemp(
      'wasd_wasip3_missing_runner_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    await _createPreview3Fixture(temp);
    final jsonPath = '${temp.path}/reports/report.json';
    final markdownPath = '${temp.path}/reports/report.md';

    final result = await Process.run(Platform.resolvedExecutable, <String>[
      'run',
      'tool/wasi_testsuite_preview3_runner.dart',
      '--testsuite-dir=${temp.path}',
      '--runner-dir=${temp.path}/missing-runner',
      '--json=$jsonPath',
      '--markdown=$markdownPath',
    ]);

    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    final report =
        json.decode(await File(jsonPath).readAsString())
            as Map<String, Object?>;
    expect(report['status'], 'failed');
    _expectSyntheticFailureTotals(report);
    expect(
      json.encode(report['failures']),
      contains('official wasi-testsuite runner not found'),
    );
  });

  test('Preview3 testsuite runner reports when git is unavailable', () async {
    final temp = await Directory.systemTemp.createTemp(
      'wasd_wasip3_missing_git_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final jsonPath = '${temp.path}/reports/report.json';
    final markdownPath = '${temp.path}/reports/report.md';

    final result = await Process.run(
      Platform.resolvedExecutable,
      <String>[
        'run',
        'tool/wasi_testsuite_preview3_runner.dart',
        '--testsuite-dir=${temp.path}',
        '--json=$jsonPath',
        '--markdown=$markdownPath',
      ],
      environment: const <String, String>{'PATH': '/no/such/bin'},
    );

    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    final report =
        json.decode(await File(jsonPath).readAsString())
            as Map<String, Object?>;
    expect(report['status'], 'missing-tests');
    expect(report['testsuite_head'], isNull);
  });

  test('Preview3 testsuite runner reports suite scan failures', () async {
    if (Platform.isWindows) {
      markTestSkipped('requires POSIX directory permissions');
      return;
    }
    final temp = await Directory.systemTemp.createTemp(
      'wasd_wasip3_scan_failure_',
    );
    final suiteRoot = Directory('${temp.path}/restricted');
    await suiteRoot.create();
    addTearDown(() async {
      await Process.run('/bin/chmod', <String>['700', suiteRoot.path]);
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final chmod = await Process.run('/bin/chmod', <String>[
      '000',
      suiteRoot.path,
    ]);
    expect(chmod.exitCode, 0);
    final jsonPath = '${temp.path}/reports/report.json';
    final markdownPath = '${temp.path}/reports/report.md';

    final result = await Process.run(Platform.resolvedExecutable, <String>[
      'run',
      'tool/wasi_testsuite_preview3_runner.dart',
      '--testsuite-dir=${suiteRoot.path}',
      '--json=$jsonPath',
      '--markdown=$markdownPath',
    ]);

    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    final report =
        json.decode(await File(jsonPath).readAsString())
            as Map<String, Object?>;
    expect(report['status'], 'failed');
    _expectSyntheticFailureTotals(report);
    expect(
      await File(markdownPath).readAsString(),
      contains('Permission denied'),
    );
  });

  test('Preview3 testsuite runner reports invalid official JSON', () async {
    final python = await _pythonExecutable();
    if (python == null) {
      markTestSkipped('requires Python 3');
      return;
    }
    final temp = await Directory.systemTemp.createTemp(
      'wasd_wasip3_invalid_json_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    await _createPreview3Fixture(temp);

    for (final (index, payload) in <String>['{', '[]', '{}'].indexed) {
      await _writeOfficialRunner(
        temp,
        'with open(args.json_output_location, "w", encoding="utf-8") as output:\n'
        '    output.write(${json.encode(payload)})\n',
      );
      final jsonPath = '${temp.path}/reports/report-$index.json';
      final markdownPath = '${temp.path}/reports/report-$index.md';
      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview3_runner.dart',
        '--testsuite-dir=${temp.path}',
        '--runner-dir=${temp.path}/test-runner',
        '--python=$python',
        '--json=$jsonPath',
        '--markdown=$markdownPath',
      ]);

      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      final report =
          json.decode(await File(jsonPath).readAsString())
              as Map<String, Object?>;
      expect(report['status'], 'failed');
      _expectSyntheticFailureTotals(report);
      expect(
        json.encode(report['failures']),
        contains('Official runner report is not valid JSON'),
      );
    }
  });

  test(
    'Preview3 testsuite runner times out and reports a hung runner',
    () async {
      final python = await _pythonExecutable();
      if (python == null) {
        markTestSkipped('requires Python 3');
        return;
      }
      final temp = await Directory.systemTemp.createTemp(
        'wasd_wasip3_runner_timeout_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      await _createPreview3Fixture(temp);
      final childPidPath = '${temp.path}/runtime-child.pid';
      final childReadyPath = '${temp.path}/runtime-child.ready';
      await _writeOfficialRunner(temp, '''
import subprocess
import sys
import time

child = subprocess.Popen([
    sys.executable,
    '-c',
    ${json.encode(_stubbornChildProgram(childReadyPath))},
])
with open(${json.encode(childPidPath)}, 'w', encoding='utf-8') as output:
    output.write(str(child.pid))
time.sleep(10)
''');
      final jsonPath = '${temp.path}/reports/report.json';
      final markdownPath = '${temp.path}/reports/report.md';
      final stopwatch = Stopwatch()..start();

      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wasi_testsuite_preview3_runner.dart',
        '--testsuite-dir=${temp.path}',
        '--runner-dir=${temp.path}/test-runner',
        '--python=$python',
        '--runner-timeout-seconds=1',
        '--json=$jsonPath',
        '--markdown=$markdownPath',
      ]);
      stopwatch.stop();

      final childPid = int.parse(await File(childPidPath).readAsString());
      addTearDown(() async {
        if (await _processIsRunning(childPid)) {
          Process.killPid(childPid, ProcessSignal.sigkill);
        }
      });
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 6)));
      final report =
          json.decode(await File(jsonPath).readAsString())
              as Map<String, Object?>;
      expect(report['status'], 'failed');
      _expectSyntheticFailureTotals(report);
      expect(json.encode(report['failures']), contains('timed out'));
      expect(await File(childReadyPath).readAsString(), 'ready');
      expect(await _waitForProcessStop(childPid), isTrue);
    },
  );
}

Future<String?> _pythonExecutable() async {
  for (final executable in const <String>['python3', 'python']) {
    try {
      final result = await Process.run(executable, const <String>[
        '-c',
        'import sys; raise SystemExit(0 if sys.version_info.major == 3 else 1)',
      ]);
      if (result.exitCode == 0) {
        return executable;
      }
    } on ProcessException {
      // Try the next common Python executable name.
    }
  }
  return null;
}

Future<void> _createPreview3Fixture(Directory root) async {
  final suite = Directory('${root.path}/tests/rust/testsuite/wasm32-wasip3');
  await suite.create(recursive: true);
  await File('${suite.path}/fixture.wasm').writeAsBytes(const <int>[0]);
}

Future<void> _writeOfficialRunner(Directory root, String body) async {
  final package = Directory('${root.path}/test-runner/wasi_test_runner');
  await package.create(recursive: true);
  final bytecode = Directory('${package.path}/__pycache__');
  if (await bytecode.exists()) {
    await bytecode.delete(recursive: true);
  }
  await File('${package.path}/__init__.py').writeAsString('');
  await File('${package.path}/__main__.py').writeAsString('''
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--test-suite', action='append')
parser.add_argument('--runtime-adapter')
parser.add_argument('--json-output-location')
parser.add_argument('--disable-colors', action='store_true')
args = parser.parse_args()
$body''');
}

Future<String?> _transmissionErrorLabel(
  WASIComponentFuture<WasmComponentValueData> transmission,
) async {
  final result = await transmission.readable.readWhenReady();
  return result.associatedValue?.label;
}

WASIComponentFuture<WasmComponentValueData> _completedNoTrailers() {
  final trailers = WASIComponentFuture<WasmComponentValueData>('no-trailers');
  trailers.writable.complete(_ok(_none()));
  return trailers;
}

WasmComponentValueData _ok(WasmComponentValueData value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: value,
  );
}

WasmComponentValueData _none() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
    isSome: false,
  );
}

WasmComponentValueData _some(WasmComponentValueData value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: true,
    associatedValue: value,
  );
}

WasmComponentValueData _integerValue(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}

void _expectSyntheticFailureTotals(Map<String, Object?> report) {
  expect(report['totals'], <String, Object?>{
    'total': 1,
    'passed': 0,
    'failed': 1,
    'skipped': 0,
    'xfailed': 0,
    'xpassed': 0,
  });
}

Future<bool> _waitForProcessStop(int pid) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (!await _processIsRunning(pid)) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return !await _processIsRunning(pid);
}

Future<bool> _processIsRunning(int pid) async {
  if (Platform.isWindows) {
    final result = await Process.run('tasklist', <String>[
      '/FI',
      'PID eq $pid',
      '/FO',
      'CSV',
      '/NH',
    ]);
    return result.exitCode == 0 && (result.stdout as String).contains('"$pid"');
  }
  final result = await Process.run('ps', <String>['-p', '$pid', '-o', 'stat=']);
  if (result.exitCode != 0) {
    return false;
  }
  final state = (result.stdout as String).trim();
  return state.isNotEmpty && !state.startsWith('Z');
}

const String _pipeHoldingChildProgram = '''
import time

time.sleep(10)
''';

String _stubbornChildProgram(String readyPath) =>
    '''
import signal
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(${json.encode(readyPath)}, 'w', encoding='utf-8') as output:
    output.write('ready')
time.sleep(10)
''';

final class _FailingHttpResponse implements HttpResponse {
  @override
  int statusCode = HttpStatus.ok;

  @override
  void add(List<int> data) {
    throw StateError('response write failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CollectingHttpResponse implements HttpResponse {
  @override
  int statusCode = HttpStatus.ok;

  @override
  void add(List<int> data) {}

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StallingCloseHttpResponse implements HttpResponse {
  @override
  int statusCode = HttpStatus.ok;

  @override
  void add(List<int> data) {}

  @override
  Future<void> close() => Completer<void>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
