import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/preview3/http.dart';
import 'package:wasd/src/wasi/preview3/native/http.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  test(
    'native Preview3 HTTP sends a body and streams a bounded response',
    () async {
      final received = Completer<List<int>>();
      final server = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        received.complete(
          await request.fold<List<int>>(<int>[], (all, chunk) {
            all.addAll(chunk);
            return all;
          }),
        );
        request.response.statusCode = 201;
        request.response.headers.set('x-runtime', 'preview3');
        request.response.add(
          List<int>.generate(96 * 1024, (index) => index & 0xff),
        );
        await request.response.close();
      });

      final host = WASIPreview3NativeHttpHost();
      final body = WASIComponentStream<int>('request-body');
      body.writable.writeAll(<int>[1, 2, 3, 4]);
      body.writable.close();
      final requestAndTransmission =
          host.imports['wasi:http/types@0.3.0.request.new']!(<Object?>[
                host.insertFields(WASIPreview3HttpFields()),
                _somePayload(body),
                _trailersFuture(),
                _none(),
              ])!
              as List<Object?>;
      final request = requestAndTransmission.first! as int;
      final transmission =
          requestAndTransmission[1]!
              as WASIComponentFuture<WasmComponentValueData>;
      _expectOk(
        host.imports['wasi:http/types@0.3.0.request.set-method']!(<Object?>[
          request,
          _variant('post', 2),
        ]),
      );
      _expectOk(
        host.imports['wasi:http/types@0.3.0.request.set-scheme']!(<Object?>[
          request,
          _some(_variant('HTTP', 0)),
        ]),
      );
      _expectOk(
        host.imports['wasi:http/types@0.3.0.request.set-authority']!(<Object?>[
          request,
          _some(_string('127.0.0.1:${server.port}')),
        ]),
      );
      _expectOk(
        host.imports['wasi:http/types@0.3.0.request.set-path-with-query']!(
          <Object?>[request, _some(_string('/upload?mode=test'))],
        ),
      );

      final sent = _result(
        await host.imports['wasi:http/client@0.3.0.send']!(<Object?>[request]),
      );
      expect(sent.isOk, isTrue);
      expect((await transmission.readable.readWhenReady()).isOk, isTrue);
      expect(await received.future, <int>[1, 2, 3, 4]);

      final response = host.takeResponse(_handle(sent.payload));
      expect(response.statusCode, 201);
      expect(
        response.headers.values('x-runtime').map(String.fromCharCodes),
        <String>['preview3'],
      );
      expect(response.contents!.maxBufferedElements, 64 * 1024);
      final responseBytes = await _drain(response.contents!);
      expect(responseBytes, hasLength(96 * 1024));
      expect(responseBytes.first, 0);
      expect(responseBytes.last, 255);
      final trailers = _result(
        await response.trailers.readable.readWhenReady(),
      );
      expect(trailers.isOk, isTrue);
      expect(_option(trailers.payload).isSome, isFalse);
    },
  );

  test(
    'native Preview3 HTTP rejects outgoing trailers without leaking fields',
    () async {
      final server = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        try {
          await request.drain<void>();
          await request.response.close();
        } on Object {
          // The client aborts before finishing an unsupported trailers request.
        }
      });

      final host = WASIPreview3NativeHttpHost();
      final trailerFields = host.insertFields(
        WASIPreview3HttpFields(
          entries: <WASIPreview3HttpFieldEntry>[
            const WASIPreview3HttpFieldEntry('x-trailer', <int>[49]),
          ],
        ),
      );
      final trailers = WASIComponentFuture<WasmComponentValueData>('trailers');
      trailers.writable.complete(_ok(_some(_integer(trailerFields))));
      final created =
          host.imports['wasi:http/types@0.3.0.request.new']!(<Object?>[
                host.insertFields(WASIPreview3HttpFields()),
                _none(),
                trailers,
                _none(),
              ])!
              as List<Object?>;
      final request = created.first! as int;
      _setTarget(host, request, server.port);

      final sent = _result(
        await host.imports['wasi:http/client@0.3.0.send']!(<Object?>[request]),
      );
      expect(sent.isOk, isFalse);
      expect(_variantData(sent.payload).label, 'HTTP-protocol-error');
      expect(host.table.activeCount, 0);
    },
  );

  test(
    'native Preview3 HTTP reports request close failures to transmission',
    () async {
      final server = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        try {
          await request.drain<void>();
          await request.response.close();
        } on Object {
          // The client closes the invalid content-length request.
        }
      });

      final host = WASIPreview3NativeHttpHost();
      final body = WASIComponentStream<int>('short-request-body');
      body.writable
        ..write(1)
        ..close();
      final created =
          host.imports['wasi:http/types@0.3.0.request.new']!(<Object?>[
                host.insertFields(
                  WASIPreview3HttpFields(
                    entries: const <WASIPreview3HttpFieldEntry>[
                      WASIPreview3HttpFieldEntry('content-length', <int>[50]),
                    ],
                  ),
                ),
                _somePayload(body),
                _trailersFuture(),
                _none(),
              ])!
              as List<Object?>;
      final request = created.first! as int;
      final transmission =
          created[1]! as WASIComponentFuture<WasmComponentValueData>;
      _setTarget(host, request, server.port);

      final sent = _result(
        await host.imports['wasi:http/client@0.3.0.send']!(<Object?>[request]),
      );
      final transmitted = _result(await transmission.readable.readWhenReady());

      expect(sent.isOk, isFalse);
      expect(transmitted.isOk, isFalse);
      expect(
        _variantData(transmitted.payload).label,
        _variantData(sent.payload).label,
      );
    },
  );

  test('native Preview3 HTTP treats request body writer drop as EOF', () async {
    final received = Completer<List<int>>();
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      received.complete(
        await request.fold<List<int>>(<int>[], (bytes, chunk) {
          bytes.addAll(chunk);
          return bytes;
        }),
      );
      request.response.statusCode = 204;
      await request.response.close();
    });

    final host = WASIPreview3NativeHttpHost();
    final body = WASIComponentStream<int>(
      'dropped-request-body',
      maxBufferedElements: 0,
    );
    final created =
        host.imports['wasi:http/types@0.3.0.request.new']!(<Object?>[
              host.insertFields(WASIPreview3HttpFields()),
              _somePayload(body),
              _trailersFuture(),
              _none(),
            ])!
            as List<Object?>;
    final request = created.first! as int;
    final transmission =
        created[1]! as WASIComponentFuture<WasmComponentValueData>;
    _setTarget(host, request, server.port);

    final pendingSend =
        host.imports['wasi:http/client@0.3.0.send']!(<Object?>[request])
            as Future<WasmComponentValueData>;
    await Future<void>.delayed(Duration.zero);
    body.writable.drop();
    final sent = _result(await pendingSend);

    expect(sent.isOk, isTrue);
    expect((await transmission.readable.readWhenReady()).isOk, isTrue);
    expect(await received.future, isEmpty);
  });

  test(
    'native Preview3 HTTP rejects malformed request body elements',
    () async {
      final server = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        try {
          await request.drain<void>();
          await request.response.close();
        } on Object {
          // The client aborts the malformed request body.
        }
      });

      final host = WASIPreview3NativeHttpHost();
      final body = WASIComponentStream<Object?>('malformed-request-body');
      body.writable
        ..write('not-a-byte')
        ..close();
      final created =
          host.imports['wasi:http/types@0.3.0.request.new']!(<Object?>[
                host.insertFields(WASIPreview3HttpFields()),
                _somePayload(body.readable),
                _trailersFuture(),
                _none(),
              ])!
              as List<Object?>;
      final request = created.first! as int;
      final transmission =
          created[1]! as WASIComponentFuture<WasmComponentValueData>;
      _setTarget(host, request, server.port);

      final sent = _result(
        await host.imports['wasi:http/client@0.3.0.send']!(<Object?>[request]),
      );

      expect(sent.isOk, isFalse);
      expect(_variantData(sent.payload).label, 'internal-error');
      expect((await transmission.readable.readWhenReady()).isOk, isFalse);
    },
  );

  test(
    'native Preview3 HTTP cancels transport when response body is dropped',
    () async {
      final cancelled = Completer<void>();
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled.complete(),
      );
      addTearDown(controller.close);
      final response = _TestHttpClientResponse(controller.stream);
      final host = WASIPreview3NativeHttpHost(
        client: _TestHttpClient(_TestHttpClientRequest(response)),
      );
      final request =
          WASIPreview3HttpRequest.noTrailers(headers: WASIPreview3HttpFields())
            ..scheme = const WASIPreview3HttpScheme.standard('HTTP')
            ..authority = 'example.com';
      final sent = _result(
        await host.imports['wasi:http/client@0.3.0.send']!(<Object?>[
          host.insertRequest(request),
        ]),
      );
      final wasiResponse = host.takeResponse(_handle(sent.payload));

      wasiResponse.contents!.readable.drop();

      await cancelled.future;
    },
  );

  test(
    'native Preview3 HTTP maps delayed response headers to response timeout',
    () async {
      final server = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        try {
          request.response.write('late');
          await request.response.close();
        } on Object {
          // Expected when the client timeout aborts the request.
        }
      });

      final host = WASIPreview3NativeHttpHost();
      final request =
          WASIPreview3HttpRequest.noTrailers(
              headers: WASIPreview3HttpFields(),
              options: WASIPreview3HttpRequestOptions(
                firstByteTimeout: BigInt.from(10 * 1000 * 1000),
              ),
            )
            ..scheme = const WASIPreview3HttpScheme.standard('HTTP')
            ..authority = '127.0.0.1:${server.port}';
      final sent = _result(
        await host.imports['wasi:http/client@0.3.0.send']!(<Object?>[
          host.insertRequest(request),
        ]),
      );
      expect(sent.isOk, isFalse);
      expect(_variantData(sent.payload).label, 'HTTP-response-timeout');
    },
  );

  test(
    'native Preview3 HTTP reports declared response trailers as unsupported',
    () async {
      final server = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.set(
          io.HttpHeaders.trailerHeader,
          'x-checksum',
        );
        request.response.write('ok');
        await request.response.close();
      });

      final host = WASIPreview3NativeHttpHost();
      final request =
          WASIPreview3HttpRequest.noTrailers(headers: WASIPreview3HttpFields())
            ..scheme = const WASIPreview3HttpScheme.standard('HTTP')
            ..authority = '127.0.0.1:${server.port}';
      final sent = _result(
        await host.imports['wasi:http/client@0.3.0.send']!(<Object?>[
          host.insertRequest(request),
        ]),
      );
      expect(sent.isOk, isTrue);
      final response = host.takeResponse(_handle(sent.payload));
      expect(String.fromCharCodes(await _drain(response.contents!)), 'ok');
      final trailers = _result(
        await response.trailers.readable.readWhenReady(),
      );
      expect(trailers.isOk, isFalse);
      expect(_variantData(trailers.payload).label, 'HTTP-protocol-error');
    },
  );

  test(
    'native Preview3 HTTP applies between-bytes timeout to body chunks',
    () async {
      final server = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.add(<int>[1]);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        try {
          request.response.add(<int>[2]);
          await request.response.close();
        } on Object {
          // Expected after the client cancels the timed-out response stream.
        }
      });

      final host = WASIPreview3NativeHttpHost();
      final request =
          WASIPreview3HttpRequest.noTrailers(
              headers: WASIPreview3HttpFields(),
              options: WASIPreview3HttpRequestOptions(
                firstByteTimeout: BigInt.from(1000 * 1000 * 1000),
                betweenBytesTimeout: BigInt.from(10 * 1000 * 1000),
              ),
            )
            ..scheme = const WASIPreview3HttpScheme.standard('HTTP')
            ..authority = '127.0.0.1:${server.port}';
      final sent = _result(
        await host.imports['wasi:http/client@0.3.0.send']!(<Object?>[
          host.insertRequest(request),
        ]),
      );
      expect(sent.isOk, isTrue);
      final response = host.takeResponse(_handle(sent.payload));
      expect(await _drain(response.contents!), <int>[1]);
      final trailers = _result(
        await response.trailers.readable.readWhenReady(),
      );
      expect(trailers.isOk, isFalse);
      expect(_variantData(trailers.payload).label, 'HTTP-response-timeout');
    },
  );
}

