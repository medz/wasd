import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/standard_wit.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasi/preview3/http.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('Preview3 HTTP fields', () {
    test('from-list rejects bytes outside HTTP field-content', () {
      final host = WASIPreview3HttpHost();
      final invalidBytes = <int>[
        ...List<int>.generate(9, (index) => index),
        ...List<int>.generate(22, (index) => index + 10),
        127,
      ];

      for (final byte in invalidBytes) {
        final created = _result(
          host.imports['wasi:http/types@0.3.0.fields.from-list']!(<Object?>[
            _fieldList(<(String, List<int>)>[
              ('x-test', <int>[byte]),
            ]),
          ]),
        );
        expect(created.isOk, isFalse, reason: 'byte $byte');
        expect(_variant(created.payload).label, 'invalid-syntax');
      }
    });

    test('preserve order and use case-insensitive lookup', () {
      final host = WASIPreview3HttpHost();
      final created = _result(
        host.imports['wasi:http/types@0.3.0.fields.from-list']!(<Object?>[
          _fieldList(<(String, List<int>)>[
            ('X-Test', <int>[49]),
            ('x-test', <int>[50]),
          ]),
        ]),
      );
      expect(created.isOk, isTrue);
      final handle = _handle(created.payload);

      final values = _list(
        host.imports['wasi:http/types@0.3.0.fields.get']!(<Object?>[
          handle,
          'X-TEST',
        ]),
      );
      expect(values.items.map(_bytes), <List<int>>[
        <int>[49],
        <int>[50],
      ]);

      final copied = _list(
        host.imports['wasi:http/types@0.3.0.fields.copy-all']!(<Object?>[
          handle,
        ]),
      );
      expect(
        copied.items.map((item) => _tuple(item).items.first.string),
        <String?>['X-Test', 'x-test'],
      );

      final appended = host.insertFields(WASIPreview3HttpFields());
      for (final (name, value) in <(String, List<int>)>[
        ('foo', <int>[49]),
        ('FOO', <int>[50]),
      ]) {
        expect(
          _result(
            host.imports['wasi:http/types@0.3.0.fields.append']!(<Object?>[
              appended,
              name,
              _listValue(<WasmComponentValueData>[
                for (final byte in value) _integer(byte),
              ]),
            ]),
          ).isOk,
          isTrue,
        );
      }
      final appendedCopy = _list(
        host.imports['wasi:http/types@0.3.0.fields.copy-all']!(<Object?>[
          appended,
        ]),
      );
      expect(
        appendedCopy.items.map((item) => _tuple(item).items.first.string),
        <String?>['foo', 'foo'],
      );
    });

    test(
      'get-and-delete returns old values and immutable children reject it',
      () {
        final host = WASIPreview3HttpHost();
        final fields = host.insertFields(
          WASIPreview3HttpFields(
            entries: <WASIPreview3HttpFieldEntry>[
              const WASIPreview3HttpFieldEntry('X-Test', <int>[49]),
            ],
          ),
        );
        final deleted = _result(
          host.imports['wasi:http/types@0.3.0.fields.get-and-delete']!(
            <Object?>[fields, 'x-test'],
          ),
        );
        expect(deleted.isOk, isTrue);
        expect(_list(deleted.payload).items.map(_bytes), <List<int>>[
          <int>[49],
        ]);

        final request = host.insertRequest(
          WASIPreview3HttpRequest.noTrailers(
            headers: WASIPreview3HttpFields(
              entries: <WASIPreview3HttpFieldEntry>[
                const WASIPreview3HttpFieldEntry('X-Locked', <int>[49]),
              ],
            ),
          ),
        );
        final child =
            host.imports['wasi:http/types@0.3.0.request.get-headers']!(
                  <Object?>[request],
                )!
                as int;
        final immutable = _result(
          host.imports['wasi:http/types@0.3.0.fields.get-and-delete']!(
            <Object?>[child, 'x-locked'],
          ),
        );
        expect(immutable.isOk, isFalse);
        expect(_variant(immutable.payload).label, 'immutable');
        expect(
          () => host.table.dropNamed('wasi:http/types@0.3.0.request', request),
          throwsStateError,
        );
        host.table.dropNamed('wasi:http/types@0.3.0.fields', child);
        host.table.dropNamed('wasi:http/types@0.3.0.request', request);
      },
    );
  });

  group('Preview3 HTTP request and response', () {
    test('new transfers resources and exposes immutable options', () {
      final host = WASIPreview3HttpHost(
        maximumRequestTimeoutNanos: BigInt.from(1000),
      );
      final fields = host.insertFields(WASIPreview3HttpFields());
      final options =
          host.imports['wasi:http/types@0.3.0.request-options.constructor']!(
                const <Object?>[],
              )!
              as int;
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.request-options.set-connect-timeout']!(
            <Object?>[options, _some(_integer(BigInt.from(999)))],
          ),
        ).isOk,
        isTrue,
      );
      final trailers = _trailersFuture();
      final created =
          host.imports['wasi:http/types@0.3.0.request.new']!(<Object?>[
                fields,
                _none(),
                trailers,
                _some(_integer(options)),
              ])!
              as List<Object?>;
      final request = created[0]! as int;
      expect(created[1], isA<WASIComponentFuture<WasmComponentValueData>>());
      expect(host.table.contains(fields), isFalse);
      expect(host.table.contains(options), isFalse);

      final optionsValue = _option(
        host.imports['wasi:http/types@0.3.0.request.get-options']!(<Object?>[
          request,
        ]),
      );
      expect(optionsValue.isSome, isTrue);
      final immutableOptions = _handle(optionsValue.payload);
      final immutableResult = _result(
        host.imports['wasi:http/types@0.3.0.request-options.set-connect-timeout']!(
          <Object?>[immutableOptions, _none()],
        ),
      );
      expect(immutableResult.isOk, isFalse);
      expect(_variant(immutableResult.payload).label, 'immutable');
      host.table.dropNamed(
        'wasi:http/types@0.3.0.request-options',
        immutableOptions,
      );
      host.table.dropNamed('wasi:http/types@0.3.0.request', request);
    });

    test('validates request target fields and moves body on consume', () async {
      final host = WASIPreview3HttpHost();
      final body = WASIComponentStream<int>('request-body');
      body.writable.writeAll(<int>[1, 2, 3]);
      body.writable.close();
      final fields = host.insertFields(WASIPreview3HttpFields());
      final created =
          host.imports['wasi:http/types@0.3.0.request.new']!(<Object?>[
                fields,
                _somePayload(body),
                _trailersFuture(),
                _none(),
              ])!
              as List<Object?>;
      final request = created.first! as int;
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.request.set-method']!(<Object?>[
            request,
            _variantValue('other', _string('GET')),
          ]),
        ).isOk,
        isTrue,
      );
      final method = _variant(
        host.imports['wasi:http/types@0.3.0.request.get-method']!(<Object?>[
          request,
        ]),
      );
      expect(method.label, 'get');
      expect(method.payload, isNull);
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.request.set-method']!(<Object?>[
            request,
            _variantValue('other', _string('BAD METHOD')),
          ]),
        ).isOk,
        isFalse,
      );
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.request.set-path-with-query']!(
            <Object?>[request, _some(_string('/ok?q=1'))],
          ),
        ).isOk,
        isTrue,
      );
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.request.set-path-with-query']!(
            <Object?>[request, _some(_string(''))],
          ),
        ).isOk,
        isTrue,
      );
      expect(
        (_option(
                  host.imports['wasi:http/types@0.3.0.request.get-path-with-query']!(
                    <Object?>[request],
                  ),
                ).payload
                as WasmComponentValueData)
            .string,
        '/',
      );
      for (final path in <String>['/%', '/\u0080']) {
        expect(
          _result(
            host.imports['wasi:http/types@0.3.0.request.set-path-with-query']!(
              <Object?>[request, _some(_string(path))],
            ),
          ).isOk,
          isTrue,
        );
        expect(
          (_option(
                    host.imports['wasi:http/types@0.3.0.request.get-path-with-query']!(
                      <Object?>[request],
                    ),
                  ).payload
                  as WasmComponentValueData)
              .string,
          path,
        );
      }
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.request.set-path-with-query']!(
            <Object?>[request, _some(_string('/#'))],
          ),
        ).isOk,
        isFalse,
      );
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.request.set-authority']!(
            <Object?>[request, _some(_string('example.test'))],
          ),
        ).isOk,
        isTrue,
      );
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.request.set-scheme']!(<Object?>[
            request,
            _some(
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.variant,
                rawBytes: Uint8List(0),
                index: 2,
                label: 'other',
                associatedValue: _string('https'),
              ),
            ),
          ]),
        ).isOk,
        isTrue,
      );
      final scheme = _variant(
        _option(
          host.imports['wasi:http/types@0.3.0.request.get-scheme']!(<Object?>[
            request,
          ]),
        ).payload,
      );
      expect(scheme.label, 'HTTPS');
      expect(scheme.payload, isNull);

      final handled = WASIComponentFuture<WasmComponentValueData>('handled');
      handled.writable.complete(_unitOk());
      final consumed =
          host.imports['wasi:http/types@0.3.0.request.consume-body']!(<Object?>[
                request,
                handled.readable,
              ])!
              as List<Object?>;
      expect(consumed[0], same(body));
      expect(await body.readable.readWhenAvailable(8), <int>[1, 2, 3]);
      expect(consumed[1], isA<WASIComponentFuture<WasmComponentValueData>>());
      expect(host.table.contains(request), isFalse);
    });

    test('moving a request detaches live header and options children', () {
      final host = WASIPreview3HttpHost();
      final options =
          host.imports['wasi:http/types@0.3.0.request-options.constructor']!(
                const <Object?>[],
              )!
              as int;
      final created =
          host.imports['wasi:http/types@0.3.0.request.new']!(<Object?>[
                host.insertFields(
                  WASIPreview3HttpFields(
                    entries: <WASIPreview3HttpFieldEntry>[
                      const WASIPreview3HttpFieldEntry('x-child', <int>[49]),
                    ],
                  ),
                ),
                _none(),
                _trailersFuture(),
                _some(_integer(options)),
              ])!
              as List<Object?>;
      final request = created.first! as int;
      final headers =
          host.imports['wasi:http/types@0.3.0.request.get-headers']!(<Object?>[
                request,
              ])!
              as int;
      final optionsChild = _handle(
        _option(
          host.imports['wasi:http/types@0.3.0.request.get-options']!(<Object?>[
            request,
          ]),
        ).payload,
      );
      final handled = WASIComponentFuture<WasmComponentValueData>('handled');
      handled.writable.complete(_unitOk());

      host.imports['wasi:http/types@0.3.0.request.consume-body']!(<Object?>[
        request,
        handled,
      ]);

      expect(host.table.contains(request), isFalse);
      expect(
        _list(
          host.imports['wasi:http/types@0.3.0.fields.get']!(<Object?>[
            headers,
            'X-CHILD',
          ]),
        ).items.map(_bytes),
        <List<int>>[
          <int>[49],
        ],
      );
      expect(
        _option(
          host.imports['wasi:http/types@0.3.0.request-options.get-connect-timeout']!(
            <Object?>[optionsChild],
          ),
        ).isSome,
        isFalse,
      );
      host.table.dropNamed('wasi:http/types@0.3.0.fields', headers);
      host.table.dropNamed(
        'wasi:http/types@0.3.0.request-options',
        optionsChild,
      );
      expect(host.table.activeCount, 0);
    });

    test('response status and body use the unified resource', () async {
      final host = WASIPreview3HttpHost();
      final body = WASIComponentStream<int>('response-body');
      body.writable.close();
      final created =
          host.imports['wasi:http/types@0.3.0.response.new']!(<Object?>[
                host.insertFields(WASIPreview3HttpFields()),
                _somePayload(body),
                _trailersFuture(),
              ])!
              as List<Object?>;
      final response = created.first! as int;
      expect(
        host.imports['wasi:http/types@0.3.0.response.get-status-code']!(
          <Object?>[response],
        ),
        200,
      );
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.response.set-status-code']!(
            <Object?>[response, 99],
          ),
        ).isOk,
        isFalse,
      );
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.response.set-status-code']!(
            <Object?>[response, 600],
          ),
        ).isOk,
        isFalse,
      );
      expect(
        _result(
          host.imports['wasi:http/types@0.3.0.response.set-status-code']!(
            <Object?>[response, 204],
          ),
        ).isOk,
        isTrue,
      );
      final handled = WASIComponentFuture<WasmComponentValueData>('handled');
      handled.writable.complete(_unitOk());
      final consumed =
          host.imports['wasi:http/types@0.3.0.response.consume-body']!(
                <Object?>[response, handled.readable],
              )!
              as List<Object?>;
      expect(consumed.first, same(body));
      expect(await body.readable.readWhenAvailable(1), isEmpty);
    });

    test('buffers guest readable response endpoints for transport', () async {
      final host = WASIPreview3HttpHost();
      final source = WASIComponentStream<int>(
        'guest-response-body',
        maxBufferedElements: 0,
      );
      final trailers = _trailersFuture();
      final created =
          host.imports['wasi:http/types@0.3.0.response.new']!(<Object?>[
                host.insertFields(WASIPreview3HttpFields()),
                _somePayload(source),
                trailers,
              ])!
              as List<Object?>;

      expect(
        await source.writable.writeWhenAvailable(const <int>[1, 2, 3, 4]),
        4,
      );
      source.writable.close();
      final response = host.takeResponse(created.first! as int);
      final bytes = <int>[];
      while (true) {
        final chunk = await response.contents!.readable.readWhenAvailable(16);
        if (chunk.isEmpty) {
          break;
        }
        bytes.addAll(chunk);
      }

      expect(bytes, const <int>[1, 2, 3, 4]);
      expect(
        _result(await response.trailers.readable.readWhenReady()).isOk,
        isTrue,
      );
    });
  });

  group('Preview3 HTTP dispatch', () {
    test('client and middleware handler use their distinct backends', () async {
      final client = _RecordingBackend(201);
      final handler = _RecordingBackend(202);
      final host = WASIPreview3HttpHost(
        clientBackend: client,
        handlerBackend: handler,
      );

      final clientRequest = _outgoingRequest('client.test');
      final clientHandle = host.insertRequest(clientRequest);
      final detachedHeaders =
          host.imports['wasi:http/types@0.3.0.request.get-headers']!(<Object?>[
                clientHandle,
              ])!
              as int;
      final clientResult = _result(
        await host.imports['wasi:http/client@0.3.0.send']!(<Object?>[
          clientHandle,
        ]),
      );
      expect(clientResult.isOk, isTrue);
      expect(host.takeResponse(_handle(clientResult.payload)).statusCode, 201);
      expect(client.request, same(clientRequest));
      expect(host.table.contains(detachedHeaders), isTrue);
      host.table.dropNamed('wasi:http/types@0.3.0.fields', detachedHeaders);

      final handlerRequest = _outgoingRequest('handler.test');
      final handlerResult = _result(
        await host.imports['wasi:http/handler@0.3.0.handle']!(<Object?>[
          host.insertRequest(handlerRequest),
        ]),
      );
      expect(handlerResult.isOk, isTrue);
      expect(host.takeResponse(_handle(handlerResult.payload)).statusCode, 202);
      expect(handler.request, same(handlerRequest));
      expect(host.table.activeCount, 0);
    });

    test(
      'unsupported client returns a structured configuration error',
      () async {
        final host = WASIPreview3HttpHost();
        final result = _result(
          await host.imports['wasi:http/client@0.3.0.send']!(<Object?>[
            host.insertRequest(_outgoingRequest('example.test')),
          ]),
        );
        expect(result.isOk, isFalse);
        expect(_variant(result.payload).label, 'configuration-error');
        expect(host.table.activeCount, 0);
      },
    );

    test('resource drop invokes transport cancellation exactly once', () {
      var drops = 0;
      final host = WASIPreview3HttpHost();
      final request = host.insertRequest(
        WASIPreview3HttpRequest.noTrailers(
          headers: WASIPreview3HttpFields(),
          onDrop: () => drops++,
        ),
      );
      host.table.dropNamed('wasi:http/types@0.3.0.request', request);
      expect(drops, 1);
      expect(host.table.activeCount, 0);
    });
  });

  test(
    'official adapters carry option<stream<u8>> through associatedPayload',
    () {
      const source = r'''
package local:http-test;

world test {
  import wasi:http/types@0.3.0;
}
''';
      final component = WASIPreview3ComponentHost();
      final http = WASIPreview3HttpHost(table: component.componentHost.table);
      final program = component.bindWitWorld(
        WASIComponentWitDocument.parse(source, sourceName: 'http-test.wit'),
        worldName: 'test',
        imports: http.imports,
      );
      final stream = WASIComponentStream<int>('nested-body');
      stream.writable.close();
      final created =
          program.invokeImport('wasi:http/types@0.3.0.request.new', <Object?>[
                http.insertFields(WASIPreview3HttpFields()),
                _somePayload(stream),
                _trailersFuture(),
                _none(),
              ])!
              as List<Object?>;

      expect(created.first, isA<int>());
      expect(created[1], isA<WASIComponentFuture<WasmComponentValueData>>());
      http.table.dropNamed(
        'wasi:http/types@0.3.0.request',
        created.first! as int,
      );
    },
  );

  test('official service and middleware worlds bind HTTP callbacks', () {
    final resolved = resolveWASIComponentStandardWitTarget(
      'wasi:http/middleware@0.3.0',
    )!;
    final component = WASIPreview3ComponentHost();
    final http = WASIPreview3HttpHost(table: component.componentHost.table);
    final program = component.bindWitWorld(
      resolved.document,
      worldName: 'middleware',
      imports: http.imports,
      exports: <String, FutureOr<Object?> Function(List<Object?>)>{
        'handler.handle': (_) =>
            throw StateError('not invoked by this binding test'),
      },
    );

    expect(
      program.operations
          .where(
            (operation) =>
                operation.qualifiedName == 'client.send' ||
                operation.qualifiedName == 'handler.handle',
          )
          .map((operation) => operation.qualifiedName),
      containsAll(<String>['client.send', 'handler.handle']),
    );
  });
}

