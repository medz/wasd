import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('WASIComponentAsyncHost', () {
    test('binds decoded canonical stream definitions as a program', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      expect(component.validate(), isEmpty);
      final dropped = <String>[];
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<int>(
        component,
        0,
        'numbers',
        onDrop: () => dropped.add('numbers'),
      );

      final program = host.bindCanonicalDefinitions(component);

      expect(program.operations.map((operation) => operation.kind), [
        WasmComponentCanonicalKind.streamNew,
        WasmComponentCanonicalKind.streamRead,
        WasmComponentCanonicalKind.streamWrite,
        WasmComponentCanonicalKind.streamCancelRead,
        WasmComponentCanonicalKind.streamCancelWrite,
        WasmComponentCanonicalKind.streamDropReadable,
        WasmComponentCanonicalKind.streamDropWritable,
      ]);

      final stream = program.invoke(0, const <Object?>[]);
      expect(stream, isA<WASIComponentStream<int>>());
      final typedStream = stream! as WASIComponentStream<int>;

      expect(
        program.invoke(2, <Object?>[
          typedStream.writable,
          <int>[1, 2, 3],
        ]),
        3,
      );
      expect(program.invoke(1, <Object?>[typedStream.readable, 2]), <int>[
        1,
        2,
      ]);
      expect(program.invoke(1, <Object?>[typedStream.readable, 4]), <int>[3]);

      expect(program.invoke(5, <Object?>[typedStream.readable]), isNull);
      expect(dropped, isEmpty);
      expect(program.invoke(6, <Object?>[typedStream.writable]), isNull);
      expect(dropped, <String>['numbers']);
    });

    test('invokes decoded canonical stream definitions with handles', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      expect(component.validate(), isEmpty);
      final dropped = <String>[];
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<int>(
        component,
        0,
        'numbers',
        onDrop: () => dropped.add('numbers'),
      );

      final program = host.bindCanonicalDefinitionsToHandles(component);
      final handles = program.invoke(0, const <Object?>[]);

      expect(handles, isA<WASIComponentAsyncEndpointHandles>());
      final streamHandles = handles! as WASIComponentAsyncEndpointHandles;
      expect(host.table.activeCount, 2);
      expect(
        program.invoke(2, <Object?>[
          streamHandles.writable,
          <int>[5, 8, 13],
        ]),
        3,
      );
      expect(program.invoke(1, <Object?>[streamHandles.readable, 2]), <int>[
        5,
        8,
      ]);
      expect(
        () => program.invoke(1, <Object?>[streamHandles.writable, 1]),
        throwsStateError,
      );

      expect(program.invoke(5, <Object?>[streamHandles.readable]), isNull);
      expect(host.table.activeCount, 1);
      expect(dropped, isEmpty);
      expect(program.invoke(6, <Object?>[streamHandles.writable]), isNull);
      expect(host.table.activeCount, 0);
      expect(dropped, <String>['numbers']);
      expect(
        () => program.invoke(1, <Object?>[streamHandles.readable, 1]),
        throwsStateError,
      );
    });

    test('binds decoded canonical future definitions as a program', () {
      final component = WasmComponent.decode(_canonicalFutureProgramBytes());
      expect(component.validate(), isEmpty);
      final dropped = <String>[];
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<String>(
        component,
        0,
        'message',
        onDrop: () => dropped.add('message'),
      );

      final program = host.bindCanonicalDefinitions(component);

      expect(program.operations.map((operation) => operation.kind), [
        WasmComponentCanonicalKind.futureNew,
        WasmComponentCanonicalKind.futureRead,
        WasmComponentCanonicalKind.futureWrite,
        WasmComponentCanonicalKind.futureCancelRead,
        WasmComponentCanonicalKind.futureCancelWrite,
        WasmComponentCanonicalKind.futureDropReadable,
        WasmComponentCanonicalKind.futureDropWritable,
      ]);

      final future = program.invoke(0, const <Object?>[]);
      expect(future, isA<WASIComponentFuture<String>>());
      final typedFuture = future! as WASIComponentFuture<String>;

      expect(
        program.invoke(2, <Object?>[typedFuture.writable, 'ready']),
        isNull,
      );
      expect(program.invoke(1, <Object?>[typedFuture.readable]), 'ready');
      expect(program.invoke(5, <Object?>[typedFuture.readable]), isNull);
      expect(dropped, isEmpty);
      expect(program.invoke(6, <Object?>[typedFuture.writable]), isNull);
      expect(dropped, <String>['message']);
    });

    test('invokes decoded canonical future definitions with handles', () {
      final component = WasmComponent.decode(_canonicalFutureProgramBytes());
      expect(component.validate(), isEmpty);
      final dropped = <String>[];
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<String>(
        component,
        0,
        'message',
        onDrop: () => dropped.add('message'),
      );

      final program = host.bindCanonicalDefinitionsToHandles(component);
      final handles = program.invoke(0, const <Object?>[]);

      expect(handles, isA<WASIComponentAsyncEndpointHandles>());
      final futureHandles = handles! as WASIComponentAsyncEndpointHandles;
      expect(host.table.activeCount, 2);
      expect(
        program.invoke(2, <Object?>[futureHandles.writable, 'ready']),
        isNull,
      );
      expect(program.invoke(1, <Object?>[futureHandles.readable]), 'ready');
      expect(
        () => program.invoke(1, <Object?>[futureHandles.writable]),
        throwsStateError,
      );

      expect(program.invoke(5, <Object?>[futureHandles.readable]), isNull);
      expect(host.table.activeCount, 1);
      expect(dropped, isEmpty);
      expect(program.invoke(6, <Object?>[futureHandles.writable]), isNull);
      expect(host.table.activeCount, 0);
      expect(dropped, <String>['message']);
    });

    test('rejects non-async definitions and mismatched type bindings', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      final host = WASIComponentAsyncHost();

      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.resourceNew,
            typeIndex: 0,
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        () =>
            host.bindCanonicalDefinition(component.canonicalDefinitions.first),
        throwsStateError,
      );

      host.defineFutureType<String>(0, 'wrong-kind');

      expect(
        () =>
            host.bindCanonicalDefinition(component.canonicalDefinitions.first),
        throwsStateError,
      );
    });

    test('validates host value and endpoint types', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<int>(component, 0, 'numbers');
      final program = host.bindCanonicalDefinitions(component);
      final stream =
          program.invoke(0, const <Object?>[])! as WASIComponentStream<int>;

      expect(
        () => program.invoke(2, <Object?>[
          stream.writable,
          <Object?>[1, 'bad'],
        ]),
        throwsStateError,
      );
      expect(
        () => program.invoke(1, <Object?>[stream.writable, 1]),
        throwsStateError,
      );
      expect(
        () => host.defineFutureTypeFromComponent<String>(component, 0, 'wrong'),
        throwsStateError,
      );
    });

    test('validates decoded stream element primitive values', () {
      final component = WasmComponent.decode(_streamStringTypeComponentBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<Object>(component, 0, 'strings');
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 0,
        ),
      );
      final writeOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 0,
        ),
      );
      final stream = newOperation.streamNew() as WASIComponentStream<Object>;

      expect(
        writeOperation.streamWrite(stream.writable, <Object>['hello', 'wasi']),
        2,
      );
      expect(
        () => writeOperation.streamWrite(stream.writable, <Object>['ok', 3]),
        throwsStateError,
      );
    });

    test('validates decoded future element integer bounds', () {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureNew,
          typeIndex: 0,
        ),
      );
      final writeOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureWrite,
          typeIndex: 0,
        ),
      );

      final accepted = newOperation.futureNew() as WASIComponentFuture<int>;
      writeOperation.futureWrite(accepted.writable, 0xffffffff);
      expect(accepted.readable.read(), 0xffffffff);

      final rejected = newOperation.futureNew() as WASIComponentFuture<int>;
      expect(
        () => writeOperation.futureWrite(rejected.writable, -1),
        throwsStateError,
      );
      expect(
        () => writeOperation.futureWrite(rejected.writable, 0x100000000),
        throwsStateError,
      );
    });

    test(
      'rejects indexed stream element types until lowering is supported',
      () {
        final component = WasmComponent.decode(
          _streamIndexedElementTypeComponentBytes(),
        );
        expect(component.validate(), isEmpty);
        final host = WASIComponentAsyncHost();

        expect(
          () => host.defineStreamTypeFromComponent<Object>(
            component,
            1,
            'indexed-stream',
          ),
          throwsUnsupportedError,
        );
      },
    );
  });
}

Uint8List _canonicalStreamProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x03,
  0x01,
  0x66,
  0x00,
  0x08,
  0x13,
  0x07,
  0x0e,
  0x00,
  0x0f,
  0x00,
  0x00,
  0x10,
  0x00,
  0x00,
  0x11,
  0x00,
  0x00,
  0x12,
  0x00,
  0x00,
  0x13,
  0x00,
  0x14,
  0x00,
]);

Uint8List _canonicalFutureProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x03,
  0x01,
  0x65,
  0x00,
  0x08,
  0x13,
  0x07,
  0x15,
  0x00,
  0x16,
  0x00,
  0x00,
  0x17,
  0x00,
  0x00,
  0x18,
  0x00,
  0x00,
  0x19,
  0x00,
  0x00,
  0x1a,
  0x00,
  0x1b,
  0x00,
]);

Uint8List _streamStringTypeComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x04,
  0x01,
  0x66,
  0x01,
  0x73,
]);

Uint8List _futureU32TypeComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x04,
  0x01,
  0x65,
  0x01,
  0x79,
]);

Uint8List _streamIndexedElementTypeComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x02,
      0x73,
      0x66,
      0x01,
      0x00,
    ]);