void _setTarget(WASIPreview3HttpHost host, int request, int port) {
  _expectOk(
    host.imports['wasi:http/types@0.3.0.request.set-scheme']!(<Object?>[
      request,
      _some(_variant('HTTP', 0)),
    ]),
  );
  _expectOk(
    host.imports['wasi:http/types@0.3.0.request.set-authority']!(<Object?>[
      request,
      _some(_string('127.0.0.1:$port')),
    ]),
  );
}

Future<List<int>> _drain(WASIComponentStream<int> stream) async {
  final bytes = <int>[];
  while (true) {
    final chunk = await stream.readable.readWhenAvailable(8192);
    if (chunk.isEmpty) {
      return bytes;
    }
    bytes.addAll(chunk);
  }
}

void _expectOk(Object? value) {
  expect(_result(value).isOk, isTrue);
}

WASIComponentFuture<WasmComponentValueData> _trailersFuture() {
  final future = WASIComponentFuture<WasmComponentValueData>('trailers');
  future.writable.complete(_ok(_none()));
  return future;
}

WasmComponentValueData _ok(WasmComponentValueData? payload) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: payload,
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

WasmComponentValueData _some(WasmComponentValueData payload) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: true,
    associatedValue: payload,
  );
}

WasmComponentValueData _somePayload(Object payload) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: true,
    associatedPayload: payload,
  );
}

