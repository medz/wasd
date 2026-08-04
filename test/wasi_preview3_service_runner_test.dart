import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

    test('turns guest exit into an internal HTTP error', () async {
      final component = await _compileComponentWat(
        'http_service_exit',
        _serviceWat(returnsError: false, exitCode: 7),
      );
      final host = WASIPreview3ComponentHost();
      final baselineResources = host.componentHost.table.activeCount;

      final result = await WASIPreview3ServiceRunner(host).handle(
        component,
        WASIPreview3HttpRequest.noTrailers(headers: WASIPreview3HttpFields()),
      );

      expect(result.isOk, isFalse);
      expect(result.errorCode, 'internal-error');
      expect(host.componentHost.table.activeCount, baselineResources);
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

    test('materializes owned response trailers before scope cleanup', () async {
      final component = await _compileComponentWat(
        'http_service_response_trailers',
        _serviceWat(returnsError: false),
      );
      final componentHost = WASIComponentHost();
      final httpHost = _TrailerResponseRequestHost(componentHost.table);
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
      expect(componentHost.table.activeCount, baselineResources);
      final trailers = await result.value!.readTrailers();
      expect(trailers.isOk, isTrue);
      expect(trailers.value!.values('x-scope'), <List<int>>[
        <int>[111, 107],
      ]);
      final transmissionRead = httpHost.transmission.readable.readWhenReady();
      result.value!.completeTransmission(
        const WASIPreview3HttpResult<void>.ok(null),
      );
      expect((await transmissionRead).isOk, isTrue);
      httpHost.transmission.readable.drop();
      await Future<void>.delayed(Duration.zero);
      expect(componentHost.table.activeCount, baselineResources);
    });

    test(
      'keeps pending response trailers scoped until transmission observation',
      () async {
        final component = await _compileComponentWat(
          'http_service_pending_trailers',
          _serviceWat(returnsError: false),
        );
        final componentHost = WASIComponentHost();
        final httpHost = _PendingTrailerResponseRequestHost(
          componentHost.table,
        );
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
        expect(httpHost.scopeDropCount, 0);
        httpHost.completeTrailers();
        final trailers = await result.value!.readTrailers();
        expect(trailers.isOk, isTrue);
        expect(trailers.value!.values('x-pending'), <List<int>>[
          <int>[111, 107],
        ]);

        result.value!.completeTransmission(
          const WASIPreview3HttpResult<void>.ok(null),
        );
        await Future<void>.delayed(Duration.zero);
        httpHost.probeScope();

        expect(
          (await httpHost.transmission.readable.readWhenReady()).isOk,
          isTrue,
        );
        httpHost.transmission.readable.drop();
        await Future<void>.delayed(Duration.zero);

        expect(httpHost.scopeDropCount, 1);
        expect(componentHost.table.activeCount, baselineResources);
        expect(httpHost.probeScope, throwsStateError);
      },
    );

    test(
      'releases a pending response scope after guest drop and cancel',
      () async {
        final component = await _compileComponentWat(
          'http_service_cancelled_response',
          _serviceWat(returnsError: false),
        );
        final componentHost = WASIComponentHost();
        final httpHost = _PendingTrailerResponseRequestHost(
          componentHost.table,
        );
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
        expect(httpHost.scopeDropCount, 0);
        httpHost.transmission.readable.drop();
        await result.value!.cancel();
        httpHost.cancelPendingTrailers();
        await Future<void>.delayed(Duration.zero);

        expect(httpHost.scopeDropCount, 1);
        expect(componentHost.table.activeCount, baselineResources);
        expect(httpHost.probeScope, throwsStateError);

        await result.value!.cancel();
        expect(httpHost.scopeDropCount, 1);
        expect(componentHost.table.activeCount, baselineResources);
      },
    );

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
        await response.completeTransmission(
          const WASIPreview3HttpResult<void>.ok(null),
        );
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

final class _TrailerResponseRequestHost extends WASIPreview3HttpHost {
  _TrailerResponseRequestHost(WASIComponentResourceTable table)
    : super(table: table);

  late final WASIComponentFuture<WasmComponentValueData> transmission;

  @override
  int insertRequest(WASIPreview3HttpRequest request) {
    request.cancel();
    final fields = insertFields(
      WASIPreview3HttpFields(
        entries: const <WASIPreview3HttpFieldEntry>[
          WASIPreview3HttpFieldEntry('x-scope', <int>[111, 107]),
        ],
      ),
    );
    final trailers = WASIComponentFuture<WasmComponentValueData>(
      'scoped-response-trailers',
    )..writable.complete(_okSomeHandle(fields));
    final created =
        imports['wasi:http/types@0.3.0.response.new']!(<Object?>[
              insertFields(WASIPreview3HttpFields()),
              _noneValue(),
              trailers,
            ])!
            as List<Object?>;
    transmission = created[1]! as WASIComponentFuture<WasmComponentValueData>;
    return created.first! as int;
  }
}

final class _PendingTrailerResponseRequestHost extends WASIPreview3HttpHost {
  _PendingTrailerResponseRequestHost(WASIComponentResourceTable table)
    : super(table: table);

  late final WASIComponentResourceType<_ScopeSentinel> _scopeSentinelType =
      table.defineType<_ScopeSentinel>(
        'pending-response-scope',
        onDrop: (_) => scopeDropCount++,
      );
  late final WASIComponentFuture<WasmComponentValueData> transmission;
  late final WASIComponentFuture<WasmComponentValueData> _trailers;
  late final void Function() completeTrailers;
  late final void Function() cancelPendingTrailers;
  late final void Function() probeScope;
  var scopeDropCount = 0;

  @override
  int insertRequest(WASIPreview3HttpRequest request) {
    request.cancel();
    table.insert<_ScopeSentinel>(_scopeSentinelType, const _ScopeSentinel());
    _trailers = WASIComponentFuture<WasmComponentValueData>(
      'pending-response-trailers',
    );
    completeTrailers = Zone.current.bindCallback(() {
      final fields = insertFields(
        WASIPreview3HttpFields(
          entries: const <WASIPreview3HttpFieldEntry>[
            WASIPreview3HttpFieldEntry('x-pending', <int>[111, 107]),
          ],
        ),
      );
      _trailers.writable.complete(_okSomeHandle(fields));
    });
    cancelPendingTrailers = Zone.current.bindCallback(() {
      if (_trailers.writable.canComplete) {
        _trailers.writable.cancel();
      }
    });
    probeScope = Zone.current.bindCallback(() {
      final handle = insertFields(WASIPreview3HttpFields());
      table.dropNamed('wasi:http/types@0.3.0.fields', handle);
    });
    final created =
        imports['wasi:http/types@0.3.0.response.new']!(<Object?>[
              insertFields(WASIPreview3HttpFields()),
              _noneValue(),
              _trailers,
            ])!
            as List<Object?>;
    transmission = created[1]! as WASIComponentFuture<WasmComponentValueData>;
    return created.first! as int;
  }
}

final class _ScopeSentinel {
  const _ScopeSentinel();
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

WasmComponentValueData _okSomeHandle(int handle) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.option,
      rawBytes: Uint8List(0),
      index: 1,
      label: 'some',
      isSome: true,
      associatedValue: WasmComponentValueData(
        kind: WasmComponentValueDataKind.integer,
        rawBytes: Uint8List(0),
        integer: handle,
      ),
    ),
  );
}

