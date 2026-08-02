@TestOn('vm')
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/preview2/native/http.dart' as native_http;
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

void main() {
  test(
    'Preview2 native HTTP aborts Content-Length protocol failures',
    () async {
      final nativeRequest = _RecordingHttpClientRequest();
      final host = native_http.WASIPreview2NativeHttpHost(
        client: _RecordingHttpClient(nativeRequest),
      );
      final request = _outgoingRequest(contentLength: '1');
      final body = request.takeBody()!;

      final handled = host.backend.handle(request, null);
      expect(handled.isOk, isTrue);
      expect(body.finish(null).errorCode, 'HTTP-protocol-error');
      await handled.value!.waitReady();

      expect(nativeRequest.abortCalls, 1);
      expect(nativeRequest.closeCalls, 0);
    },
  );

  test('Preview2 native HTTP aborts opened requests on exceptions', () async {
    final headerFailure = _RecordingHttpClientRequest(
      headerError: const io.HttpException('invalid header'),
    );
    final headerHost = native_http.WASIPreview2NativeHttpHost(
      client: _RecordingHttpClient(headerFailure),
    );
    final headerHandled = headerHost.backend.handle(
      _outgoingRequest(extraHeader: true),
      null,
    );
    expect(headerHandled.isOk, isTrue);
    await headerHandled.value!.waitReady();
    expect(headerFailure.abortCalls, 1);
    expect(headerFailure.closeCalls, 0);

    final closeFailure = _RecordingHttpClientRequest(
      closeError: StateError('close failed'),
    );
    final closeHost = native_http.WASIPreview2NativeHttpHost(
      client: _RecordingHttpClient(closeFailure),
    );
    final closeHandled = closeHost.backend.handle(_outgoingRequest(), null);
    expect(closeHandled.isOk, isTrue);
    await closeHandled.value!.waitReady();
    expect(closeFailure.closeCalls, 1);
    expect(closeFailure.abortCalls, 1);
  });

  test('Preview2 native HTTP aborts requests opened after timeout', () async {
    final pendingRequest = Completer<io.HttpClientRequest>();
    final nativeRequest = _RecordingHttpClientRequest();
    final host = native_http.WASIPreview2NativeHttpHost(
      client: _RecordingHttpClient(pendingRequest.future),
    );
    final options = WASIPreview2HttpRequestOptions()
      ..connectTimeout = BigInt.zero;

    final handled = host.backend.handle(_outgoingRequest(), options);
    expect(handled.isOk, isTrue);
    await handled.value!.waitReady();
    expect(nativeRequest.abortCalls, 0);

    pendingRequest.complete(nativeRequest);
    await Future<void>.delayed(Duration.zero);

    expect(nativeRequest.abortCalls, 1);
    expect(nativeRequest.closeCalls, 0);
  });

  test(
    'Preview2 native HTTP applies first-byte timeout to response headers',
    () async {
      final response = _RecordingHttpClientResponse(
        headers: _RecordingHttpHeaders(null),
      );
      final nativeRequest = _RecordingHttpClientRequest(
        closeResult: Future<io.HttpClientResponse>.delayed(
          const Duration(milliseconds: 120),
          () => response,
        ),
      );
      final (:program, host: _) = _httpFixture(nativeRequest);

      final future = _startHttpRequest(
        program,
        firstByteTimeout: const Duration(milliseconds: 40),
      );
      await _block(
        program,
        'wasi:http/types@0.2.0.future-incoming-response.subscribe',
        future,
      );
      final ready =
          program.invokeImport(
                'wasi:http/types@0.2.0.future-incoming-response.get',
                [future],
              )
              as WasmComponentValueData;

      expect(
        _resultErrorLabel(_resultOk(_optionPayload(ready))),
        'HTTP-response-timeout',
      );
      expect(nativeRequest.abortCalls, 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(response.listenCalls, 0);
    },
  );

  test('Preview2 native HTTP shares the first-byte timeout budget', () async {
    final responseBody = StreamController<List<int>>();
    addTearDown(responseBody.close);
    final response = _RecordingHttpClientResponse(
      headers: _RecordingHttpHeaders(null),
      stream: responseBody.stream,
    );
    final nativeRequest = _RecordingHttpClientRequest(
      closeResult: Future<io.HttpClientResponse>.delayed(
        const Duration(milliseconds: 120),
        () => response,
      ),
    );
    final (:program, host: _) = _httpFixture(nativeRequest);

    final future = _startHttpRequest(
      program,
      firstByteTimeout: const Duration(milliseconds: 200),
    );
    await _block(
      program,
      'wasi:http/types@0.2.0.future-incoming-response.subscribe',
      future,
    );
    final incomingResponse = _takeHttpResponse(program, future);
    final incomingBody = _consumeHttpResponse(program, incomingResponse);
    final input = _takeHttpInput(program, incomingBody);

    await Future<void>.delayed(const Duration(milliseconds: 120));
    responseBody.add(const <int>[65]);
    await responseBody.close();
    final pollable =
        program.invokeImport('wasi:io/streams@0.2.0.input-stream.subscribe', [
              input,
            ])
            as int;
    await program.invokeImportAsync('wasi:io/poll@0.2.0.pollable.block', [
      pollable,
    ]);
    final read =
        program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
              input,
              BigInt.one,
            ])
            as WasmComponentValueData;
    final error = _streamErrorHandle(read);

    expect(
      program.invokeImport('wasi:io/error@0.2.0.error.to-debug-string', [
        error,
      ]),
      'HTTP-response-timeout',
    );
    expect(response.cancelCalls, 1);
  });

  test(
    'Preview2 native HTTP accepts the first byte within the shared budget',
    () async {
      final responseBody = StreamController<List<int>>();
      addTearDown(responseBody.close);
      final response = _RecordingHttpClientResponse(
        headers: _RecordingHttpHeaders(null),
        stream: responseBody.stream,
      );
      final nativeRequest = _RecordingHttpClientRequest(
        closeResult: Future<io.HttpClientResponse>.delayed(
          const Duration(milliseconds: 40),
          () => response,
        ),
      );
      final (:host, :program) = _httpFixture(nativeRequest);

      final future = _startHttpRequest(
        program,
        firstByteTimeout: const Duration(milliseconds: 200),
      );
      await _block(
        program,
        'wasi:http/types@0.2.0.future-incoming-response.subscribe',
        future,
      );
      final incomingResponse = _takeHttpResponse(program, future);
      final incomingBody = _consumeHttpResponse(program, incomingResponse);
      final input = _takeHttpInput(program, incomingBody);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      responseBody.add(const <int>[65]);
      await responseBody.close();

      expect(await _readHttpInput(host, program, input), const <int>[65]);
      expect(await _readHttpInput(host, program, input), isNull);
      expect(response.cancelCalls, 0);
    },
  );

  test('Preview2 native HTTP cancels an unclaimed response future', () async {
    final responseBody = StreamController<List<int>>();
    addTearDown(responseBody.close);
    final response = _RecordingHttpClientResponse(
      headers: _RecordingHttpHeaders(null),
      stream: responseBody.stream,
    );
    final (:host, :program) = _httpFixture(
      _RecordingHttpClientRequest(response: response),
    );

    await host.componentHost.table.runScoped(() async {
      await _startReadyHttpRequest(program);
      expect(responseBody.hasListener, isTrue);
      expect(response.cancelCalls, 0);
    });

    expect(host.componentHost.table.activeCount, 0);
    expect(response.cancelCalls, 1);
  });

  test('Preview2 native HTTP aborts a request still opening', () async {
    final pendingRequest = Completer<io.HttpClientRequest>();
    final nativeRequest = _RecordingHttpClientRequest();
    final (:host, :program) = _httpFixture(pendingRequest.future);

    await host.componentHost.table.runScoped(() async {
      _startHttpRequest(program);
      await Future<void>.delayed(Duration.zero);
    });
    pendingRequest.complete(nativeRequest);
    await Future<void>.delayed(Duration.zero);

    expect(host.componentHost.table.activeCount, 0);
    expect(nativeRequest.abortCalls, 1);
    expect(nativeRequest.closeCalls, 0);
  });

  test(
    'Preview2 native HTTP transfers response cancellation ownership',
    () async {
      for (final finishBody in <bool>[false, true]) {
        final responseBody = StreamController<List<int>>();
        addTearDown(responseBody.close);
        final response = _RecordingHttpClientResponse(
          headers: _RecordingHttpHeaders(null),
          stream: responseBody.stream,
        );
        final (:host, :program) = _httpFixture(
          _RecordingHttpClientRequest(response: response),
        );

        await host.componentHost.table.runScoped(() async {
          final future = await _startReadyHttpRequest(program);
          final incomingResponse = _takeHttpResponse(program, future);
          _dropHttpResource(host, 'future-incoming-response', future);
          final incomingBody = _consumeHttpResponse(program, incomingResponse);
          _dropHttpResource(host, 'incoming-response', incomingResponse);
          final input = _takeHttpInput(program, incomingBody);
          expect(response.cancelCalls, 0);
          if (!finishBody) {
            return;
          }

          _dropHttpResource(host, 'input-stream', input, ioResource: true);
          final futureTrailers = _finishHttpBody(program, incomingBody);
          expect(response.cancelCalls, 0, reason: 'finish transfers ownership');
          _dropHttpResource(host, 'future-trailers', futureTrailers);
          expect(response.cancelCalls, 1);
        });

        expect(host.componentHost.table.activeCount, 0);
        expect(response.cancelCalls, 1);
      }
    },
  );

  test('Preview2 native HTTP leaves completed responses uncancelled', () async {
    final response = _RecordingHttpClientResponse(
      headers: _RecordingHttpHeaders(null),
      chunks: const <List<int>>[
        <int>[1, 2],
      ],
    );
    final (:host, :program) = _httpFixture(
      _RecordingHttpClientRequest(response: response),
    );

    await host.componentHost.table.runScoped(() async {
      final future = await _startReadyHttpRequest(program);
      final incomingResponse = _takeHttpResponse(program, future);
      final incomingBody = _consumeHttpResponse(program, incomingResponse);
      final input = _takeHttpInput(program, incomingBody);
      expect(await _readHttpInput(host, program, input), <int>[1, 2]);
      expect(await _readHttpInput(host, program, input), isNull);
      _dropHttpResource(host, 'input-stream', input, ioResource: true);
      final futureTrailers = _finishHttpBody(program, incomingBody);
      expect(_takeHttpTrailers(program, futureTrailers).isOk, isTrue);
      _dropHttpResource(host, 'future-trailers', futureTrailers);
    });

    expect(host.componentHost.table.activeCount, 0);
    expect(response.cancelCalls, 0);
  });

  test('Preview2 native HTTP aborts active abandoned requests', () async {
    final pendingResponse = Completer<io.HttpClientResponse>();
    final lateResponse = _RecordingHttpClientResponse(
      headers: _RecordingHttpHeaders(null),
    );
    final nativeRequest = _RecordingHttpClientRequest(
      closeResult: pendingResponse.future,
    );
    final (:host, :program) = _httpFixture(nativeRequest);

    await host.componentHost.table.runScoped(() async {
      _startHttpRequest(program);
      await Future<void>.delayed(Duration.zero);
      expect(nativeRequest.closeCalls, 1);
    });

    pendingResponse.complete(lateResponse);
    await Future<void>.delayed(Duration.zero);

    expect(host.componentHost.table.activeCount, 0);
    expect(nativeRequest.abortCalls, 1);
    expect(lateResponse.listenCalls, 0);
  });

  test('Preview2 native HTTP hides response stream error details', () async {
    const secret = '/private/host/path:8443';
    for (final (error, expected) in <(Object, String)>[
      (StateError(secret), 'internal-error'),
      (const io.HttpException(secret), 'HTTP-protocol-error'),
    ]) {
      final response = _RecordingHttpClientResponse(
        headers: _RecordingHttpHeaders(null),
        streamError: error,
      );
      final result = await _nativeGet(
        Uri.parse('http://example.test/'),
        _RecordingHttpClient(_RecordingHttpClientRequest(response: response)),
        captureBodyError: true,
      );

      expect(result.bodyError, expected);
      expect(result.bodyError, isNot(contains(secret)));
    }
  });

  test('Preview2 native HTTP rejects unsupported outgoing trailers', () async {
    const source = '''
package wasi-testsuite:test;

world http-trailers-test {
  import wasi:http/types@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
    final nativeRequest = _RecordingHttpClientRequest();
    final nativeHost = native_http.WASIPreview2NativeHttpHost(
      client: _RecordingHttpClient(nativeRequest),
    );
    final host = WASIPreview2ComponentHost(httpHost: nativeHost);
    final program = host.bindWitWorld(
      WASIComponentWitDocument.parse(source),
      worldName: 'http-trailers-test',
    );

    final headers =
        program.invokeImport(
              'wasi:http/types@0.2.0.fields.constructor',
              const [],
            )
            as int;
    final request =
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.constructor',
              [headers],
            )
            as int;
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-scheme',
            [request, _someValue(_variantValue('HTTP'))],
          )
          as WasmComponentValueData,
    );
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-authority',
            [request, _someValue(_stringValue('example.test'))],
          )
          as WasmComponentValueData,
    );
    final body = _handle(
      _resultOk(
        program.invokeImport('wasi:http/types@0.2.0.outgoing-request.body', [
              request,
            ])
            as WasmComponentValueData,
      ),
    );
    final future = _handle(
      _resultOk(
        program.invokeImport('wasi:http/outgoing-handler@0.2.0.handle', [
              request,
              _noneValue(),
            ])
            as WasmComponentValueData,
      ),
    );
    final trailers = _handle(
      _resultOk(
        program.invokeImport('wasi:http/types@0.2.0.fields.from-list', [
              _httpFieldListValue([
                ('x-checksum', [111, 107]),
              ]),
            ])
            as WasmComponentValueData,
      ),
    );

    expect(
      _resultErrorLabel(
        program.invokeImport('wasi:http/types@0.2.0.outgoing-body.finish', [
              body,
              _someValue(_integerValue(trailers)),
            ])
            as WasmComponentValueData,
      ),
      'HTTP-protocol-error',
    );
    await _block(
      program,
      'wasi:http/types@0.2.0.future-incoming-response.subscribe',
      future,
    );
    expect(nativeRequest.abortCalls, 1);
    expect(nativeRequest.closeCalls, 0);

    final prefinishedRequest = _outgoingRequest();
    final prefinishedBody = prefinishedRequest.takeBody()!;
    expect(
      prefinishedBody
          .finish(
            WASIPreview2HttpFields(
              entries: const <WASIPreview2HttpFieldEntry>[
                WASIPreview2HttpFieldEntry('x-checksum', <int>[111, 107]),
              ],
            ),
          )
          .isOk,
      isTrue,
    );
    final prefinishedHandled = nativeHost.backend.handle(
      prefinishedRequest,
      null,
    );
    expect(prefinishedHandled.isOk, isFalse);
    expect(prefinishedHandled.errorCode, 'HTTP-protocol-error');

    final directRequest = _outgoingRequest();
    final directBody = directRequest.takeBody()!;
    final handled = nativeHost.backend.handle(directRequest, null);
    expect(
      directBody
          .finish(
            WASIPreview2HttpFields(
              entries: const <WASIPreview2HttpFieldEntry>[
                WASIPreview2HttpFieldEntry('x-checksum', <int>[111, 107]),
              ],
            ),
          )
          .errorCode,
      'HTTP-protocol-error',
    );
    await handled.value!.waitReady();
    expect(nativeRequest.abortCalls, 2);
    expect(nativeRequest.closeCalls, 0);
  });

  test('Preview2 native HTTP preserves proxy response trailers', () {
    const source = '''
package wasi-testsuite:test;

world http-trailers-test {
  import wasi:http/types@0.2.0;
}
''';
    final host = WASIPreview2ComponentHost(
      httpHost: native_http.WASIPreview2NativeHttpHost(),
    );
    final program = host.bindWitWorld(
      WASIComponentWitDocument.parse(source),
      worldName: 'http-trailers-test',
    );
    final headers =
        program.invokeImport(
              'wasi:http/types@0.2.0.fields.constructor',
              const [],
            )
            as int;
    final response =
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-response.constructor',
              [headers],
            )
            as int;
    final body = _handle(
      _resultOk(
        program.invokeImport('wasi:http/types@0.2.0.outgoing-response.body', [
              response,
            ])
            as WasmComponentValueData,
      ),
    );
    final trailers = _handle(
      _resultOk(
        program.invokeImport('wasi:http/types@0.2.0.fields.from-list', [
              _httpFieldListValue([
                ('x-checksum', [111, 107]),
              ]),
            ])
            as WasmComponentValueData,
      ),
    );

    _expectUnitOk(
      program.invokeImport('wasi:http/types@0.2.0.outgoing-body.finish', [
            body,
            _someValue(_integerValue(trailers)),
          ])
          as WasmComponentValueData,
    );
    final outparam = WASIPreview2HttpResponseOutparam();
    final outparamHandle = host.httpHost.insertResponseOutparam(outparam);
    program.invokeImport('wasi:http/types@0.2.0.response-outparam.set', [
      outparamHandle,
      _resultOkValue(_integerValue(response)),
    ]);

    final returnedTrailers = outparam.response!.value!.bodyResource!.trailers!;
    expect(returnedTrailers.entries, hasLength(1));
    expect(returnedTrailers.entries.single.name, 'x-checksum');
    expect(returnedTrailers.entries.single.value, [111, 107]);
  });

  test(
    'Preview2 native HTTP host completes a loopback outgoing request',
    () async {
      final receivedBody = Completer<List<int>>();
      final server = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() async {
        await server.close(force: true);
      });
      server.listen((request) async {
        final body = <int>[];
        await for (final chunk in request) {
          body.addAll(chunk);
        }
        receivedBody.complete(body);
        request.response.statusCode = 202;
        request.response.headers.set('x-server', 'ok');
        request.response.add(const <int>[112, 111, 110, 103]);
        await request.response.close();
      });

      const source = '''
package wasi-testsuite:test;

world http-test {
  import wasi:http/types@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost(
        httpHost: WASIPreview2NativeHttpHost(),
      );
      final program = host.bindWitWorld(document, worldName: 'http-test');
      final headers = _handle(
        _resultOk(
          program.invokeImport('wasi:http/types@0.2.0.fields.from-list', [
                _httpFieldListValue([
                  ('x-client', [111, 107]),
                ]),
              ])
              as WasmComponentValueData,
        ),
      );
      final request =
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.constructor',
                [headers],
              )
              as int;

      _expectUnitOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.set-method',
              [request, _variantCaseValue('post', 2)],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.set-scheme',
              [request, _someValue(_variantValue('HTTP'))],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.set-authority',
              [request, _someValue(_stringValue('127.0.0.1:${server.port}'))],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.set-path-with-query',
              [request, _someValue(_stringValue('/native'))],
            )
            as WasmComponentValueData,
      );
      final outgoingBody = _handle(
        _resultOk(
          program.invokeImport('wasi:http/types@0.2.0.outgoing-request.body', [
                request,
              ])
              as WasmComponentValueData,
        ),
      );
      final output = _handle(
        _resultOk(
          program.invokeImport('wasi:http/types@0.2.0.outgoing-body.write', [
                outgoingBody,
              ])
              as WasmComponentValueData,
        ),
      );
      final future = _handle(
        _resultOk(
          program.invokeImport('wasi:http/outgoing-handler@0.2.0.handle', [
                request,
                _noneValue(),
              ])
              as WasmComponentValueData,
        ),
      );
      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        output,
      ]);
      _expectUnitOk(
        program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
              output,
              _u8ListValue([9, 8, 7]),
            ])
            as WasmComponentValueData,
      );
      host.componentHost.table.dropNamed(
        'wasi:io/streams@0.2.0.output-stream',
        output,
      );
      _expectUnitOk(
        program.invokeImport('wasi:http/types@0.2.0.outgoing-body.finish', [
              outgoingBody,
              _noneValue(),
            ])
            as WasmComponentValueData,
      );

      await _block(
        program,
        'wasi:http/types@0.2.0.future-incoming-response.subscribe',
        future,
      );
      final ready =
          program.invokeImport(
                'wasi:http/types@0.2.0.future-incoming-response.get',
                [future],
              )
              as WasmComponentValueData;
      final response = _handle(_resultOk(_resultOk(_optionPayload(ready))));
      final status =
          program.invokeImport(
                'wasi:http/types@0.2.0.incoming-response.status',
                [response],
              )
              as int;
      final incomingBody = _handle(
        _resultOk(
          program.invokeImport(
                'wasi:http/types@0.2.0.incoming-response.consume',
                [response],
              )
              as WasmComponentValueData,
        ),
      );
      final input = _handle(
        _resultOk(
          program.invokeImport('wasi:http/types@0.2.0.incoming-body.%stream', [
                incomingBody,
              ])
              as WasmComponentValueData,
        ),
      );
      await _block(
        program,
        'wasi:io/streams@0.2.0.input-stream.subscribe',
        input,
      );
      final responseBytes =
          program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                input,
                BigInt.from(16),
              ])
              as WasmComponentValueData;

      expect(status, 202);
      expect(_u8List(_resultOk(responseBytes)), [112, 111, 110, 103]);
      expect(await receivedBody.future, [9, 8, 7]);
      expect(host.httpHost.streamsHost, same(host.streamsHost));
    },
  );

  test('Preview2 native HTTP preserves compressed response bytes', () async {
    final original = <int>[112, 111, 110, 103];
    final compressed = io.gzip.encode(original);
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.set(
        io.HttpHeaders.contentEncodingHeader,
        'gzip',
      );
      request.response.contentLength = compressed.length;
      request.response.add(compressed);
      await request.response.close();
    });
    final client = io.HttpClient();
    addTearDown(() => client.close(force: true));

    final response = await _nativeGet(
      Uri.parse('http://127.0.0.1:${server.port}/gzip'),
      client,
    );

    expect(response.status, 200);
    expect(response.body, compressed);
    expect(response.contentEncoding, 'gzip');
    expect(response.contentLength, '${compressed.length}');
  });

  test('Preview2 native HTTP returns redirects without following', () async {
    var targetVisits = 0;
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/redirect') {
        request.response.statusCode = io.HttpStatus.found;
        request.response.headers.set(io.HttpHeaders.locationHeader, '/target');
      } else {
        targetVisits++;
        request.response.statusCode = io.HttpStatus.ok;
        request.response.write('followed');
      }
      await request.response.close();
    });
    final client = io.HttpClient();
    addTearDown(() => client.close(force: true));

    final response = await _nativeGet(
      Uri.parse('http://127.0.0.1:${server.port}/redirect'),
      client,
    );

    expect(response.status, io.HttpStatus.found);
    expect(targetVisits, 0);
  });

  test('Preview2 native HTTP does not inject a User-Agent', () async {
    String? userAgent;
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      userAgent = request.headers.value(io.HttpHeaders.userAgentHeader);
      await request.response.close();
    });
    final client = io.HttpClient();
    addTearDown(() => client.close(force: true));

    await _nativeGet(
      Uri.parse('http://127.0.0.1:${server.port}/headers'),
      client,
    );

    expect(userAgent, isNull);
  });

  test('Preview2 HTTP rejects invalid request target components', () {
    const source = '''
package wasi-testsuite:test;

world http-request-target-test {
  import wasi:http/types@0.2.0;
}
''';
    final program = WASIPreview2ComponentHost().bindWitWorld(
      WASIComponentWitDocument.parse(source),
      worldName: 'http-request-target-test',
    );
    final fields =
        program.invokeImport(
              'wasi:http/types@0.2.0.fields.constructor',
              const [],
            )
            as int;
    final request =
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.constructor',
              [fields],
            )
            as int;

    for (final path in <String>['bad path', '/path#fragment', '/bad%escape']) {
      final result =
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.set-path-with-query',
                [request, _someValue(_stringValue(path))],
              )
              as WasmComponentValueData;
      expect(result.isOk, isFalse, reason: path);
    }
    for (final authority in <String>[
      'bad host',
      'example.test?query',
      'example.test#fragment',
    ]) {
      final result =
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.set-authority',
                [request, _someValue(_stringValue(authority))],
              )
              as WasmComponentValueData;
      expect(result.isOk, isFalse, reason: authority);
    }
    expect(
      (program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.set-method',
                [request, _variantValue('other', _stringValue('bad method'))],
              )
              as WasmComponentValueData)
          .isOk,
      isFalse,
    );
    expect(
      (program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.set-scheme',
                [
                  request,
                  _someValue(_variantValue('other', _stringValue('1http'))),
                ],
              )
              as WasmComponentValueData)
          .isOk,
      isFalse,
    );
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-path-with-query',
            [request, _someValue(_stringValue('/a%20b?x=y/z?ok'))],
          )
          as WasmComponentValueData,
    );
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-authority',
            [request, _someValue(_stringValue('[::1]:8080'))],
          )
          as WasmComponentValueData,
    );
  });

  test('Preview2 native HTTP reports unavailable incoming trailers', () async {
    const source = '''
package wasi-testsuite:test;

world http-trailers-test {
  import wasi:http/types@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
    final response = _RecordingHttpClientResponse(
      headers: _RecordingHttpHeaders(null, const <String, List<String>>{
        io.HttpHeaders.trailerHeader: <String>['x-checksum'],
      }),
      chunks: const <List<int>>[
        <int>[112, 111, 110, 103],
      ],
    );
    final host = WASIPreview2ComponentHost(
      httpHost: native_http.WASIPreview2NativeHttpHost(
        client: _RecordingHttpClient(
          _RecordingHttpClientRequest(response: response),
        ),
      ),
    );
    final program = host.bindWitWorld(
      WASIComponentWitDocument.parse(source),
      worldName: 'http-trailers-test',
    );
    final headers =
        program.invokeImport(
              'wasi:http/types@0.2.0.fields.constructor',
              const [],
            )
            as int;
    final request =
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.constructor',
              [headers],
            )
            as int;
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-scheme',
            [request, _someValue(_variantValue('HTTP'))],
          )
          as WasmComponentValueData,
    );
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-authority',
            [request, _someValue(_stringValue('example.test'))],
          )
          as WasmComponentValueData,
    );
    final future = _handle(
      _resultOk(
        program.invokeImport('wasi:http/outgoing-handler@0.2.0.handle', [
              request,
              _noneValue(),
            ])
            as WasmComponentValueData,
      ),
    );

    await _block(
      program,
      'wasi:http/types@0.2.0.future-incoming-response.subscribe',
      future,
    );
    final ready =
        program.invokeImport(
              'wasi:http/types@0.2.0.future-incoming-response.get',
              [future],
            )
            as WasmComponentValueData;
    final incomingResponse = _handle(
      _resultOk(_resultOk(_optionPayload(ready))),
    );
    final incomingBody = _handle(
      _resultOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.incoming-response.consume',
              [incomingResponse],
            )
            as WasmComponentValueData,
      ),
    );
    final futureTrailers =
        program.invokeImport('wasi:http/types@0.2.0.incoming-body.finish', [
              incomingBody,
            ])
            as int;

    await _block(
      program,
      'wasi:http/types@0.2.0.future-trailers.subscribe',
      futureTrailers,
    );
    final trailers =
        program.invokeImport('wasi:http/types@0.2.0.future-trailers.get', [
              futureTrailers,
            ])
            as WasmComponentValueData;
    final bodyResult = _resultOk(_optionPayload(trailers));

    expect(_resultErrorLabel(bodyResult), 'HTTP-protocol-error');
  });

  test('Preview2 native HTTP host times out delayed response bodies', () async {
    final server = await io.ServerSocket.bind(
      io.InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() async {
      await server.close();
    });
    server.listen((socket) {
      socket.listen((_) {}, onError: (_) {});
      unawaited(
        (() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          socket.add(
            'HTTP/1.1 200 OK\r\n'
                    'Content-Length: 1\r\n'
                    'Connection: close\r\n'
                    '\r\n'
                .codeUnits,
          );
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 75));
          try {
            socket.add(const <int>[65]);
            await socket.flush();
            await socket.close();
          } on Object {
            socket.destroy();
          }
        })(),
      );
    });

    const source = '''
package wasi-testsuite:test;

world http-timeout-test {
  import wasi:http/types@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
  import wasi:io/error@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
    final document = WASIComponentWitDocument.parse(source);
    final host = WASIPreview2ComponentHost(
      httpHost: WASIPreview2NativeHttpHost(),
    );
    final program = host.bindWitWorld(document, worldName: 'http-timeout-test');
    final headers =
        program.invokeImport(
              'wasi:http/types@0.2.0.fields.constructor',
              const [],
            )
            as int;
    final request =
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.constructor',
              [headers],
            )
            as int;

    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-scheme',
            [request, _someValue(_variantValue('HTTP'))],
          )
          as WasmComponentValueData,
    );
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-authority',
            [request, _someValue(_stringValue('127.0.0.1:${server.port}'))],
          )
          as WasmComponentValueData,
    );
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-path-with-query',
            [request, _someValue(_stringValue('/timeout'))],
          )
          as WasmComponentValueData,
    );
    final options =
        program.invokeImport(
              'wasi:http/types@0.2.0.request-options.constructor',
              const [],
            )
            as int;
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.request-options.set-first-byte-timeout',
            [options, _someValue(_integerValue(BigInt.from(50000000)))],
          )
          as WasmComponentValueData,
    );
    final future = _handle(
      _resultOk(
        program.invokeImport('wasi:http/outgoing-handler@0.2.0.handle', [
              request,
              _someValue(_integerValue(options)),
            ])
            as WasmComponentValueData,
      ),
    );

    await _block(
      program,
      'wasi:http/types@0.2.0.future-incoming-response.subscribe',
      future,
    );
    final ready =
        program.invokeImport(
              'wasi:http/types@0.2.0.future-incoming-response.get',
              [future],
            )
            as WasmComponentValueData;
    final response = _handle(_resultOk(_resultOk(_optionPayload(ready))));
    final incomingBody = _handle(
      _resultOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.incoming-response.consume',
              [response],
            )
            as WasmComponentValueData,
      ),
    );
    final input = _handle(
      _resultOk(
        program.invokeImport('wasi:http/types@0.2.0.incoming-body.%stream', [
              incomingBody,
            ])
            as WasmComponentValueData,
      ),
    );
    await _block(
      program,
      'wasi:io/streams@0.2.0.input-stream.subscribe',
      input,
    );
    final read =
        program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
              input,
              BigInt.one,
            ])
            as WasmComponentValueData;
    final error = _streamErrorHandle(read);

    expect(
      program.invokeImport('wasi:io/error@0.2.0.error.to-debug-string', [
        error,
      ]),
      'HTTP-response-timeout',
    );
  });

  test('Preview2 native HTTP host rejects unsupported timeout ranges', () {
    const source = '''
package wasi-testsuite:test;

world http-timeout-range-test {
  import wasi:http/types@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
}
''';
    final program =
        WASIPreview2ComponentHost(
          httpHost: WASIPreview2NativeHttpHost(),
        ).bindWitWorld(
          WASIComponentWitDocument.parse(source),
          worldName: 'http-timeout-range-test',
        );
    final headers =
        program.invokeImport(
              'wasi:http/types@0.2.0.fields.constructor',
              const [],
            )
            as int;
    final request =
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.constructor',
              [headers],
            )
            as int;
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-scheme',
            [request, _someValue(_variantValue('HTTP'))],
          )
          as WasmComponentValueData,
    );
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.set-authority',
            [request, _someValue(_stringValue('example.test'))],
          )
          as WasmComponentValueData,
    );
    final options =
        program.invokeImport(
              'wasi:http/types@0.2.0.request-options.constructor',
              const [],
            )
            as int;
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.request-options.set-connect-timeout',
            [options, _someValue(_integerValue(BigInt.from(86400000000000)))],
          )
          as WasmComponentValueData,
    );
    final rejected =
        program.invokeImport(
              'wasi:http/types@0.2.0.request-options.set-connect-timeout',
              [options, _someValue(_integerValue(BigInt.from(86400000000001)))],
            )
            as WasmComponentValueData;
    final configured =
        program.invokeImport(
              'wasi:http/types@0.2.0.request-options.connect-timeout',
              [options],
            )
            as WasmComponentValueData;

    expect(rejected.isOk, isFalse);
    expect(_optionPayload(configured).integer, BigInt.from(86400000000000));
  });
}

