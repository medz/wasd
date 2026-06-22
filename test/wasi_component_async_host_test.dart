import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/error_context.dart';
import 'package:wasd/src/wasi/component/waitable_set.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

import 'support/component_fixtures.dart' as component_fixtures;

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

    test('copies error-context stream handles through memory', () {
      final component = WasmComponent.decode(
        _streamErrorContextTypeComponentBytes(),
      );
      expect(component.validate(), isEmpty);
      final errorHost = WASIComponentErrorContextHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final errorHandle = errorHost.create('stream failed');
      data.setUint32(32, errorHandle, Endian.little);
      final host = WASIComponentAsyncHost(table: errorHost.table);
      host.defineStreamTypeFromComponent<int>(
        component,
        0,
        'error-context-stream',
      );
      final program = _streamErrorContextMemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));

      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32, 1]),
        1 << 4,
      );
      expect(
        program.invokeWithMemory(2, memory, <Object?>[handles.readable, 96, 1]),
        1 << 4,
      );
      expect(data.getUint32(96, Endian.little), errorHandle);
      expect(errorHost.debugMessage(errorHandle), 'stream failed');
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(errorHost.table.activeCount, 1);
      errorHost.drop(errorHandle);
      expect(errorHost.table.activeCount, 0);
    });

    test('copies owned resource stream handles through canonical memory', () {
      final component = WasmComponent.decode(
        component_fixtures.streamOwnResourceTypeComponentBytes(),
      );
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 0x7fffffff, Endian.little);
      data.setUint32(36, 0x80000000, Endian.little);
      final host = WASIComponentAsyncHost();
      final bindings = host.componentAsyncValueBindings(component);

      expect(bindings.single.componentTypeIndex, 2);
      expect(bindings.single.memoryLayout!.byteLength, 4);
      expect(bindings.single.memoryLayout!.alignment, 4);

      host.defineStreamTypeFromComponent<int>(
        component,
        2,
        'owned-resource-stream',
      );
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 2,
        ),
      );
      final readOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamRead,
          typeIndex: 2,
        ),
      );
      final writeOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 2,
        ),
      );
      final dropReadableOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropReadable,
          typeIndex: 2,
        ),
      );
      final dropWritableOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropWritable,
          typeIndex: 2,
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
      expect(data.getUint32(96, Endian.little), 0x7fffffff);
      expect(data.getUint32(100, Endian.little), 0x80000000);
      expect(host.table.activeCount, 2);
      dropReadableOperation.streamDropReadableHandle(handles.readable);
      dropWritableOperation.streamDropWritableHandle(handles.writable);
      expect(host.table.activeCount, 0);
    });

    test('invokes handle-backed stream memory copies with core ABI args', () {
      final component = WasmComponent.decode(_streamU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 55, Endian.little);
      data.setUint32(36, 89, Endian.little);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<int>(component, 0, 'u32-stream');
      final program = _streamU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));

      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32, 2]),
        2 << 4,
      );
      expect(
        program.invokeWithMemory(2, memory, <Object?>[handles.readable, 96, 2]),
        2 << 4,
      );
      expect(data.getUint32(96, Endian.little), 55);
      expect(data.getUint32(100, Endian.little), 89);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('awaits pending handle-backed stream reads into memory', () async {
      final component = WasmComponent.decode(_streamU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 144, Endian.little);
      data.setUint32(36, 233, Endian.little);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<int>(component, 0, 'u32-stream');
      final program = _streamU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      var completed = false;

      final pending =
          program.invokeWithMemoryAsync(2, memory, <Object?>[
            handles.readable,
            96,
            2,
          ])..then((_) {
            completed = true;
          });
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);
      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32, 2]),
        2 << 4,
      );
      await expectLater(pending, completion(2 << 4));
      expect(completed, isTrue);
      expect(data.getUint32(96, Endian.little), 144);
      expect(data.getUint32(100, Endian.little), 233);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('publishes handle-backed stream read memory events', () async {
      final component = WasmComponent.decode(_streamU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 144, Endian.little);
      data.setUint32(36, 233, Endian.little);
      final host = WASIComponentAsyncHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      host.defineStreamTypeFromComponent<int>(component, 0, 'u32-stream');
      final program = _streamU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handles.readable, waitableSet);
      var completed = false;

      expect(
        program.invokeWithMemoryEvent(2, memory, <Object?>[
          handles.readable,
          96,
          2,
        ]),
        wasiComponentAsyncBlocked,
      );
      final pending =
          waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128)
            ..then((_) {
              completed = true;
            });
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);
      expect(
        () => program.invoke(3, <Object?>[handles.readable]),
        throwsStateError,
      );
      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32, 2]),
        2 << 4,
      );

      await expectLater(pending, completion(2));
      expect(completed, isTrue);
      expect(data.getUint32(96, Endian.little), 144);
      expect(data.getUint32(100, Endian.little), 233);
      expect(data.getUint32(128, Endian.little), handles.readable);
      expect(data.getUint32(132, Endian.little), 2 << 4);
      waitableHost.waitableJoin(handles.readable, 0);
      waitableHost.waitableSetDrop(waitableSet);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('rejects duplicate handle-backed stream read memory events', () async {
      final component = WasmComponent.decode(_streamU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 377, Endian.little);
      final host = WASIComponentAsyncHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      host.defineStreamTypeFromComponent<int>(component, 0, 'u32-stream');
      final program = _streamU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handles.readable, waitableSet);

      expect(
        program.invokeWithMemoryEvent(2, memory, <Object?>[
          handles.readable,
          96,
          1,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(
        () => program.invokeWithMemoryEvent(2, memory, <Object?>[
          handles.readable,
          100,
          1,
        ]),
        throwsStateError,
      );
      expect(
        () => program.invoke(3, <Object?>[handles.readable]),
        throwsStateError,
      );

      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32, 1]),
        1 << 4,
      );
      await expectLater(
        waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
        completion(2),
      );
      waitableHost.waitableJoin(handles.readable, 0);
      waitableHost.waitableSetDrop(waitableSet);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test(
      'publishes cancelled handle-backed stream read memory events',
      () async {
        final component = WasmComponent.decode(_streamU32TypeComponentBytes());
        expect(component.validate(), isEmpty);
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        final host = WASIComponentAsyncHost();
        final waitableHost = WASIComponentWaitableHost(
          table: host.table,
          waitableResolvers: [host.waitableForHandle],
        );
        host.defineStreamTypeFromComponent<int>(component, 0, 'u32-stream');
        final program = _streamU32MemoryCancelHandleProgram(host);
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
        final waitableSet = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(handles.readable, waitableSet);

        expect(
          program.invokeWithMemoryEvent(2, memory, <Object?>[
            handles.readable,
            96,
            1,
          ]),
          wasiComponentAsyncBlocked,
        );
        expect(
          program.invoke(3, <Object?>[handles.readable]),
          wasiComponentAsyncBlocked,
        );
        expect(
          () => program.invoke(3, <Object?>[handles.readable]),
          throwsStateError,
        );

        await expectLater(
          waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
          completion(2),
        );
        expect(data.getUint32(128, Endian.little), handles.readable);
        expect(
          data.getUint32(132, Endian.little),
          WASIComponentAsyncCopyResult.cancelled().packedResult,
        );
        waitableHost.waitableJoin(handles.readable, 0);
        waitableHost.waitableSetDrop(waitableSet);
        expect(program.invoke(5, <Object?>[handles.readable]), isNull);
        expect(program.invoke(6, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test(
      'waits for synchronous handle-backed stream read cancel memory events',
      () async {
        final component = WasmComponent.decode(_streamU32TypeComponentBytes());
        expect(component.validate(), isEmpty);
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final host = WASIComponentAsyncHost();
        host.defineStreamTypeFromComponent<int>(component, 0, 'u32-stream');
        final program = _streamU32MemoryCancelHandleProgram(
          host,
          cancelIsAsync: false,
        );
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));

        expect(
          program.invokeWithMemoryEvent(2, memory, <Object?>[
            handles.readable,
            96,
            1,
          ]),
          wasiComponentAsyncBlocked,
        );
        await expectLater(
          program.invokeAsync(3, <Object?>[handles.readable]),
          completion(WASIComponentAsyncCopyResult.cancelled().packedResult),
        );
        expect(
          () => program.invoke(3, <Object?>[handles.readable]),
          throwsStateError,
        );

        expect(program.invoke(5, <Object?>[handles.readable]), isNull);
        expect(program.invoke(6, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test('publishes dropped handle-backed stream read memory events', () async {
      final component = WasmComponent.decode(_streamU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final host = WASIComponentAsyncHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      host.defineStreamTypeFromComponent<int>(component, 0, 'u32-stream');
      final program = _streamU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handles.readable, waitableSet);

      expect(
        program.invokeWithMemoryEvent(2, memory, <Object?>[
          handles.readable,
          96,
          1,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);

      await expectLater(
        waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
        completion(2),
      );
      expect(data.getUint32(128, Endian.little), handles.readable);
      expect(
        data.getUint32(132, Endian.little),
        WASIComponentAsyncCopyStatus.dropped.code,
      );
      waitableHost.waitableJoin(handles.readable, 0);
      waitableHost.waitableSetDrop(waitableSet);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('cancels bounded handle-backed stream write memory events', () async {
      final component = WasmComponent.decode(_streamU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 3, Endian.little);
      data.setUint32(36, 5, Endian.little);
      final host = WASIComponentAsyncHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      host.defineStreamTypeFromComponent<int>(
        component,
        0,
        'u32-stream',
        maxBufferedElements: 1,
      );
      final program = _streamU32MemoryCancelHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handles.writable, waitableSet);

      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32, 1]),
        1 << 4,
      );
      expect(
        program.invokeWithMemoryEvent(1, memory, <Object?>[
          handles.writable,
          36,
          1,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(
        program.invoke(4, <Object?>[handles.writable]),
        wasiComponentAsyncBlocked,
      );

      await expectLater(
        waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
        completion(3),
      );
      expect(data.getUint32(128, Endian.little), handles.writable);
      expect(
        data.getUint32(132, Endian.little),
        WASIComponentAsyncCopyResult.cancelled().packedResult,
      );
      waitableHost.waitableJoin(handles.writable, 0);
      waitableHost.waitableSetDrop(waitableSet);
      expect(program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test(
      'waits for synchronous bounded stream write cancel memory events',
      () async {
        final component = WasmComponent.decode(_streamU32TypeComponentBytes());
        expect(component.validate(), isEmpty);
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        data.setUint32(32, 3, Endian.little);
        data.setUint32(36, 5, Endian.little);
        final host = WASIComponentAsyncHost();
        host.defineStreamTypeFromComponent<int>(
          component,
          0,
          'u32-stream',
          maxBufferedElements: 1,
        );
        final program = _streamU32MemoryCancelHandleProgram(
          host,
          cancelIsAsync: false,
        );
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));

        expect(
          program.invokeWithMemory(1, memory, <Object?>[
            handles.writable,
            32,
            1,
          ]),
          1 << 4,
        );
        expect(
          program.invokeWithMemoryEvent(1, memory, <Object?>[
            handles.writable,
            36,
            1,
          ]),
          wasiComponentAsyncBlocked,
        );
        await expectLater(
          program.invokeAsync(4, <Object?>[handles.writable]),
          completion(WASIComponentAsyncCopyResult.cancelled().packedResult),
        );

        expect(program.invoke(5, <Object?>[handles.readable]), isNull);
        expect(program.invoke(6, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test(
      'publishes dropped bounded handle-backed stream write memory events',
      () async {
        final component = WasmComponent.decode(_streamU32TypeComponentBytes());
        expect(component.validate(), isEmpty);
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        data.setUint32(32, 3, Endian.little);
        data.setUint32(36, 5, Endian.little);
        final host = WASIComponentAsyncHost();
        final waitableHost = WASIComponentWaitableHost(
          table: host.table,
          waitableResolvers: [host.waitableForHandle],
        );
        host.defineStreamTypeFromComponent<int>(
          component,
          0,
          'u32-stream',
          maxBufferedElements: 1,
        );
        final program = _streamU32MemoryHandleProgram(host);
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
        final waitableSet = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(handles.writable, waitableSet);

        expect(
          program.invokeWithMemory(1, memory, <Object?>[
            handles.writable,
            32,
            1,
          ]),
          1 << 4,
        );
        expect(
          program.invokeWithMemoryEvent(1, memory, <Object?>[
            handles.writable,
            36,
            1,
          ]),
          wasiComponentAsyncBlocked,
        );
        expect(program.invoke(3, <Object?>[handles.readable]), isNull);

        await expectLater(
          waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
          completion(3),
        );
        expect(data.getUint32(128, Endian.little), handles.writable);
        expect(
          data.getUint32(132, Endian.little),
          WASIComponentAsyncCopyStatus.dropped.code,
        );
        waitableHost.waitableJoin(handles.writable, 0);
        waitableHost.waitableSetDrop(waitableSet);
        expect(program.invoke(4, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test(
      'publishes bounded handle-backed stream write memory events',
      () async {
        final component = WasmComponent.decode(_streamU32TypeComponentBytes());
        expect(component.validate(), isEmpty);
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        data.setUint32(32, 3, Endian.little);
        data.setUint32(36, 5, Endian.little);
        final host = WASIComponentAsyncHost();
        final waitableHost = WASIComponentWaitableHost(
          table: host.table,
          waitableResolvers: [host.waitableForHandle],
        );
        host.defineStreamTypeFromComponent<int>(
          component,
          0,
          'u32-stream',
          maxBufferedElements: 1,
        );
        final program = _streamU32MemoryHandleProgram(host);
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
        final waitableSet = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(handles.writable, waitableSet);

        expect(
          program.invokeWithMemory(1, memory, <Object?>[
            handles.writable,
            32,
            1,
          ]),
          1 << 4,
        );
        expect(
          program.invokeWithMemoryEvent(1, memory, <Object?>[
            handles.writable,
            36,
            1,
          ]),
          wasiComponentAsyncBlocked,
        );
        expect(
          program.invokeWithMemory(2, memory, <Object?>[
            handles.readable,
            96,
            1,
          ]),
          1 << 4,
        );

        await expectLater(
          waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
          completion(3),
        );
        expect(data.getUint32(128, Endian.little), handles.writable);
        expect(data.getUint32(132, Endian.little), 1 << 4);
        expect(
          program.invokeWithMemory(2, memory, <Object?>[
            handles.readable,
            100,
            1,
          ]),
          1 << 4,
        );
        expect(data.getUint32(96, Endian.little), 3);
        expect(data.getUint32(100, Endian.little), 5);
        waitableHost.waitableJoin(handles.writable, 0);
        waitableHost.waitableSetDrop(waitableSet);
        expect(program.invoke(3, <Object?>[handles.readable]), isNull);
        expect(program.invoke(4, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test('awaits bounded handle-backed stream writes from memory', () async {
      final component = WasmComponent.decode(_streamU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 3, Endian.little);
      data.setUint32(36, 5, Endian.little);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<int>(
        component,
        0,
        'u32-stream',
        maxBufferedElements: 1,
      );
      final program = _streamU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32, 1]),
        1 << 4,
      );
      var completed = false;

      final pending =
          program.invokeWithMemoryAsync(1, memory, <Object?>[
            handles.writable,
            36,
            1,
          ])..then((_) {
            completed = true;
          });
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);
      expect(
        program.invokeWithMemory(2, memory, <Object?>[handles.readable, 96, 1]),
        1 << 4,
      );
      await expectLater(pending, completion(1 << 4));
      expect(completed, isTrue);
      expect(
        program.invokeWithMemory(2, memory, <Object?>[
          handles.readable,
          100,
          1,
        ]),
        1 << 4,
      );
      expect(data.getUint32(96, Endian.little), 3);
      expect(data.getUint32(100, Endian.little), 5);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('copies decoded string stream values from canonical memory', () {
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
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.stringEncodingUtf16,
            ),
          ],
        ),
      );
      final stringStream = WASIComponentStream<Object>('strings');
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint16(96, 0x68, Endian.little);
      data.setUint16(98, 0xe9, Endian.little);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 2, Endian.little);

      final result = stringWrite.streamWriteFromMemory(
        stringStream.writable,
        memory,
        32,
        1,
      );

      expect(result.packedResult, 1 << 4);
      expect(stringStream.readable.read(1), ['hé']);
    });

    test('rejects out-of-bounds string stream record ranges', () {
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
          0,
          memory.buffer.lengthInBytes ~/ 8 + 1,
        ),
        throwsRangeError,
      );
      expect(stringStream.readable.read(1), isEmpty);
    });

    test('writes decoded string stream reads to canonical memory', () {
      final component = WasmComponent.decode(_streamStringTypeComponentBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<Object>(component, 0, 'strings');
      final program = _streamStringMemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      var nextPointer = 96;

      expect(
        program.invoke(1, <Object?>[
          handles.writable,
          ['hé'],
        ]),
        1,
      );
      expect(
        program.invokeWithMemory(
          2,
          memory,
          <Object?>[handles.readable, 32, 1],
          realloc: (oldPointer, oldSize, alignment, newSize) {
            expect(oldPointer, 0);
            expect(oldSize, 0);
            expect(alignment, 2);
            expect(newSize, 4);
            final pointer = nextPointer;
            nextPointer += newSize;
            return pointer;
          },
        ),
        1 << 4,
      );
      expect(data.getUint32(32, Endian.little), 96);
      expect(data.getUint32(36, Endian.little), 2);
      expect(data.getUint16(96, Endian.little), 0x68);
      expect(data.getUint16(98, Endian.little), 0xe9);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('copies decoded list stream values through canonical memory', () {
      final component = WasmComponent.decode(
        _streamListU32TypeComponentBytes(),
      );
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<WasmComponentValueData>(
        component,
        1,
        'u32-lists',
      );
      final program = _streamListU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 2, Endian.little);
      data.setUint32(96, 7, Endian.little);
      data.setUint32(100, 8, Endian.little);

      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32, 1]),
        1 << 4,
      );
      expect(
        () => program.invokeWithMemory(2, memory, <Object?>[
          handles.readable,
          64,
          1,
        ]),
        throwsUnsupportedError,
      );
      expect(
        program.invokeWithMemory(
          2,
          memory,
          <Object?>[handles.readable, 64, 1],
          realloc: (oldPointer, oldSize, alignment, newSize) {
            expect(oldPointer, 0);
            expect(oldSize, 0);
            expect(alignment, 4);
            expect(newSize, 8);
            return 128;
          },
        ),
        1 << 4,
      );
      expect(data.getUint32(64, Endian.little), 128);
      expect(data.getUint32(68, Endian.little), 2);
      expect(data.getUint32(128, Endian.little), 7);
      expect(data.getUint32(132, Endian.little), 8);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test(
      'copies decoded string list stream values through canonical memory',
      () {
        final component = WasmComponent.decode(
          _streamListStringTypeComponentBytes(),
        );
        expect(component.validate(), isEmpty);
        final host = WASIComponentAsyncHost();
        host.defineStreamTypeFromComponent<WasmComponentValueData>(
          component,
          1,
          'string-lists',
        );
        final program = _streamListStringMemoryHandleProgram(host);
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final bytes = Uint8List.view(memory.buffer);
        final data = ByteData.view(memory.buffer);
        bytes.setAll(160, 'go'.codeUnits);
        bytes.setAll(176, 'hi'.codeUnits);
        data.setUint32(96, 160, Endian.little);
        data.setUint32(100, 2, Endian.little);
        data.setUint32(104, 176, Endian.little);
        data.setUint32(108, 2, Endian.little);
        data.setUint32(32, 96, Endian.little);
        data.setUint32(36, 2, Endian.little);

        expect(
          program.invokeWithMemory(1, memory, <Object?>[
            handles.writable,
            32,
            1,
          ]),
          1 << 4,
        );
        final allocations = <int>[224, 256, 272];
        expect(
          program.invokeWithMemory(
            2,
            memory,
            <Object?>[handles.readable, 64, 1],
            realloc: (oldPointer, oldSize, alignment, newSize) {
              expect(oldPointer, 0);
              expect(oldSize, 0);
              if (allocations.length == 3) {
                expect(alignment, 4);
                expect(newSize, 16);
              } else {
                expect(alignment, 1);
                expect(newSize, 2);
              }
              return allocations.removeAt(0);
            },
          ),
          1 << 4,
        );
        expect(data.getUint32(64, Endian.little), 224);
        expect(data.getUint32(68, Endian.little), 2);
        expect(data.getUint32(224, Endian.little), 256);
        expect(data.getUint32(228, Endian.little), 2);
        expect(data.getUint32(232, Endian.little), 272);
        expect(data.getUint32(236, Endian.little), 2);
        expect(String.fromCharCodes(bytes.sublist(256, 258)), 'go');
        expect(String.fromCharCodes(bytes.sublist(272, 274)), 'hi');
        expect(allocations, isEmpty);
        expect(program.invoke(3, <Object?>[handles.readable]), isNull);
        expect(program.invoke(4, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test('copies decoded flags stream values through canonical memory', () {
      final component = WasmComponent.decode(_streamFlagsTypeComponentBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<WasmComponentValueData>(
        component,
        1,
        'flags',
      );
      final program = _streamFlagsMemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint8(32, 0x05);

      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32, 1]),
        1 << 4,
      );
      expect(
        program.invokeWithMemory(2, memory, <Object?>[handles.readable, 64, 1]),
        1 << 4,
      );
      expect(data.getUint8(64), 0x05);

      final duplicate = WasmComponentValueData(
        kind: WasmComponentValueDataKind.flags,
        rawBytes: Uint8List(0),
        labels: ['a', 'a'],
      );
      expect(
        () => program.invoke(1, <Object?>[
          handles.writable,
          [duplicate],
        ]),
        throwsStateError,
      );
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('rejects conflicting option stream value selectors', () {
      final component = WasmComponent.decode(
        _streamOptionU32TypeComponentBytes(),
      );
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<WasmComponentValueData>(
        component,
        1,
        'options',
      );
      final program = _streamOptionU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint8(32, 1);
      data.setUint32(36, 0x12345678, Endian.little);

      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32, 1]),
        1 << 4,
      );
      expect(
        program.invokeWithMemory(2, memory, <Object?>[handles.readable, 64, 1]),
        1 << 4,
      );
      expect(data.getUint8(64), 1);
      expect(data.getUint32(68, Endian.little), 0x12345678);

      final conflicting = WasmComponentValueData(
        kind: WasmComponentValueDataKind.option,
        rawBytes: Uint8List(0),
        index: 1,
        isSome: false,
        associatedValue: WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: 7,
        ),
      );
      expect(
        () => program.invoke(1, <Object?>[
          handles.writable,
          [conflicting],
        ]),
        throwsStateError,
      );
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('does not require realloc for empty string stream reads', () {
      final component = WasmComponent.decode(_streamStringTypeComponentBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<Object>(component, 0, 'strings');
      final program = _streamStringMemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final memory = Memory(const MemoryDescriptor(initial: 1));

      expect(
        program.invokeWithMemory(2, memory, <Object?>[handles.readable, 32, 0]),
        0,
      );
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('awaits pending string stream reads into canonical memory', () async {
      final component = WasmComponent.decode(_streamStringTypeComponentBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineStreamTypeFromComponent<Object>(component, 0, 'strings');
      final program = _streamStringMemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      var completed = false;

      final pending =
          program.invokeWithMemoryAsync(
            2,
            memory,
            <Object?>[handles.readable, 32, 1],
            realloc: (oldPointer, oldSize, alignment, newSize) {
              expect(oldPointer, 0);
              expect(oldSize, 0);
              expect(alignment, 2);
              expect(newSize, 4);
              return 96;
            },
          )..then((_) {
            completed = true;
          });
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);
      expect(
        program.invoke(1, <Object?>[
          handles.writable,
          ['go'],
        ]),
        1,
      );
      await expectLater(pending, completion(1 << 4));
      expect(completed, isTrue);
      expect(data.getUint32(32, Endian.little), 96);
      expect(data.getUint32(36, Endian.little), 2);
      expect(data.getUint16(96, Endian.little), 0x67);
      expect(data.getUint16(98, Endian.little), 0x6f);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('rejects unaligned stream memory copies', () {
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
      final memory = Memory(const MemoryDescriptor(initial: 1));

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

    test('loads nonzero canonical bool stream memory values as true', () {
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
        writeOperation
            .streamWriteFromMemory(stream.writable, memory, 32, 1)
            .packedResult,
        1 << 4,
      );
      expect(stream.readable.read(1), [true]);
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
      expect(
        () => readOperation.futureReadHandleToMemory(
          handles.readable,
          memory,
          100,
        ),
        throwsStateError,
      );
      expect(host.table.activeCount, 2);
      dropReadableOperation.futureDropReadableHandle(handles.readable);
      dropWritableOperation.futureDropWritableHandle(handles.writable);
      expect(host.table.activeCount, 0);
    });

    test('copies error-context future handles through memory', () {
      final component = WasmComponent.decode(
        _futureErrorContextTypeComponentBytes(),
      );
      expect(component.validate(), isEmpty);
      final errorHost = WASIComponentErrorContextHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final errorHandle = errorHost.create('future failed');
      data.setUint32(32, errorHandle, Endian.little);
      final host = WASIComponentAsyncHost(table: errorHost.table);
      host.defineFutureTypeFromComponent<int>(
        component,
        0,
        'error-context-future',
      );
      final program = _futureErrorContextMemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));

      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32]),
        0,
      );
      expect(
        program.invokeWithMemory(2, memory, <Object?>[handles.readable, 96]),
        0,
      );
      expect(data.getUint32(96, Endian.little), errorHandle);
      expect(errorHost.debugMessage(errorHandle), 'future failed');
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(errorHost.table.activeCount, 1);
      errorHost.drop(errorHandle);
      expect(errorHost.table.activeCount, 0);
    });

    test('invokes handle-backed future memory copies with core ABI args', () {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 987, Endian.little);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final program = _futureU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));

      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32]),
        0,
      );
      expect(
        program.invokeWithMemory(2, memory, <Object?>[handles.readable, 96]),
        0,
      );
      expect(data.getUint32(96, Endian.little), 987);
      expect(
        () => program.invokeWithMemory(2, memory, <Object?>[
          handles.readable,
          100,
        ]),
        throwsStateError,
      );
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('copies owned resource future handles through canonical memory', () {
      final component = WasmComponent.decode(
        component_fixtures.futureOwnResourceTypeComponentBytes(),
      );
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 0xffffffff, Endian.little);
      final host = WASIComponentAsyncHost();
      final bindings = host.componentAsyncValueBindings(component);

      expect(bindings.single.componentTypeIndex, 2);
      expect(bindings.single.memoryLayout!.byteLength, 4);
      expect(bindings.single.memoryLayout!.alignment, 4);

      host.defineFutureTypeFromComponent<int>(
        component,
        2,
        'owned-resource-future',
      );
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureNew,
          typeIndex: 2,
        ),
      );
      final readOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureRead,
          typeIndex: 2,
        ),
      );
      final writeOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureWrite,
          typeIndex: 2,
        ),
      );
      final dropReadableOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropReadable,
          typeIndex: 2,
        ),
      );
      final dropWritableOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropWritable,
          typeIndex: 2,
        ),
      );
      final handles = newOperation.futureNewHandles();

      expect(
        writeOperation
            .futureWriteHandleFromMemory(handles.writable, memory, 32)
            .packedResult,
        0,
      );
      expect(
        readOperation
            .futureReadHandleToMemory(handles.readable, memory, 96)
            .packedResult,
        0,
      );
      expect(data.getUint32(96, Endian.little), 0xffffffff);
      expect(host.table.activeCount, 2);
      dropReadableOperation.futureDropReadableHandle(handles.readable);
      dropWritableOperation.futureDropWritableHandle(handles.writable);
      expect(host.table.activeCount, 0);
    });

    test('awaits pending handle-backed future reads into memory', () async {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 1597, Endian.little);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final program = _futureU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      var completed = false;

      final pending =
          program.invokeWithMemoryAsync(2, memory, <Object?>[
            handles.readable,
            96,
          ])..then((_) {
            completed = true;
          });
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);
      await expectLater(
        program.invokeWithMemoryAsync(2, memory, <Object?>[
          handles.readable,
          100,
        ]),
        throwsStateError,
      );
      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32]),
        0,
      );
      await expectLater(pending, completion(0));
      expect(completed, isTrue);
      expect(data.getUint32(96, Endian.little), 1597);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('publishes handle-backed future read memory events', () async {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 1597, Endian.little);
      final host = WASIComponentAsyncHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final program = _futureU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handles.readable, waitableSet);

      expect(
        program.invokeWithMemoryEvent(2, memory, <Object?>[
          handles.readable,
          96,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32]),
        0,
      );

      await expectLater(
        waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
        completion(4),
      );
      expect(data.getUint32(96, Endian.little), 1597);
      expect(data.getUint32(128, Endian.little), handles.readable);
      expect(data.getUint32(132, Endian.little), 0);
      expect(
        () => program.invokeWithMemory(2, memory, <Object?>[
          handles.readable,
          100,
        ]),
        throwsStateError,
      );
      waitableHost.waitableJoin(handles.readable, 0);
      waitableHost.waitableSetDrop(waitableSet);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('publishes handle-backed future write memory events', () async {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 610, Endian.little);
      final host = WASIComponentAsyncHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final program = _futureU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handles.writable, waitableSet);

      expect(
        program.invokeWithMemoryEvent(1, memory, <Object?>[
          handles.writable,
          32,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(
        program.invokeWithMemory(2, memory, <Object?>[handles.readable, 96]),
        0,
      );

      await expectLater(
        waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
        completion(5),
      );
      expect(data.getUint32(96, Endian.little), 610);
      expect(data.getUint32(128, Endian.little), handles.writable);
      expect(data.getUint32(132, Endian.little), 0);
      waitableHost.waitableJoin(handles.writable, 0);
      waitableHost.waitableSetDrop(waitableSet);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('cancels handle-backed future read memory events', () async {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final host = WASIComponentAsyncHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final program = _futureU32MemoryCancelHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handles.readable, waitableSet);

      expect(
        program.invokeWithMemoryEvent(2, memory, <Object?>[
          handles.readable,
          96,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(
        program.invoke(3, <Object?>[handles.readable]),
        wasiComponentAsyncBlocked,
      );

      await expectLater(
        waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
        completion(4),
      );
      expect(data.getUint32(128, Endian.little), handles.readable);
      expect(
        data.getUint32(132, Endian.little),
        WASIComponentAsyncCopyResult.cancelled().packedResult,
      );
      waitableHost.waitableJoin(handles.readable, 0);
      waitableHost.waitableSetDrop(waitableSet);
      expect(program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('waits for synchronous future read cancel memory events', () async {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final program = _futureU32MemoryCancelHandleProgram(
        host,
        cancelIsAsync: false,
      );
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));

      expect(
        program.invokeWithMemoryEvent(2, memory, <Object?>[
          handles.readable,
          96,
        ]),
        wasiComponentAsyncBlocked,
      );
      await expectLater(
        program.invokeAsync(3, <Object?>[handles.readable]),
        completion(WASIComponentAsyncCopyResult.cancelled().packedResult),
      );

      expect(program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('cancels handle-backed future write memory events', () async {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 610, Endian.little);
      final host = WASIComponentAsyncHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final program = _futureU32MemoryCancelHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handles.writable, waitableSet);

      expect(
        program.invokeWithMemoryEvent(1, memory, <Object?>[
          handles.writable,
          32,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(
        program.invoke(4, <Object?>[handles.writable]),
        wasiComponentAsyncBlocked,
      );

      await expectLater(
        waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
        completion(5),
      );
      expect(data.getUint32(128, Endian.little), handles.writable);
      expect(
        data.getUint32(132, Endian.little),
        WASIComponentAsyncCopyResult.cancelled().packedResult,
      );
      waitableHost.waitableJoin(handles.writable, 0);
      waitableHost.waitableSetDrop(waitableSet);
      expect(program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('waits for synchronous future write cancel memory events', () async {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 610, Endian.little);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final program = _futureU32MemoryCancelHandleProgram(
        host,
        cancelIsAsync: false,
      );
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));

      expect(
        program.invokeWithMemoryEvent(1, memory, <Object?>[
          handles.writable,
          32,
        ]),
        wasiComponentAsyncBlocked,
      );
      await expectLater(
        program.invokeAsync(4, <Object?>[handles.writable]),
        completion(WASIComponentAsyncCopyResult.cancelled().packedResult),
      );

      expect(program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test(
      'publishes dropped handle-backed future write memory events',
      () async {
        final component = WasmComponent.decode(_futureU32TypeComponentBytes());
        expect(component.validate(), isEmpty);
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        data.setUint32(32, 610, Endian.little);
        final host = WASIComponentAsyncHost();
        final waitableHost = WASIComponentWaitableHost(
          table: host.table,
          waitableResolvers: [host.waitableForHandle],
        );
        host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
        final program = _futureU32MemoryHandleProgram(host);
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
        final waitableSet = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(handles.writable, waitableSet);

        expect(
          program.invokeWithMemoryEvent(1, memory, <Object?>[
            handles.writable,
            32,
          ]),
          wasiComponentAsyncBlocked,
        );
        expect(program.invoke(3, <Object?>[handles.readable]), isNull);

        await expectLater(
          waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
          completion(5),
        );
        expect(data.getUint32(128, Endian.little), handles.writable);
        expect(
          data.getUint32(132, Endian.little),
          WASIComponentAsyncCopyStatus.dropped.code,
        );
        waitableHost.waitableJoin(handles.writable, 0);
        waitableHost.waitableSetDrop(waitableSet);
        expect(program.invoke(4, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test('does not cancel completed future read memory events', () async {
      final component = WasmComponent.decode(_futureU32TypeComponentBytes());
      expect(component.validate(), isEmpty);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 987, Endian.little);
      final host = WASIComponentAsyncHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      host.defineFutureTypeFromComponent<int>(component, 0, 'u32-future');
      final program = _futureU32MemoryCancelHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handles.readable, waitableSet);

      expect(
        program.invokeWithMemoryEvent(2, memory, <Object?>[
          handles.readable,
          96,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32]),
        0,
      );
      expect(
        program.invoke(3, <Object?>[handles.readable]),
        wasiComponentAsyncBlocked,
      );

      await expectLater(
        waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
        completion(4),
      );
      expect(data.getUint32(96, Endian.little), 987);
      expect(data.getUint32(128, Endian.little), handles.readable);
      expect(data.getUint32(132, Endian.little), 0);
      waitableHost.waitableJoin(handles.readable, 0);
      waitableHost.waitableSetDrop(waitableSet);
      expect(program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('copies decoded string future values from canonical memory', () {
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
      final bytes = Uint8List.view(memory.buffer);
      final data = ByteData.view(memory.buffer);
      bytes.setAll(96, 'ready'.codeUnits);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 5, Endian.little);

      final result = stringWrite.futureWriteFromMemory(
        stringFuture.writable,
        memory,
        32,
      );

      expect(result.packedResult, 0);
      expect(stringFuture.readable.read(), 'ready');
    });

    test('writes decoded string future reads to canonical memory', () {
      final component = WasmComponent.decode(_futureStringTypeComponentBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<Object>(component, 0, 'strings');
      final program = _futureStringMemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);

      program.invoke(1, <Object?>[handles.writable, 'done']);
      expect(
        program.invokeWithMemory(
          2,
          memory,
          <Object?>[handles.readable, 96],
          realloc: (oldPointer, oldSize, alignment, newSize) {
            expect(oldPointer, 0);
            expect(oldSize, 0);
            expect(alignment, 1);
            expect(newSize, 4);
            return 128;
          },
        ),
        0,
      );
      final data = ByteData.view(memory.buffer);
      expect(data.getUint32(96, Endian.little), 128);
      expect(data.getUint32(100, Endian.little), 4);
      expect(String.fromCharCodes(bytes.sublist(128, 132)), 'done');
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('rejects non-scalar char future values before memory copies', () {
      final component = WasmComponent.decode(_futureCharTypeComponentBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<String>(component, 0, 'char-future');
      final program = _futureU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);

      expect(
        () => program.invoke(1, <Object?>[
          handles.writable,
          String.fromCharCode(0xd800),
        ]),
        throwsStateError,
      );

      expect(program.invoke(1, <Object?>[handles.writable, 'A']), isNull);
      expect(
        program.invokeWithMemory(2, memory, <Object?>[handles.readable, 64]),
        0,
      );
      expect(data.getUint32(64, Endian.little), 0x41);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('copies decoded list future values through canonical memory', () {
      final component = WasmComponent.decode(
        _futureListU32TypeComponentBytes(),
      );
      expect(component.validate(), isEmpty);
      final host = WASIComponentAsyncHost();
      host.defineFutureTypeFromComponent<WasmComponentValueData>(
        component,
        1,
        'u32-lists',
      );
      final program = _futureListU32MemoryHandleProgram(host);
      final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 2, Endian.little);
      data.setUint32(96, 7, Endian.little);
      data.setUint32(100, 8, Endian.little);

      expect(
        program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32]),
        0,
      );
      expect(
        () => program.invokeWithMemory(2, memory, <Object?>[
          handles.readable,
          64,
        ]),
        throwsUnsupportedError,
      );
      expect(
        program.invokeWithMemory(
          2,
          memory,
          <Object?>[handles.readable, 64],
          realloc: (oldPointer, oldSize, alignment, newSize) {
            expect(oldPointer, 0);
            expect(oldSize, 0);
            expect(alignment, 4);
            expect(newSize, 8);
            return 128;
          },
        ),
        0,
      );
      expect(data.getUint32(64, Endian.little), 128);
      expect(data.getUint32(68, Endian.little), 2);
      expect(data.getUint32(128, Endian.little), 7);
      expect(data.getUint32(132, Endian.little), 8);
      expect(program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test(
      'copies decoded string list future values through canonical memory',
      () {
        final component = WasmComponent.decode(
          _futureListStringTypeComponentBytes(),
        );
        expect(component.validate(), isEmpty);
        final host = WASIComponentAsyncHost();
        host.defineFutureTypeFromComponent<WasmComponentValueData>(
          component,
          1,
          'string-lists',
        );
        final program = _futureListStringMemoryHandleProgram(host);
        final handles = _unpackHandles(program.invoke(0, const <Object?>[]));
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final bytes = Uint8List.view(memory.buffer);
        final data = ByteData.view(memory.buffer);
        bytes.setAll(160, 'go'.codeUnits);
        bytes.setAll(176, 'hi'.codeUnits);
        data.setUint32(96, 160, Endian.little);
        data.setUint32(100, 2, Endian.little);
        data.setUint32(104, 176, Endian.little);
        data.setUint32(108, 2, Endian.little);
        data.setUint32(32, 96, Endian.little);
        data.setUint32(36, 2, Endian.little);

        expect(
          program.invokeWithMemory(1, memory, <Object?>[handles.writable, 32]),
          0,
        );
        final allocations = <int>[224, 256, 272];
        expect(
          program.invokeWithMemory(
            2,
            memory,
            <Object?>[handles.readable, 64],
            realloc: (oldPointer, oldSize, alignment, newSize) {
              expect(oldPointer, 0);
              expect(oldSize, 0);
              if (allocations.length == 3) {
                expect(alignment, 4);
                expect(newSize, 16);
              } else {
                expect(alignment, 1);
                expect(newSize, 2);
              }
              return allocations.removeAt(0);
            },
          ),
          0,
        );
        expect(data.getUint32(64, Endian.little), 224);
        expect(data.getUint32(68, Endian.little), 2);
        expect(data.getUint32(224, Endian.little), 256);
        expect(data.getUint32(228, Endian.little), 2);
        expect(data.getUint32(232, Endian.little), 272);
        expect(data.getUint32(236, Endian.little), 2);
        expect(String.fromCharCodes(bytes.sublist(256, 258)), 'go');
        expect(String.fromCharCodes(bytes.sublist(272, 274)), 'hi');
        expect(allocations, isEmpty);
        expect(program.invoke(3, <Object?>[handles.readable]), isNull);
        expect(program.invoke(4, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test('rejects unaligned future memory copies', () {
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
      final memory = Memory(const MemoryDescriptor(initial: 1));

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

    test(
      'validates indexed nested async stream element types before binding',
      () {
        final component = WasmComponent.decode(
          _streamIndexedNestedAsyncElementTypeComponentBytes(),
        );
        final errors = component.validate();

        expect(errors, hasLength(1));
        expect(errors.single.message, contains('nested async'));
        expect(errors.single.message, contains('stream element type'));
      },
    );
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

Uint8List _streamListU32TypeComponentBytes() => Uint8List.fromList(const <int>[
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
  0x79,
  0x66,
  0x01,
  0x00,
]);

Uint8List _streamListStringTypeComponentBytes() =>
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

Uint8List _streamFlagsTypeComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x0c,
  0x02,
  0x6e,
  0x03,
  0x01,
  0x61,
  0x01,
  0x62,
  0x01,
  0x63,
  0x66,
  0x01,
  0x00,
]);

Uint8List _streamOptionU32TypeComponentBytes() =>
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
      0x6b,
      0x79,
      0x66,
      0x01,
      0x00,
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

Uint8List _futureErrorContextTypeComponentBytes() =>
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
      0x04,
      0x01,
      0x65,
      0x01,
      0x64,
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

Uint8List _futureCharTypeComponentBytes() => Uint8List.fromList(const <int>[
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
  0x74,
]);

Uint8List _futureListU32TypeComponentBytes() => Uint8List.fromList(const <int>[
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
  0x79,
  0x65,
  0x01,
  0x00,
]);

Uint8List _futureListStringTypeComponentBytes() =>
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
      0x65,
      0x01,
      0x00,
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

Uint8List _streamErrorContextTypeComponentBytes() =>
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
      0x04,
      0x01,
      0x66,
      0x01,
      0x64,
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

Uint8List _streamIndexedNestedAsyncElementTypeComponentBytes() =>
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
      0x07,
      0x02,
      0x66,
      0x01,
      0x79,
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

WASIComponentCanonicalAsyncHandleProgram _streamU32MemoryHandleProgram(
  WASIComponentAsyncHost host, {
  bool includeCancel = false,
  bool cancelIsAsync = true,
}) {
  return WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 0,
        ),
      ),
      host.bindCanonicalDefinition(
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
      ),
      host.bindCanonicalDefinition(
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
      ),
      if (includeCancel) ...[
        host.bindCanonicalDefinition(
          WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamCancelRead,
            typeIndex: 0,
            isAsync: cancelIsAsync,
          ),
        ),
        host.bindCanonicalDefinition(
          WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamCancelWrite,
            typeIndex: 0,
            isAsync: cancelIsAsync,
          ),
        ),
      ],
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropReadable,
          typeIndex: 0,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropWritable,
          typeIndex: 0,
        ),
      ),
    ],
  );
}

WASIComponentCanonicalAsyncHandleProgram _streamErrorContextMemoryHandleProgram(
  WASIComponentAsyncHost host,
) => _streamU32MemoryHandleProgram(host);

WASIComponentCanonicalAsyncHandleProgram _streamStringMemoryHandleProgram(
  WASIComponentAsyncHost host,
) {
  return WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 0,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 0,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamRead,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.stringEncodingUtf16,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropReadable,
          typeIndex: 0,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropWritable,
          typeIndex: 0,
        ),
      ),
    ],
  );
}

WASIComponentCanonicalAsyncHandleProgram _streamListU32MemoryHandleProgram(
  WASIComponentAsyncHost host,
) {
  return WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamRead,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropReadable,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropWritable,
          typeIndex: 1,
        ),
      ),
    ],
  );
}

WASIComponentCanonicalAsyncHandleProgram _streamListStringMemoryHandleProgram(
  WASIComponentAsyncHost host,
) {
  return WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamRead,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropReadable,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropWritable,
          typeIndex: 1,
        ),
      ),
    ],
  );
}

WASIComponentCanonicalAsyncHandleProgram _streamFlagsMemoryHandleProgram(
  WASIComponentAsyncHost host,
) {
  return WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamRead,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropReadable,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropWritable,
          typeIndex: 1,
        ),
      ),
    ],
  );
}

WASIComponentCanonicalAsyncHandleProgram _streamOptionU32MemoryHandleProgram(
  WASIComponentAsyncHost host,
) {
  return WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamRead,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropReadable,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropWritable,
          typeIndex: 1,
        ),
      ),
    ],
  );
}

