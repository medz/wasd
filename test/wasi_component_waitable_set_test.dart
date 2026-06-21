import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/waitable_set.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

void main() {
  group('WASIComponentWaitableHost', () {
    test('polls pending waitable events into canonical memory', () {
      final host = WASIComponentWaitableHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final set = host.waitableSetNew();
      final waitable = WASIComponentWaitable('stream-read');
      final waitableHandle = host.insertWaitable(waitable);
      host.waitableJoin(waitableHandle, set);

      expect(host.waitableSetPollToMemory(set, memory, 16), 0);
      expect(data.getUint32(16, Endian.little), 0);
      expect(data.getUint32(20, Endian.little), 0);

      waitable.setPendingEvent(
        () => const WASIComponentWaitableEvent(
          code: WASIComponentWaitableEventCode.streamRead,
          payload1: 7,
          payload2: 2 << 4,
        ),
      );

      expect(host.waitableSetPollToMemory(set, memory, 16), 2);
      expect(data.getUint32(16, Endian.little), 7);
      expect(data.getUint32(20, Endian.little), 2 << 4);
      expect(host.waitableSetPollToMemory(set, memory, 24), 0);

      host.waitableJoin(waitableHandle, 0);
      host.waitableSetDrop(set);
      host.dropWaitable(waitableHandle);
      expect(host.table.activeCount, 0);
    });

    test('waits for pending waitable events', () async {
      final host = WASIComponentWaitableHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final set = host.waitableSetNew();
      final waitable = WASIComponentWaitable('future-write');
      final waitableHandle = host.insertWaitable(waitable);
      host.waitableJoin(waitableHandle, set);
      var completed = false;

      final pending = host.waitableSetWaitToMemory(set, memory, 32)
        ..then((_) {
          completed = true;
        });
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);
      expect(() => host.waitableSetDrop(set), throwsStateError);

      waitable.setPendingEvent(
        () => const WASIComponentWaitableEvent(
          code: WASIComponentWaitableEventCode.futureWrite,
          payload1: 11,
          payload2: 0,
        ),
      );

      await expectLater(pending, completion(5));
      expect(completed, isTrue);
      expect(data.getUint32(32, Endian.little), 11);
      expect(data.getUint32(36, Endian.little), 0);

      host.waitableJoin(waitableHandle, 0);
      host.waitableSetDrop(set);
      host.dropWaitable(waitableHandle);
      expect(host.table.activeCount, 0);
    });

    test('transfers waitables between sets and removes them with zero', () {
      final host = WASIComponentWaitableHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final firstSet = host.waitableSetNew();
      final secondSet = host.waitableSetNew();
      final waitable = WASIComponentWaitable('subtask');
      final waitableHandle = host.insertWaitable(waitable);

      host.waitableJoin(waitableHandle, firstSet);
      host.waitableJoin(waitableHandle, secondSet);
      waitable.setPendingEvent(
        () => const WASIComponentWaitableEvent(
          code: WASIComponentWaitableEventCode.subtask,
          payload1: 3,
          payload2: 4,
        ),
      );

      expect(host.waitableSetPollToMemory(firstSet, memory, 0), 0);
      expect(host.waitableSetPollToMemory(secondSet, memory, 0), 1);

      host.waitableJoin(waitableHandle, 0);
      host.waitableSetDrop(firstSet);
      host.waitableSetDrop(secondSet);
      host.dropWaitable(waitableHandle);
      expect(host.table.activeCount, 0);
    });

    test('rejects dropping non-empty sets or pending waitables', () {
      final host = WASIComponentWaitableHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final set = host.waitableSetNew();
      final waitable = WASIComponentWaitable('stream-write');
      final waitableHandle = host.insertWaitable(waitable);
      host.waitableJoin(waitableHandle, set);

      expect(() => host.waitableSetDrop(set), throwsStateError);

      host.waitableJoin(waitableHandle, 0);
      waitable.setPendingEvent(
        () => const WASIComponentWaitableEvent(
          code: WASIComponentWaitableEventCode.streamWrite,
          payload1: 5,
          payload2: 1 << 4,
        ),
      );

      expect(() => host.dropWaitable(waitableHandle), throwsStateError);
      host.waitableJoin(waitableHandle, set);
      expect(host.waitableSetPollToMemory(set, memory, 0), 3);
      host.waitableJoin(waitableHandle, 0);
      host.dropWaitable(waitableHandle);
      host.waitableSetDrop(set);
      expect(host.table.activeCount, 0);
    });

    test('rejects joining a synchronously waited waitable', () async {
      final host = WASIComponentWaitableHost();
      final set = host.waitableSetNew();
      final waitable = WASIComponentWaitable('future-read');
      final waitableHandle = host.insertWaitable(waitable);
      final started = Completer<void>();
      final release = Completer<void>();

      final pending = waitable.withSyncWaiter<void>(() {
        started.complete();
        return release.future;
      });
      await started.future;

      expect(() => host.waitableJoin(waitableHandle, set), throwsStateError);

      release.complete();
      await pending;
      host.waitableSetDrop(set);
      host.dropWaitable(waitableHandle);
      expect(host.table.activeCount, 0);
    });
  });

  group('WASIComponentCanonicalWaitableProgram', () {
    test('invokes canonical waitable definitions by index', () async {
      final host = WASIComponentWaitableHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final component = WasmComponent.decode(_waitableProgramBytes());
      expect(
        component.canonicalDefinitions.map((definition) => definition.kind),
        <WasmComponentCanonicalKind>[
          WasmComponentCanonicalKind.waitableSetNew,
          WasmComponentCanonicalKind.waitableSetWait,
          WasmComponentCanonicalKind.waitableSetPoll,
          WasmComponentCanonicalKind.waitableSetDrop,
          WasmComponentCanonicalKind.waitableJoin,
        ],
      );
      final program = host.bindCanonicalDefinitions(component);

      final set = program.invoke(0, const <Object?>[]);
      expect(set, isA<int>());
      final setHandle = set! as int;
      final waitable = WASIComponentWaitable('future-read');
      final waitableHandle = host.insertWaitable(waitable);

      expect(program.invoke(4, <Object?>[waitableHandle, setHandle]), isNull);
      expect(program.invokeWithMemory(2, memory, <Object?>[setHandle, 64]), 0);

      final pending = program.invokeWithMemoryAsync(1, memory, <Object?>[
        setHandle,
        64,
      ]);
      await Future<void>.delayed(Duration.zero);
      waitable.setPendingEvent(
        () => const WASIComponentWaitableEvent(
          code: WASIComponentWaitableEventCode.futureRead,
          payload1: 9,
          payload2: 0,
        ),
      );

      await expectLater(pending, completion(4));
      expect(data.getUint32(64, Endian.little), 9);
      expect(data.getUint32(68, Endian.little), 0);
      expect(program.invoke(4, <Object?>[waitableHandle, 0]), isNull);
      expect(program.invoke(3, <Object?>[setHandle]), isNull);
      host.dropWaitable(waitableHandle);
      expect(host.table.activeCount, 0);
    });

    test('rejects non-waitable canonical definitions', () {
      final host = WASIComponentWaitableHost();

      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamNew,
            typeIndex: 0,
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });
}

Uint8List _waitableProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x08,
  0x0a,
  0x05,
  0x1f,
  0x20,
  0x00,
  0x00,
  0x21,
  0x00,
  0x00,
  0x22,
  0x23,
]);