WasmComponentValueData _variant(String label, int index) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: index,
    label: label,
  );
}

WasmComponentValueData _string(String value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.string,
    rawBytes: Uint8List(0),
    string: value,
  );
}

WasmComponentValueData _integer(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}

WasmComponentValueData _result(Object? value) {
  final data = value! as WasmComponentValueData;
  expect(data.kind, WasmComponentValueDataKind.result);
  return data;
}

WasmComponentValueData _option(Object? value) {
  final data = value! as WasmComponentValueData;
  expect(data.kind, WasmComponentValueDataKind.option);
  return data;
}

WasmComponentValueData _variantData(Object? value) {
  final data = value! as WasmComponentValueData;
  expect(data.kind, WasmComponentValueDataKind.variant);
  return data;
}

int _handle(Object? value) {
  final data = value! as WasmComponentValueData;
  return (data.integer! as num).toInt();
}

final class _TestHttpClient implements io.HttpClient {
  _TestHttpClient(this.request);

  final io.HttpClientRequest request;

  @override
  bool autoUncompress = true;

  @override
  String? userAgent = 'Dart/test';

  @override
  Future<io.HttpClientRequest> openUrl(String method, Uri url) async => request;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TestHttpClientRequest implements io.HttpClientRequest {
  _TestHttpClientRequest(this.response);

  final io.HttpClientResponse response;

  @override
  bool followRedirects = true;

  @override
  final io.HttpHeaders headers = _TestHttpHeaders();

  @override
  Future<io.HttpClientResponse> close() async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TestHttpHeaders implements io.HttpHeaders {
  @override
  List<String>? operator [](String name) => null;

  @override
  void forEach(void Function(String name, List<String> values) action) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TestHttpClientResponse extends Stream<List<int>>
    implements io.HttpClientResponse {
  _TestHttpClientResponse(this.stream);

  final Stream<List<int>> stream;

  @override
  final io.HttpHeaders headers = _TestHttpHeaders();

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