WASIComponentCanonicalAsyncHandleProgram _streamU32MemoryCancelHandleProgram(
  WASIComponentAsyncHost host, {
  bool cancelIsAsync = true,
}) => _streamU32MemoryHandleProgram(
  host,
  includeCancel: true,
  cancelIsAsync: cancelIsAsync,
);

WASIComponentCanonicalAsyncHandleProgram _futureU32MemoryHandleProgram(
  WASIComponentAsyncHost host, {
  bool includeCancel = false,
  bool cancelIsAsync = true,
}) {
  return WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureNew,
          typeIndex: 0,
        ),
      ),
      host.bindCanonicalDefinition(
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
      ),
      host.bindCanonicalDefinition(
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
      ),
      if (includeCancel) ...[
        host.bindCanonicalDefinition(
          WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.futureCancelRead,
            typeIndex: 0,
            isAsync: cancelIsAsync,
          ),
        ),
        host.bindCanonicalDefinition(
          WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.futureCancelWrite,
            typeIndex: 0,
            isAsync: cancelIsAsync,
          ),
        ),
      ],
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropReadable,
          typeIndex: 0,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropWritable,
          typeIndex: 0,
        ),
      ),
    ],
  );
}

WASIComponentCanonicalAsyncHandleProgram _futureErrorContextMemoryHandleProgram(
  WASIComponentAsyncHost host,
) => _futureU32MemoryHandleProgram(host);