Future<
  ({
    int status,
    List<int> body,
    String? bodyError,
    String? contentEncoding,
    String? contentLength,
  })
>
_nativeGet(
  Uri uri,
  io.HttpClient client, {
  bool captureBodyError = false,
}) async {
  const source = '''
package wasi-testsuite:test;

world http-get-test {
  import wasi:http/types@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
  import wasi:io/error@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
  final host = WASIPreview2ComponentHost(
    httpHost: native_http.WASIPreview2NativeHttpHost(client: client),
  );
  final program = host.bindWitWorld(
    WASIComponentWitDocument.parse(source),
    worldName: 'http-get-test',
  );
  final fields =
      program.invokeImport('wasi:http/types@0.2.0.fields.constructor', const [])
          as int;
  final request =
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.constructor',
            [fields],
          )
          as int;
  _expectUnitOk(
    program.invokeImport('wasi:http/types@0.2.0.outgoing-request.set-scheme', [
          request,
          _someValue(_variantValue('HTTP')),
        ])
        as WasmComponentValueData,
  );
  _expectUnitOk(
    program.invokeImport(
          'wasi:http/types@0.2.0.outgoing-request.set-authority',
          [request, _someValue(_stringValue(uri.authority))],
        )
        as WasmComponentValueData,
  );
  _expectUnitOk(
    program.invokeImport(
          'wasi:http/types@0.2.0.outgoing-request.set-path-with-query',
          [
            request,
            _someValue(
              _stringValue(
                uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
              ),
            ),
          ],
        )
        as WasmComponentValueData,
  );
  final future = _handle(
    _resultOk(
      program.invokeImport('wasi:http/outgoing-handler@0.2.0.handle', [
            request,
            _noneValue(),
          ])
          as WasmComponentValueData,
    ),
  );
  await _block(
    program,
    'wasi:http/types@0.2.0.future-incoming-response.subscribe',
    future,
  );
  final ready =
      program.invokeImport(
            'wasi:http/types@0.2.0.future-incoming-response.get',
            [future],
          )
          as WasmComponentValueData;
  final response = _handle(_resultOk(_resultOk(_optionPayload(ready))));
  final status =
      program.invokeImport('wasi:http/types@0.2.0.incoming-response.status', [
            response,
          ])
          as int;
  final responseFields =
      program.invokeImport('wasi:http/types@0.2.0.incoming-response.headers', [
            response,
          ])
          as int;

  String? firstHeader(String name) {
    final values =
        program.invokeImport('wasi:http/types@0.2.0.fields.get', [
              responseFields,
              name,
            ])
            as WasmComponentValueData;
    return values.items.isEmpty
        ? null
        : String.fromCharCodes(_u8List(values.items.first));
  }

  final incomingBody = _handle(
    _resultOk(
      program.invokeImport('wasi:http/types@0.2.0.incoming-response.consume', [
            response,
          ])
          as WasmComponentValueData,
    ),
  );
  final input = _handle(
    _resultOk(
      program.invokeImport('wasi:http/types@0.2.0.incoming-body.%stream', [
            incomingBody,
          ])
          as WasmComponentValueData,
    ),
  );
  final body = <int>[];
  String? bodyError;
  while (true) {
    await _block(
      program,
      'wasi:io/streams@0.2.0.input-stream.subscribe',
      input,
    );
    final read =
        program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
              input,
              BigInt.from(65536),
            ])
            as WasmComponentValueData;
    if (!(read.isOk ?? read.index == 0 || read.label == 'ok')) {
      final label = _resultErrorLabel(read);
      if (label == 'last-operation-failed') {
        final error = _streamErrorHandle(read);
        bodyError =
            program.invokeImport('wasi:io/error@0.2.0.error.to-debug-string', [
                  error,
                ])
                as String;
        if (!captureBodyError) {
          throw StateError('unexpected response body error: $bodyError');
        }
      } else if (label != 'closed') {
        throw StateError('unexpected response body error: $label');
      }
      break;
    }
    body.addAll(_u8List(_resultOk(read)));
  }
  return (
    status: status,
    body: body,
    bodyError: bodyError,
    contentEncoding: firstHeader(io.HttpHeaders.contentEncodingHeader),
    contentLength: firstHeader(io.HttpHeaders.contentLengthHeader),
  );
}

WASIPreview2HttpOutgoingRequest _outgoingRequest({
  String? contentLength,
  bool extraHeader = false,
}) {
  final request = WASIPreview2HttpOutgoingRequest(
    WASIPreview2HttpFields(
      entries: [
        if (contentLength != null)
          WASIPreview2HttpFieldEntry('content-length', contentLength.codeUnits),
        if (extraHeader)
          const WASIPreview2HttpFieldEntry('x-test', <int>[111, 107]),
      ],
    ),
  );
  request.scheme = const WASIPreview2HttpScheme.standard('http');
  request.authority = 'example.test';
  request.pathWithQuery = '/';
  return request;
}

WASIComponentWitAdapterProgram _httpAbandonProgram(
  WASIPreview2ComponentHost host,
) {
  const source = '''
package wasi-testsuite:test;

world http-abandon-test {
  import wasi:http/types@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
  import wasi:io/error@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
  return host.bindWitWorld(
    WASIComponentWitDocument.parse(source),
    worldName: 'http-abandon-test',
  );
}

({WASIPreview2ComponentHost host, WASIComponentWitAdapterProgram program})
_httpFixture(FutureOr<io.HttpClientRequest> request) {
  final host = WASIPreview2ComponentHost(
    httpHost: native_http.WASIPreview2NativeHttpHost(
      client: _RecordingHttpClient(request),
    ),
  );
  return (host: host, program: _httpAbandonProgram(host));
}

int _startHttpRequest(
  WASIComponentWitAdapterProgram program, {
  Duration? firstByteTimeout,
}) {
  final headers =
      program.invokeImport('wasi:http/types@0.2.0.fields.constructor', const [])
          as int;
  final request =
      program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-request.constructor',
            [headers],
          )
          as int;
  _expectUnitOk(
    program.invokeImport('wasi:http/types@0.2.0.outgoing-request.set-scheme', [
          request,
          _someValue(_variantValue('HTTP')),
        ])
        as WasmComponentValueData,
  );
  _expectUnitOk(
    program.invokeImport(
          'wasi:http/types@0.2.0.outgoing-request.set-authority',
          [request, _someValue(_stringValue('example.test'))],
        )
        as WasmComponentValueData,
  );
  int? options;
  if (firstByteTimeout != null) {
    options =
        program.invokeImport(
              'wasi:http/types@0.2.0.request-options.constructor',
              const [],
            )
            as int;
    _expectUnitOk(
      program.invokeImport(
            'wasi:http/types@0.2.0.request-options.set-first-byte-timeout',
            [
              options,
              _someValue(
                _integerValue(
                  BigInt.from(firstByteTimeout.inMicroseconds) *
                      BigInt.from(1000),
                ),
              ),
            ],
          )
          as WasmComponentValueData,
    );
  }
  return _handle(
    _resultOk(
      program.invokeImport('wasi:http/outgoing-handler@0.2.0.handle', [
            request,
            options == null ? _noneValue() : _someValue(_integerValue(options)),
          ])
          as WasmComponentValueData,
    ),
  );
}

