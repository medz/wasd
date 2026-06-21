import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/subtask.dart';
import 'package:wasd/src/wasi/component/waitable_set.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

void main() {
  group('WASIComponentSubtaskHost', () {
    test('returns already resolved subtask states from cancel', () {
      final host = WASIComponentSubtaskHost();
      final subtask = WASIComponentSubtask(
        name: 'returned',
        state: WASIComponentSubtaskState.returned,
      );
      final handle = host.insertSubtask(subtask);
      final cancel = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.subtaskCancel,
          isAsync: true,
        ),
      );
      final drop = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.subtaskDrop,
        ),
      );

      expect(
        cancel.subtaskCancel(handle),
        WASIComponentSubtaskState.returned.code,
      );
      expect(() => cancel.subtaskCancel(handle), throwsStateError);
      expect(() => drop.subtaskDrop(handle), returnsNormally);
      expect(host.table.activeCount, 0);
    });

    test(
      'publishes async cancelled subtask events through waitable sets',
      () async {
        final host = WASIComponentSubtaskHost();
        final waitableHost = WASIComponentWaitableHost(
          table: host.table,
          waitableResolvers: [host.waitableForHandle],
        );
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        final subtask = WASIComponentSubtask(name: 'blocked-cancel');
        final handle = host.insertSubtask(subtask);
        final set = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(handle, set);
        final cancel = host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.subtaskCancel,
            isAsync: true,
          ),
        );
        final drop = host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.subtaskDrop,
          ),
        );

        expect(cancel.subtaskCancel(handle), wasiComponentSubtaskBlocked);
        expect(() => cancel.subtaskCancel(handle), throwsStateError);

        subtask.cancelBeforeStarted();

        await expectLater(
          waitableHost.waitableSetWaitToMemory(set, memory, 64),
          completion(WASIComponentWaitableEventCode.subtask.value),
        );
        expect(data.getUint32(64, Endian.little), handle);
        expect(
          data.getUint32(68, Endian.little),
          WASIComponentSubtaskState.cancelledBeforeStarted.code,
        );
        expect(subtask.resolveDelivered, isTrue);

        waitableHost.waitableJoin(handle, 0);
        waitableHost.waitableSetDrop(set);
        expect(() => drop.subtaskDrop(handle), returnsNormally);
        expect(host.table.activeCount, 0);
      },
    );

    test(
      'keeps started progress separate from async cancellation resolution',
      () async {
        final host = WASIComponentSubtaskHost();
        final waitableHost = WASIComponentWaitableHost(
          table: host.table,
          waitableResolvers: [host.waitableForHandle],
        );
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        final subtask = WASIComponentSubtask(name: 'started-cancel');
        final handle = host.insertSubtask(subtask);
        final set = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(handle, set);
        final cancel = host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.subtaskCancel,
            isAsync: true,
          ),
        );
        final drop = host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.subtaskDrop,
          ),
        );

        subtask.markStarted();

        expect(cancel.subtaskCancel(handle), wasiComponentSubtaskBlocked);
        expect(
          waitableHost.waitableSetPollToMemory(set, memory, 128),
          WASIComponentWaitableEventCode.subtask.value,
        );
        expect(data.getUint32(128, Endian.little), handle);
        expect(
          data.getUint32(132, Endian.little),
          WASIComponentSubtaskState.started.code,
        );

        subtask.cancelBeforeReturned();

        await expectLater(
          waitableHost.waitableSetWaitToMemory(set, memory, 128),
          completion(WASIComponentWaitableEventCode.subtask.value),
        );
        expect(data.getUint32(128, Endian.little), handle);
        expect(
          data.getUint32(132, Endian.little),
          WASIComponentSubtaskState.cancelledBeforeReturned.code,
        );

        waitableHost.waitableJoin(handle, 0);
        waitableHost.waitableSetDrop(set);
        expect(() => drop.subtaskDrop(handle), returnsNormally);
        expect(host.table.activeCount, 0);
      },
    );

    test(
      'waits for non-async subtask cancellation through invokeAsync',
      () async {
        final host = WASIComponentSubtaskHost();
        final subtask = WASIComponentSubtask(name: 'sync-cancel');
        final handle = host.insertSubtask(subtask);
        final program = WASIComponentCanonicalSubtaskProgram(
          operations: [
            host.bindCanonicalDefinition(
              const WasmComponentCanonicalDefinition(
                kind: WasmComponentCanonicalKind.subtaskCancel,
                isAsync: false,
              ),
            ),
            host.bindCanonicalDefinition(
              const WasmComponentCanonicalDefinition(
                kind: WasmComponentCanonicalKind.subtaskDrop,
              ),
            ),
          ],
        );
        var completed = false;

        final pending = program.invokeAsync(0, <Object?>[handle])
          ..then((_) {
            completed = true;
          });
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);
        expect(() => program.invoke(0, <Object?>[handle]), throwsStateError);

        subtask.cancelBeforeStarted();

        await expectLater(
          pending,
          completion(WASIComponentSubtaskState.cancelledBeforeStarted.code),
        );
        expect(completed, isTrue);
        expect(program.invoke(1, <Object?>[handle]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

    test('non-async cancellation waits past started progress', () async {
      final host = WASIComponentSubtaskHost();
      final subtask = WASIComponentSubtask(name: 'sync-started-cancel');
      final handle = host.insertSubtask(subtask);
      final program = WASIComponentCanonicalSubtaskProgram(
        operations: [
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.subtaskCancel,
              isAsync: false,
            ),
          ),
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.subtaskDrop,
            ),
          ),
        ],
      );
      var completed = false;

      subtask.markStarted();

      final pending = program.invokeAsync(0, <Object?>[handle])
        ..then((_) {
          completed = true;
        });
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);

      subtask.cancelBeforeReturned();

      await expectLater(
        pending,
        completion(WASIComponentSubtaskState.cancelledBeforeReturned.code),
      );
      expect(completed, isTrue);
      expect(program.invoke(1, <Object?>[handle]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('rejects starting after cancellation was requested', () {
      final host = WASIComponentSubtaskHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final subtask = WASIComponentSubtask(name: 'cancel-before-start');
      final handle = host.insertSubtask(subtask);
      final set = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handle, set);
      final cancel = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.subtaskCancel,
          isAsync: true,
        ),
      );

      expect(cancel.subtaskCancel(handle), wasiComponentSubtaskBlocked);
      expect(() => subtask.markStarted(), throwsStateError);

      subtask.cancelBeforeStarted();
      expect(
        waitableHost.waitableSetPollToMemory(set, memory, 160),
        WASIComponentWaitableEventCode.subtask.value,
      );
      waitableHost.waitableJoin(handle, 0);
      waitableHost.waitableSetDrop(set);
      expect(() => host.subtaskDrop(handle), returnsNormally);
      expect(host.table.activeCount, 0);
    });

    test('rejects non-async cancellation while joined to a waitable set', () {
      final host = WASIComponentSubtaskHost();
      final waitableHost = WASIComponentWaitableHost(
        table: host.table,
        waitableResolvers: [host.waitableForHandle],
      );
      final subtask = WASIComponentSubtask(
        name: 'joined',
        state: WASIComponentSubtaskState.returned,
      );
      final handle = host.insertSubtask(subtask);
      final set = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(handle, set);
      final cancel = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.subtaskCancel,
          isAsync: false,
        ),
      );

      expect(() => cancel.subtaskCancel(handle), throwsStateError);

      expect(
        waitableHost.waitableSetPollToMemory(
          set,
          Memory(const MemoryDescriptor(initial: 1)),
          96,
        ),
        WASIComponentWaitableEventCode.subtask.value,
      );
      waitableHost.waitableJoin(handle, 0);
      waitableHost.waitableSetDrop(set);
      expect(() => host.subtaskDrop(handle), returnsNormally);
      expect(host.table.activeCount, 0);
    });

    test('binds canonical subtask programs and rejects other definitions', () {
      final host = WASIComponentSubtaskHost();
      final program = WASIComponentCanonicalSubtaskProgram(
        operations: [
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.subtaskCancel,
              isAsync: true,
            ),
          ),
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.subtaskDrop,
            ),
          ),
        ],
      );
      final subtask = WASIComponentSubtask(
        name: 'program-returned',
        state: WASIComponentSubtaskState.returned,
      );
      final handle = host.insertSubtask(subtask);

      expect(
        program.invoke(0, <Object?>[handle]),
        WASIComponentSubtaskState.returned.code,
      );
      expect(program.invoke(1, <Object?>[handle]), isNull);
      expect(host.table.activeCount, 0);
      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.waitableSetNew,
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });
}