WASIComponentCanonicalAsyncHandleProgram _futureStringMemoryHandleProgram(
  WASIComponentAsyncHost host,
) {
  return WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureNew,
          typeIndex: 0,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureWrite,
          typeIndex: 0,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureRead,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropReadable,
          typeIndex: 0,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropWritable,
          typeIndex: 0,
        ),
      ),
    ],
  );
}

WASIComponentCanonicalAsyncHandleProgram _futureListU32MemoryHandleProgram(
  WASIComponentAsyncHost host,
) {
  return WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureNew,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureWrite,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureRead,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropReadable,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropWritable,
          typeIndex: 1,
        ),
      ),
    ],
  );
}

WASIComponentCanonicalAsyncHandleProgram _futureListStringMemoryHandleProgram(
  WASIComponentAsyncHost host,
) {
  return WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureNew,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureWrite,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureRead,
          typeIndex: 1,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
          ],
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropReadable,
          typeIndex: 1,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropWritable,
          typeIndex: 1,
        ),
      ),
    ],
  );
}

WASIComponentCanonicalAsyncHandleProgram _futureU32MemoryCancelHandleProgram(
  WASIComponentAsyncHost host, {
  bool cancelIsAsync = true,
}) => _futureU32MemoryHandleProgram(
  host,
  includeCancel: true,
  cancelIsAsync: cancelIsAsync,
);

WASIComponentAsyncEndpointHandles _unpackHandles(Object? packed) {
  final value = packed;
  expect(value, isA<int>());
  return WASIComponentAsyncEndpointHandles.unpack(value as int);
}