final class _RecordingBackend implements WASIPreview3HttpBackend {
  _RecordingBackend(this.status);

  final int status;
  WASIPreview3HttpRequest? request;

  @override
  FutureOr<WASIPreview3HttpResult<WASIPreview3HttpResponse>> handle(
    WASIPreview3HttpRequest request,
  ) {
    this.request = request;
    request.completeTransmission(const WASIPreview3HttpResult<void>.ok(null));
    final response = WASIPreview3HttpResponse.noTrailers(
      headers: WASIPreview3HttpFields(),
    )..statusCode = status;
    return WASIPreview3HttpResult<WASIPreview3HttpResponse>.ok(response);
  }
}

WASIPreview3HttpRequest _outgoingRequest(String authority) {
  return WASIPreview3HttpRequest.noTrailers(headers: WASIPreview3HttpFields())
    ..authority = authority;
}

WASIComponentFuture<WasmComponentValueData> _trailersFuture() {
  final future = WASIComponentFuture<WasmComponentValueData>('trailers');
  future.writable.complete(_ok(_none()));
  return future;
}

WasmComponentValueData _fieldList(List<(String, List<int>)> entries) {
  return _listValue(<WasmComponentValueData>[
    for (final (name, value) in entries)
      _tupleValue(<WasmComponentValueData>[
        _string(name),
        _listValue(<WasmComponentValueData>[
          for (final byte in value) _integer(byte),
        ]),
      ]),
  ]);
}