Future<int> _startReadyHttpRequest(
  WASIComponentWitAdapterProgram program,
) async {
  final future = _startHttpRequest(program);
  await _block(
    program,
    'wasi:http/types@0.2.0.future-incoming-response.subscribe',
    future,
  );
  return future;
}

int _takeHttpResponse(WASIComponentWitAdapterProgram program, int future) {
  final ready =
      program.invokeImport(
            'wasi:http/types@0.2.0.future-incoming-response.get',
            [future],
          )
          as WasmComponentValueData;
  return _handle(_resultOk(_resultOk(_optionPayload(ready))));
}

int _consumeHttpResponse(WASIComponentWitAdapterProgram program, int response) {
  return _handle(
    _resultOk(
      program.invokeImport('wasi:http/types@0.2.0.incoming-response.consume', [
            response,
          ])
          as WasmComponentValueData,
    ),
  );
}

int _takeHttpInput(WASIComponentWitAdapterProgram program, int body) {
  return _handle(
    _resultOk(
      program.invokeImport('wasi:http/types@0.2.0.incoming-body.%stream', [
            body,
          ])
          as WasmComponentValueData,
    ),
  );
}

int _finishHttpBody(WASIComponentWitAdapterProgram program, int body) {
  return program.invokeImport('wasi:http/types@0.2.0.incoming-body.finish', [
        body,
      ])
      as int;
}

