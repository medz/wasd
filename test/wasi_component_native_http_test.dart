@TestOn('vm')
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

void main() {
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
      _expectUnitOk(
        program.invokeImport('wasi:http/types@0.2.0.outgoing-body.finish', [
              outgoingBody,
              _noneValue(),
            ])
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
