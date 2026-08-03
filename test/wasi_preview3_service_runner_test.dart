import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

void main() {
  group('WASI Preview3 HTTP service runner', () {
    test('returns component errors and cleans each repeated request', () async {
      final component = await _compileComponentWat(
        'http_service_error',
        _serviceWat(returnsError: true),
      );
      var droppedRequests = 0;
      final host = WASIPreview3ComponentHost();
      final runner = WASIPreview3ServiceRunner(host);
      final baselineResources = host.componentHost.table.activeCount;

      for (var invocation = 0; invocation < 2; invocation++) {
        final result = await runner.handle(
          component,
          WASIPreview3HttpRequest.noTrailers(
            headers: WASIPreview3HttpFields(),
            onDrop: () => droppedRequests++,
          ),
        );

        expect(result.isOk, isFalse);
        expect(result.errorCode, 'internal-error');
        expect(host.componentHost.table.activeCount, baselineResources);
      }

      expect(droppedRequests, 2);
    });

    test('takes successful response ownership before scope cleanup', () async {
      final component = await _compileComponentWat(
        'http_service_response',
        _serviceWat(returnsError: false),
      );
      final componentHost = WASIComponentHost();
      final httpHost = _ResponseRequestHost(componentHost.table);
      final host = WASIPreview3ComponentHost(
        componentHost: componentHost,
        httpHost: httpHost,
      );
      final baselineResources = componentHost.table.activeCount;

      final result = await WASIPreview3ServiceRunner(host).handle(
        component,
        WASIPreview3HttpRequest.noTrailers(headers: WASIPreview3HttpFields()),
      );

      expect(result.isOk, isTrue);
      expect(result.errorCode, isNull);
      expect(result.value, same(httpHost.response));
      expect(result.value!.statusCode, 204);
      expect(componentHost.table.activeCount, baselineResources);
    });

    final testsuiteRoot = Platform.environment['WASD_WASI_TESTSUITE_DIR'];
    test(
      'executes the official http-service component and takes its response',
      () async {
        final fixture = File(
          '$testsuiteRoot/tests/rust/testsuite/wasm32-wasip3/'
          'http-service.wasm',
        );
        expect(fixture.existsSync(), isTrue, reason: fixture.path);
        final component = WasmComponent.decode(await fixture.readAsBytes());
        final host = WASIPreview3ComponentHost.native();
        final baselineResources = host.componentHost.table.activeCount;
        final request = WASIPreview3HttpRequest.noTrailers(
          headers: WASIPreview3HttpFields(),
        )..pathWithQuery = '/';

        final result = await WASIPreview3ServiceRunner(
          host,
        ).handle(component, request);

        expect(result.isOk, isTrue);
        expect(result.errorCode, isNull);
        final response = result.value!;
        expect(response.statusCode, 200);
        expect(
          response.headers.values('content-type').single,
          'text/plain'.codeUnits,
        );
        expect(await _readBody(response), 'hey\n'.codeUnits);
        expect(host.componentHost.table.activeCount, baselineResources);
      },
      skip: testsuiteRoot == null
          ? 'Set WASD_WASI_TESTSUITE_DIR to the official precompiled suite.'
          : false,
    );
  });
}

final class _ResponseRequestHost extends WASIPreview3HttpHost {
  _ResponseRequestHost(WASIComponentResourceTable table) : super(table: table);

  final response = WASIPreview3HttpResponse.noTrailers(
    headers: WASIPreview3HttpFields(),
  )..statusCode = 204;

  @override
  int insertRequest(WASIPreview3HttpRequest request) {
    return insertResponse(response);
  }
}

Future<List<int>> _readBody(WASIPreview3HttpResponse response) async {
  final body = response.contents;
  if (body == null) {
    return const <int>[];
  }
  final bytes = <int>[];
  while (true) {
    final chunk = await body.readable.readWhenAvailable(64 * 1024);
    bytes.addAll(chunk);
    if (chunk.isEmpty && body.writable.isClosed) {
      return bytes;
    }
  }
}

Future<WasmComponent> _compileComponentWat(String name, String source) async {
  final directory = await Directory.systemTemp.createTemp(
    'wasd_wasip3_service_',
  );
  addTearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
  final wat = File('${directory.path}/$name.wat');
  final wasm = File('${directory.path}/$name.wasm');
  await wat.writeAsString(source);
  final wasmTools = File(
    '.toolchains/bin/${Platform.isWindows ? 'wasm-tools.exe' : 'wasm-tools'}',
  );
  if (!wasmTools.existsSync()) {
    fail('Missing wasm-tools at ${wasmTools.path}.');
  }
  final parse = await Process.run(wasmTools.path, <String>[
    'parse',
    wat.path,
    '-o',
    wasm.path,
  ]);
  expect(parse.exitCode, 0, reason: '${parse.stdout}\n${parse.stderr}');
  return WasmComponent.decode(await wasm.readAsBytes());
}

String _serviceWat({required bool returnsError}) {
  return _serviceWatTemplate.replaceFirst(
    ';; TASK_RETURN',
    returnsError
        ? 'i32.const 1\n      i32.const 0'
        : 'i32.const 0\n      local.get 0',
  );
}

const String _serviceWatTemplate = r'''
(component
  (type $http-types (instance
    (export "request" (type (sub resource)))
    (export "response" (type (sub resource)))
    (type $error-code (variant (case "internal-error")))
    (export "error-code" (type (eq $error-code)))))
  (import "wasi:http/types@0.3.0"
    (instance $types (type $http-types)))
  (alias export $types "request" (type $request))
  (alias export $types "response" (type $response))
  (alias export $types "error-code" (type $error-code))
  (type $request-future (future u32))
  (core func $request-future-new (canon future.new $request-future))
  (type $handle-result
    (result (own $response) (error $error-code)))

  (core module $main
    (import "" "task.return" (func $task-return (param i32 i32)))
    (func (export "handle") (param i32) (result i32)
      ;; TASK_RETURN
      call $task-return
      i32.const 0)
    (func (export "callback") (param i32 i32 i32) (result i32)
      unreachable))

  (canon task.return (result $handle-result) (core func $task-return))
  (core instance $builtins
    (export "task.return" (func $task-return)))
  (core instance $main-instance
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main-instance "handle" (core func $handle-core))
  (alias core export $main-instance "callback" (core func $callback-core))

  (type $handle-type
    (func async
      (param "request" (own $request))
      (result $handle-result)))
  (func $handle (type $handle-type)
    (canon lift (core func $handle-core) async (callback $callback-core)))
  (instance $handler
    (export "request" (type $request))
    (export "response" (type $response))
    (export "error-code" (type $error-code))
    (export "handle" (func $handle)))
  (export "wasi:http/handler@0.3.0" (instance $handler)))
''';
