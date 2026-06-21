import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

void main() {
  group('WASIComponentAsyncHost', () {
    test('binds decoded canonical backpressure definitions', () {
      final component = WasmComponent.decode(_canonicalBackpressureBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      final program = host.bindCanonicalDefinitions(component);

      expect(program.operations.map((operation) => operation.kind), [
        WasmComponentCanonicalKind.backpressureSet,
        WasmComponentCanonicalKind.backpressureInc,
        WasmComponentCanonicalKind.backpressureDec,
      ]);

      expect(program.invoke(0, <Object?>[true]), 1);
      expect(host.backpressure.isActive, isTrue);
      expect(program.invoke(1, const <Object?>[]), 2);
      expect(program.invoke(2, const <Object?>[]), 1);
      expect(program.invoke(0, <Object?>[false]), 0);
      expect(host.backpressure.isActive, isFalse);
      expect(() => program.invoke(2, const <Object?>[]), throwsStateError);
    });

    test('packs endpoint handles as canonical i64 bit patterns', () {
      final handles = WASIComponentAsyncEndpointHandles(
        readable: 0xffffffff,
        writable: 0x80000000,
      );

      expect(handles.packed, isNegative);

      final signed = WASIComponentAsyncEndpointHandles.unpack(handles.packed);
      expect(signed.readable, 0xffffffff);
      expect(signed.writable, 0x80000000);

      final unsigned = WASIComponentAsyncEndpointHandles.unpack(
        handles.packed.toUnsigned(64),
      );
      expect(unsigned.readable, 0xffffffff);
      expect(unsigned.writable, 0x80000000);

      expect(
        () => WASIComponentAsyncEndpointHandles(
          readable: 0x100000000,
          writable: 1,
        ),
        throwsRangeError,
      );
      expect(WASIComponentAsyncEndpointHandles.unpack(-1).readable, 0xffffffff);
      expect(WASIComponentAsyncEndpointHandles.unpack(-1).writable, 0xffffffff);
    });

    test('binds decoded canonical stream definitions as a program', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      expect(component.validate(), isEmpty);
      final dropped = <String>[];
      final host = WASIComponentAsyncHost();
      host.defineStreamType<int>(
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

    test(
      'awaits pending stream reads through async program invocation',
      () async {
        final component = WasmComponent.decode(_canonicalStreamProgramBytes());
        expect(component.validate(), isEmpty);
        final host = WASIComponentAsyncHost();
        host.defineStreamType<int>(0, 'numbers');
        final program = host.bindCanonicalDefinitions(component);
        final stream =
            program.invoke(0, const <Object?>[])! as WASIComponentStream<int>;
        var completed = false;

        final pending = program.invokeAsync(1, <Object?>[stream.readable, 2])
          ..then((_) {
            completed = true;
          });
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);

        expect(
          program.invoke(2, <Object?>[
            stream.writable,
            <int>[1, 2, 3],
          ]),
          3,
        );

        await expectLater(pending, completion(<int>[1, 2]));
        expect(completed, isTrue);
        expect(program.invoke(1, <Object?>[stream.readable, 2]), <int>[3]);
      },
    );

    test('invokes decoded canonical stream definitions with handles', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      expect(component.validate(), isEmpty);
      final dropped = <String>[];
      final host = WASIComponentAsyncHost();
      host.defineStreamType<int>(
        0,
        'numbers',
        onDrop: () => dropped.add('numbers'),
      );

      final program = host.bindCanonicalDefinitionsToHandles(component);
      final handles = program.invoke(0, const <Object?>[]);

      expect(handles, isA<int>());
      final streamHandles = _unpackHandles(handles);
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

    test(
      'awaits pending stream reads through async handle invocation',
      () async {
        final component = WasmComponent.decode(_canonicalStreamProgramBytes());
        expect(component.validate(), isEmpty);
        final host = WASIComponentAsyncHost();
        host.defineStreamType<int>(0, 'numbers');

        final program = host.bindCanonicalDefinitionsToHandles(component);
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
        var completed = false;

        final pending = program.invokeAsync(1, <Object?>[handles.readable, 2])
          ..then((_) {
            completed = true;
          });
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);
        expect(
          () => program.invoke(5, <Object?>[handles.readable]),
          throwsStateError,
        );

        expect(
          program.invoke(2, <Object?>[
            handles.writable,
            <int>[1, 2, 3],
          ]),
          3,
        );

        await expectLater(pending, completion(<int>[1, 2]));
        expect(completed, isTrue);
        expect(program.invoke(1, <Object?>[handles.readable, 2]), <int>[3]);
        expect(program.invoke(5, <Object?>[handles.readable]), isNull);
        expect(program.invoke(6, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test('borrows stream endpoint handles during handle-backed writes', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamType<int>(0, 'numbers');

      final program = host.bindCanonicalDefinitionsToHandles(component);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final values = _DropDuringIteration(
        onFirstValue: () {
          expect(
            () => program.invoke(6, <Object?>[handles.writable]),
            throwsStateError,
          );
        },
      );

      expect(program.invoke(2, <Object?>[handles.writable, values]), 2);
      expect(program.invoke(1, <Object?>[handles.readable, 2]), <int>[1, 2]);
      expect(program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test(
      'awaits bounded stream write capacity through async program invocation',
      () async {
        final component = WasmComponent.decode(_canonicalStreamProgramBytes());
        expect(component.validate(), isEmpty);
        final host = WASIComponentAsyncHost();
        host.defineStreamType<int>(0, 'numbers', maxBufferedElements: 2);
        final program = host.bindCanonicalDefinitions(component);
        final stream =
            program.invoke(0, const <Object?>[])! as WASIComponentStream<int>;

        expect(
          program.invoke(2, <Object?>[
            stream.writable,
            <int>[1, 2],
          ]),
          2,
        );

        var completed = false;
        final pending =
            program.invokeAsync(2, <Object?>[
              stream.writable,
              <int>[3, 4],
            ])..then((_) {
              completed = true;
            });
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);
        expect(program.invoke(1, <Object?>[stream.readable, 1]), <int>[1]);

        await expectLater(pending, completion(1));
        expect(completed, isTrue);
        expect(program.invoke(1, <Object?>[stream.readable, 4]), <int>[2, 3]);
      },
    );

    test(
      'borrows bounded stream write handles until async write completes',
      () async {
        final component = WasmComponent.decode(_canonicalStreamProgramBytes());
        expect(component.validate(), isEmpty);
        final host = WASIComponentAsyncHost();
        host.defineStreamType<int>(0, 'numbers', maxBufferedElements: 2);

        final program = host.bindCanonicalDefinitionsToHandles(component);
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));

        expect(
          program.invoke(2, <Object?>[
            handles.writable,
            <int>[1, 2],
          ]),
          2,
        );

        final pending = program.invokeAsync(2, <Object?>[
          handles.writable,
          <int>[3],
        ]);
        await Future<void>.delayed(Duration.zero);

        expect(
          () => program.invoke(6, <Object?>[handles.writable]),
          throwsStateError,
        );
        expect(program.invoke(1, <Object?>[handles.readable, 1]), <int>[1]);

        await expectLater(pending, completion(1));
        expect(program.invoke(6, <Object?>[handles.writable]), isNull);
      },
    );

    test('binds decoded unit stream definitions as a program', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<Object?>(component, 0, 'ticks');
      final program = host.bindCanonicalDefinitions(component);
      final stream =
          program.invoke(0, const <Object?>[])! as WASIComponentStream<Object?>;

      expect(
        program.invoke(2, <Object?>[
          stream.writable,
          <Object?>[null, null],
        ]),
        2,
      );
      expect(program.invoke(1, <Object?>[stream.readable, 1]), <Object?>[null]);
      expect(
        () => program.invoke(2, <Object?>[
          stream.writable,
          <Object?>[1],
        ]),
        throwsStateError,
      );
    });

    test('binds decoded canonical future definitions as a program', () {
      final component = WasmComponent.decode(_canonicalFutureProgramBytes());
      expect(component.validate(), isEmpty);
      final dropped = <String>[];
      final host = WASIComponentAsyncHost();
      host.defineFutureType<String>(
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

    test(
      'awaits pending future reads through async program invocation',
      () async {
        final component = WasmComponent.decode(_canonicalFutureProgramBytes());
        expect(component.validate(), isEmpty);
        final host = WASIComponentAsyncHost();
        host.defineFutureType<String>(0, 'message');
        final program = host.bindCanonicalDefinitions(component);
        final future =
            program.invoke(0, const <Object?>[])!
                as WASIComponentFuture<String>;
        var completed = false;

        final pending = program.invokeAsync(1, <Object?>[future.readable])
          ..then((_) {
            completed = true;
          });
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);

        expect(program.invoke(2, <Object?>[future.writable, 'ready']), isNull);

        await expectLater(pending, completion('ready'));
        expect(completed, isTrue);
      },
    );

    test('invokes decoded canonical future definitions with handles', () {
      final component = WasmComponent.decode(_canonicalFutureProgramBytes());
      expect(component.validate(), isEmpty);
      final dropped = <String>[];
      final host = WASIComponentAsyncHost();
      host.defineFutureType<String>(
        0,
        'message',
        onDrop: () => dropped.add('message'),
      );

      final program = host.bindCanonicalDefinitionsToHandles(component);
      final handles = program.invoke(0, const <Object?>[]);

      expect(handles, isA<int>());
      final futureHandles = _unpackHandles(handles);
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

    test(
      'awaits pending future reads through async handle invocation',
      () async {
        final component = WasmComponent.decode(_canonicalFutureProgramBytes());
        expect(component.validate(), isEmpty);
        final host = WASIComponentAsyncHost();
        host.defineFutureType<String>(0, 'message');
        final program = host.bindCanonicalDefinitionsToHandles(component);
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
        var completed = false;

        final pending = program.invokeAsync(1, <Object?>[handles.readable])
          ..then((_) {
            completed = true;
          });
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);
        expect(
          () => program.invoke(5, <Object?>[handles.readable]),
          throwsStateError,
        );

        expect(program.invoke(2, <Object?>[handles.writable, 'ready']), isNull);

        await expectLater(pending, completion('ready'));
        expect(completed, isTrue);
        expect(program.invoke(5, <Object?>[handles.readable]), isNull);
        expect(program.invoke(6, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test('binds decoded unit future definitions as a program', () {
      final component = WasmComponent.decode(_canonicalFutureProgramBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<Object?>(component, 0, 'ready');
      final program = host.bindCanonicalDefinitions(component);
      final future =
          program.invoke(0, const <Object?>[])! as WASIComponentFuture<Object?>;

      expect(program.invoke(2, <Object?>[future.writable, null]), isNull);
      expect(program.invoke(1, <Object?>[future.readable]), isNull);

      final rejected =
          program.invoke(0, const <Object?>[])! as WASIComponentFuture<Object?>;
      expect(
        () => program.invoke(2, <Object?>[rejected.writable, 'payload']),
        throwsStateError,
      );
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
      host.defineStreamType<int>(0, 'numbers');
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

    test('copies decoded primitive stream values through canonical memory', () {
      final component = WasmComponent.decode(_streamU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 1, Endian.little);
      data.setUint32(36, 0xffffffff, Endian.little);
      data.setUint32(40, 13, Endian.little);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<int>(component, 0, 'u32-stream');
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 0,
        ),
      );
      final readOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamRead,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final writeOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final stream = newOperation.streamNew() as WASIComponentStream<int>;

      final writeResult = writeOperation.streamWriteFromMemory(
        stream.writable,
        memory,
        32,
        3,
      );
      final readResult = readOperation.streamReadToMemory(
        stream.readable,
        memory,
        96,
        2,
      );

      expect(writeResult.status, WASIComponentAsyncCopyStatus.completed);
      expect(writeResult.copiedElements, 3);
      expect(writeResult.packedResult, 3 << 4);
      expect(readResult.status, WASIComponentAsyncCopyStatus.completed);
      expect(readResult.copiedElements, 2);
      expect(data.getUint32(96, Endian.little), 1);
      expect(data.getUint32(100, Endian.little), 0xffffffff);
      expect(readOperation.streamRead(stream.readable, 2), <int>[13]);
    });

    test('copies handle-backed primitive stream values through memory', () {
      final component = WasmComponent.decode(_streamU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 21, Endian.little);
      data.setUint32(36, 34, Endian.little);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<int>(component, 0, 'u32-stream');
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 0,
        ),
      );
      final readOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamRead,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final writeOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final dropReadableOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropReadable,
          typeIndex: 0,
        ),
      );
      final dropWritableOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropWritable,
          typeIndex: 0,
        ),
      );
      final handles = newOperation.streamNewHandles();

      final writeResult = writeOperation.streamWriteHandleFromMemory(
        handles.writable,
        memory,
        32,
        2,
      );
      final readResult = readOperation.streamReadHandleToMemory(
        handles.readable,
        memory,
        96,
        2,
      );

      expect(writeResult.packedResult, 2 << 4);
      expect(readResult.packedResult, 2 << 4);
      expect(data.getUint32(96, Endian.little), 21);
      expect(data.getUint32(100, Endian.little), 34);
      expect(host.table.activeCount, 2);
      dropReadableOperation.streamDropReadableHandle(handles.readable);
      dropWritableOperation.streamDropWritableHandle(handles.writable);
      expect(host.table.activeCount, 0);
    });

    test('rejects unsupported and unaligned stream memory copies', () {
      final stringComponent = WasmComponent.decode(
        _streamStringTypeComponentBytes(),
      );
      expect(stringComponent.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<Object>(stringComponent, 0, 'strings');
      final stringWrite = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final stringStream = WASIComponentStream<Object>('strings');
      final memory = Memory(const MemoryDescriptor(initial: 1));

      expect(
        () => stringWrite.streamWriteFromMemory(
          stringStream.writable,
          memory,
          32,
          1,
        ),
        throwsUnsupportedError,
      );

      final u32Component = WasmComponent.decode(_streamU32TypeComponentBytes());
      expect(u32Component.validate(), isEmpty);
      final numberHost = WASIComponentAsyncHost();
      numberHost.defineStreamTypeFromComponent<int>(
        u32Component,
        0,
        'u32-stream',
      );
      final u32Write = numberHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final numberStream = WASIComponentStream<int>('u32-stream');

      expect(
        () => u32Write.streamWriteFromMemory(
          numberStream.writable,
          memory,
          33,
          1,
        ),
        throwsStateError,
      );
    });

    test('rejects malformed canonical bool stream memory values', () {
      final component = WasmComponent.decode(_streamBoolTypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      bytes[32] = 2;
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<bool>(component, 0, 'bool-stream');
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
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final stream = newOperation.streamNew() as WASIComponentStream<bool>;

      expect(
        () => writeOperation.streamWriteFromMemory(
          stream.writable,
          memory,
          32,
          1,
        ),
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

    test('copies decoded primitive future values through canonical memory', () {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 0xffffffff, Endian.little);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureNew,
          typeIndex: 0,
        ),
      );
      final readOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureRead,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final writeOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureWrite,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final future = newOperation.futureNew() as WASIComponentFuture<int>;

      final writeResult = writeOperation.futureWriteFromMemory(
        future.writable,
        memory,
        32,
      );
      final readResult = readOperation.futureReadToMemory(
        future.readable,
        memory,
        96,
      );

      expect(writeResult.status, WASIComponentAsyncCopyStatus.completed);
      expect(writeResult.copiedElements, 0);
      expect(writeResult.packedResult, 0);
      expect(readResult.status, WASIComponentAsyncCopyStatus.completed);
      expect(readResult.copiedElements, 0);
      expect(readResult.packedResult, 0);
      expect(data.getUint32(96, Endian.little), 0xffffffff);
    });

    test('copies handle-backed primitive future values through memory', () {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 377, Endian.little);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureNew,
          typeIndex: 0,
        ),
      );
      final readOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureRead,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final writeOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureWrite,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final dropReadableOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropReadable,
          typeIndex: 0,
        ),
      );
      final dropWritableOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropWritable,
          typeIndex: 0,
        ),
      );
      final handles = newOperation.futureNewHandles();

      final writeResult = writeOperation.futureWriteHandleFromMemory(
        handles.writable,
        memory,
        32,
      );
      final readResult = readOperation.futureReadHandleToMemory(
        handles.readable,
        memory,
        96,
      );

      expect(writeResult.packedResult, 0);
      expect(readResult.packedResult, 0);
      expect(data.getUint32(96, Endian.little), 377);
      expect(host.table.activeCount, 2);
      dropReadableOperation.futureDropReadableHandle(handles.readable);
      dropWritableOperation.futureDropWritableHandle(handles.writable);
      expect(host.table.activeCount, 0);
    });

    test('rejects unsupported and unaligned future memory copies', () {
      final stringComponent = WasmComponent.decode(
        _futureStringTypeComponentBytes(),
      );
      expect(stringComponent.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<Object>(stringComponent, 0, 'strings');
      final stringWrite = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureWrite,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final stringFuture = WASIComponentFuture<Object>('strings');
      final memory = Memory(const MemoryDescriptor(initial: 1));

      expect(
        () => stringWrite.futureWriteFromMemory(
          stringFuture.writable,
          memory,
          32,
        ),
        throwsUnsupportedError,
      );

      final u32Component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(u32Component.validate(), isEmpty);
      final numberHost = WASIComponentAsyncHost();
      numberHost.defineFutureTypeFromComponent<int>(
        u32Component,
        0,
        'u32-future',
      );
      final u32Write = numberHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureWrite,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final numberFuture = WASIComponentFuture<int>('u32-future');

      expect(
        () => u32Write.futureWriteFromMemory(numberFuture.writable, memory, 33),
        throwsStateError,
      );
    });

    test('validates indexed primitive stream element values', () {
      final component = WasmComponent.decode(
        _streamIndexedPrimitiveElementTypeComponentBytes(),
      );
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<Object>(
        component,
        1,
        'indexed-stream',
      );
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 1,
        ),
      );
      final writeOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 1,
        ),
      );
      final stream = newOperation.streamNew() as WASIComponentStream<Object>;

      expect(writeOperation.streamWrite(stream.writable, <Object>['ok']), 1);
      expect(
        () => writeOperation.streamWrite(stream.writable, <Object>[7]),
        throwsStateError,
      );
    });

    test('rejects indexed composite stream element types', () {
      final component = WasmComponent.decode(
        _streamIndexedCompositeElementTypeComponentBytes(),
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
    });
  });
}