WasmComponentValueData _unitOk() => _ok(null);

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

WasmComponentValueData _variantValue(
  String label, [
  WasmComponentValueData? payload,
]) {
  const labels = <String>[
    'get',
    'head',
    'post',
    'put',
    'delete',
    'connect',
    'options',
    'trace',
    'patch',
    'other',
  ];
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: labels.indexOf(label),
    label: label,
    associatedValue: payload,
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

WasmComponentValueData _listValue(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _tupleValue(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    items: items,
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

WasmComponentValueData _variant(Object? value) {
  final data = value! as WasmComponentValueData;
  expect(data.kind, WasmComponentValueDataKind.variant);
  return data;
}

WasmComponentValueData _list(Object? value) {
  final data = value! as WasmComponentValueData;
  expect(data.kind, WasmComponentValueDataKind.list);
  return data;
}

WasmComponentValueData _tuple(Object? value) {
  final data = value! as WasmComponentValueData;
  expect(data.kind, WasmComponentValueDataKind.tuple);
  return data;
}

int _handle(Object? value) {
  final data = value! as WasmComponentValueData;
  return (data.integer! as num).toInt();
}

List<int> _bytes(WasmComponentValueData value) {
  return <int>[for (final item in value.items) (item.integer! as num).toInt()];
}