WasmComponentValueData _takeHttpTrailers(
  WASIComponentWitAdapterProgram program,
  int trailers,
) {
  final value =
      program.invokeImport('wasi:http/types@0.2.0.future-trailers.get', [
            trailers,
          ])
          as WasmComponentValueData;
  return _resultOk(_optionPayload(value));
}

void _dropHttpResource(
  WASIPreview2ComponentHost host,
  String resource,
  int handle, {
  bool ioResource = false,
}) {
  final interface = ioResource ? 'wasi:io/streams' : 'wasi:http/types';
  host.componentHost.table.dropNamed('$interface@0.2.0.$resource', handle);
}

Future<List<int>?> _readHttpInput(
  WASIPreview2ComponentHost host,
  WASIComponentWitAdapterProgram program,
  int input,
) async {
  final pollable =
      program.invokeImport('wasi:io/streams@0.2.0.input-stream.subscribe', [
            input,
          ])
          as int;
  await program.invokeImportAsync('wasi:io/poll@0.2.0.pollable.block', [
    pollable,
  ]);
  host.componentHost.table.dropNamed('wasi:io/poll@0.2.0.pollable', pollable);
  final read =
      program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
            input,
            BigInt.from(16),
          ])
          as WasmComponentValueData;
  if (read.isOk ?? read.index == 0 || read.label == 'ok') {
    return _u8List(_resultOk(read));
  }
  if (_resultErrorLabel(read) == 'closed') {
    return null;
  }
  throw StateError('unexpected input stream failure');
}