Uint8List _canonicalBackpressureBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x08,
  0x04,
  0x03,
  0x08,
  0x24,
  0x25,
]);

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

Uint8List _futureStringTypeComponentBytes() => Uint8List.fromList(const <int>[
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
  0x73,
]);

Uint8List _streamBoolTypeComponentBytes() => Uint8List.fromList(const <int>[
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
  0x7f,
]);

Uint8List _streamU32TypeComponentBytes() => Uint8List.fromList(const <int>[
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
  0x79,
]);

Uint8List _streamIndexedPrimitiveElementTypeComponentBytes() =>
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

Uint8List _streamIndexedCompositeElementTypeComponentBytes() =>
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
      0x06,
      0x02,
      0x70,
      0x73,
      0x66,
      0x01,
      0x00,
    ]);

final class _DropDuringIteration extends Iterable<int> {
  _DropDuringIteration({required this.onFirstValue});

  final void Function() onFirstValue;

  @override
  Iterator<int> get iterator => _DropDuringIterationIterator(onFirstValue);
}

final class _DropDuringIterationIterator implements Iterator<int> {
  _DropDuringIterationIterator(this._onFirstValue);

  final void Function() _onFirstValue;
  int _index = -1;

  @override
  int get current => _index + 1;

  @override
  bool moveNext() {
    _index++;
    if (_index == 0) {
      _onFirstValue();
    }
    return _index < 2;
  }
}

WASIComponentAsyncEndpointHandles _unpackHandles(Object? packed) {
  final value = packed;
  expect(value, isA<int>());
  return WASIComponentAsyncEndpointHandles.unpack(value as int);
}