WasmComponentValueData _noneValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
    isSome: false,
  );
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

String _serviceWat({required bool returnsError, int? exitCode}) {
  final exitComponent = exitCode == null
      ? ''
      : r'''
  (type $exit-interface (instance
    (type $exit-with-code-type (func (param "status-code" u8)))
    (export "exit-with-code" (func (type $exit-with-code-type)))))
  (import "wasi:cli/exit@0.3.0"
    (instance $exit (type $exit-interface)))
  (alias export $exit "exit-with-code" (func $exit-with-code))
  (core func $exit-with-code-core
    (canon lower (func $exit-with-code)))
''';
  final exitImport = exitCode == null
      ? ''
      : r'''(import "" "exit-with-code" (func $exit-with-code (param i32)))''';
  final exitExport = exitCode == null
      ? ''
      : r'''(export "exit-with-code" (func $exit-with-code-core))''';
  final taskReturn = exitCode == null
      ? returnsError
            ? 'i32.const 1\n      i32.const 0'
            : 'i32.const 0\n      local.get 0'
      : 'i32.const $exitCode\n      call \$exit-with-code\n      unreachable';
  return _serviceWatTemplate
      .replaceFirst(';; EXIT_COMPONENT', exitComponent)
      .replaceFirst(';; EXIT_IMPORT', exitImport)
      .replaceFirst(';; EXIT_EXPORT', exitExport)
      .replaceFirst(';; TASK_RETURN', taskReturn);
}

const String _serviceWatTemplate = r'''
(component
  ;; EXIT_COMPONENT
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
    ;; EXIT_IMPORT
    (func (export "handle") (param i32) (result i32)
      ;; TASK_RETURN
      call $task-return
      i32.const 0)
    (func (export "callback") (param i32 i32 i32) (result i32)
      unreachable))

  (canon task.return (result $handle-result) (core func $task-return))
  (core instance $builtins
    (export "task.return" (func $task-return))
    ;; EXIT_EXPORT
  )
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