final class _RecordingHttpClient implements io.HttpClient {
  _RecordingHttpClient(FutureOr<io.HttpClientRequest> request)
    : _request = Future<io.HttpClientRequest>.value(request);

  final Future<io.HttpClientRequest> _request;

  @override
  bool autoUncompress = true;

  @override
  String? userAgent = 'Dart/test';

  @override
  Future<io.HttpClientRequest> openUrl(String method, Uri url) => _request;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecordingHttpClientRequest implements io.HttpClientRequest {
  _RecordingHttpClientRequest({
    this.headerError,
    this.closeError,
    this.response,
    this.closeResult,
  });

  final Object? headerError;
  final Object? closeError;
  final io.HttpClientResponse? response;
  final Future<io.HttpClientResponse>? closeResult;
  int abortCalls = 0;
  int closeCalls = 0;

  @override
  bool followRedirects = true;

  @override
  late final io.HttpHeaders headers = _RecordingHttpHeaders(headerError);

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    abortCalls++;
  }

  @override
  Future<io.HttpClientResponse> close() {
    closeCalls++;
    final closeResult = this.closeResult;
    if (closeResult != null) {
      return closeResult;
    }
    final response = this.response;
    if (response != null) {
      return Future<io.HttpClientResponse>.value(response);
    }
    return Future<io.HttpClientResponse>.error(
      closeError ?? StateError('unexpected close'),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecordingHttpHeaders implements io.HttpHeaders {
  _RecordingHttpHeaders(
    this.error, [
    Map<String, List<String>> values = const <String, List<String>>{},
  ]) : _values = <String, List<String>>{
         for (final entry in values.entries)
           entry.key.toLowerCase(): List<String>.of(entry.value),
       };

  final Object? error;
  final Map<String, List<String>> _values;

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    final error = this.error;
    if (error != null) {
      throw error;
    }
    _values.putIfAbsent(name.toLowerCase(), () => <String>[]).add('$value');
  }

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecordingHttpClientResponse extends Stream<List<int>>
    implements io.HttpClientResponse {
  _RecordingHttpClientResponse({
    required this.headers,
    List<List<int>> chunks = const <List<int>>[],
    Object? streamError,
    Stream<List<int>>? stream,
  }) : _stream =
           stream ??
           (streamError == null
               ? Stream<List<int>>.fromIterable(chunks)
               : Stream<List<int>>.error(streamError));

  final Stream<List<int>> _stream;
  int listenCalls = 0;
  int cancelCalls = 0;

  @override
  final io.HttpHeaders headers;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCalls++;
    return _RecordingStreamSubscription<List<int>>(
      _stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
      () {
        cancelCalls++;
      },
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecordingStreamSubscription<T> implements StreamSubscription<T> {
  _RecordingStreamSubscription(this._subscription, this._onCancel);

  final StreamSubscription<T> _subscription;
  final void Function() _onCancel;
  bool _cancelled = false;

  @override
  Future<void> cancel() {
    if (!_cancelled) {
      _cancelled = true;
      _onCancel();
    }
    return _subscription.cancel();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _block(
  WASIComponentWitAdapterProgram program,
  String subscribe,
  int handle,
) async {
  final pollable = program.invokeImport(subscribe, [handle]) as int;
  await program.invokeImportAsync('wasi:io/poll@0.2.0.pollable.block', [
    pollable,
  ]);
}

WasmComponentValueData _resultOk(WasmComponentValueData value) {
  final associated = value.associatedValue;
  if (value.kind != WasmComponentValueDataKind.result ||
      !(value.isOk ?? value.index == 0 || value.label == 'ok') ||
      associated == null) {
    throw StateError('expected ok result');
  }
  return associated;
}

WasmComponentValueData _optionPayload(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.option ||
      !(value.isSome ?? value.index == 1 || value.label == 'some') ||
      value.associatedValue == null) {
    throw StateError('expected some option payload');
  }
  return value.associatedValue!;
}

int _handle(WasmComponentValueData value) {
  final integer = value.integer;
  if (integer is int) {
    return integer;
  }
  if (integer is BigInt) {
    return integer.toInt();
  }
  throw StateError('expected resource handle');
}

void _expectUnitOk(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.result ||
      !(value.isOk ?? value.index == 0 || value.label == 'ok')) {
    throw StateError('expected ok result');
  }
}

String _resultErrorLabel(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.result ||
      (value.isOk ?? value.index == 0 || value.label == 'ok')) {
    throw StateError('expected error result');
  }
  final error = value.associatedValue;
  if (error == null || error.kind != WasmComponentValueDataKind.variant) {
    throw StateError('expected variant error payload');
  }
  return error.label ?? 'unknown';
}

List<int> _u8List(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    throw StateError('expected list<u8>');
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.integer)
        item.integer as int
      else
        throw StateError('expected u8 item'),
  ];
}

int _streamErrorHandle(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.result ||
      (value.isOk ?? value.index == 0 || value.label == 'ok')) {
    throw StateError('expected stream error');
  }
  final associated = value.associatedValue;
  if (associated == null ||
      associated.kind != WasmComponentValueDataKind.variant ||
      associated.associatedValue == null) {
    throw StateError('expected stream error payload');
  }
  return _handle(associated.associatedValue!);
}

WasmComponentValueData _httpFieldListValue(List<(String, List<int>)> entries) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      for (final entry in entries)
        _tupleValue([_stringValue(entry.$1), _u8ListValue(entry.$2)]),
    ],
  );
}

WasmComponentValueData _u8ListValue(List<int> bytes) {
  return WasmComponentValueData(
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
  );
}

WasmComponentValueData _stringValue(String value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.string,
    rawBytes: Uint8List(0),
    string: value,
  );
}

WasmComponentValueData _integerValue(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}

WasmComponentValueData _someValue(WasmComponentValueData value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    associatedValue: value,
  );
}

WasmComponentValueData _noneValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
  );
}

WasmComponentValueData _resultOkValue(WasmComponentValueData value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: value,
  );
}

WasmComponentValueData _variantValue(
  String label, [
  WasmComponentValueData? associatedValue,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    label: label,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _variantCaseValue(
  String label,
  int index, [
  WasmComponentValueData? associatedValue,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: index,
    label: label,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _tupleValue(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    items: items,
  );
}
