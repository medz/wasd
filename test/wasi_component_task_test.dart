import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/subtask.dart';
import 'package:wasd/src/wasi/component/task.dart';
import 'package:wasd/src/wasi/component/waitable_set.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

void main() {
  group('WASIComponentTaskHost', () {
    test('returns through a caller subtask', () {
      final subtaskHost = WASIComponentSubtaskHost();
      final waitableHost = WASIComponentWaitableHost(
        table: subtaskHost.table,
        waitableResolvers: [subtaskHost.waitableForHandle],
      );
      final taskHost = WASIComponentTaskHost(waitableHost: waitableHost);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final subtask = WASIComponentSubtask(name: 'caller-subtask');
      final subtaskHandle = subtaskHost.insertSubtask(subtask);
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(subtaskHandle, waitableSet);
      final task = taskHost.createTask(name: 'callee-task', subtask: subtask);
      final program = WASIComponentCanonicalTaskProgram(
        operations: [
          taskHost.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.taskReturn,
              result: WasmComponentCanonicalResult.value(
                WasmComponentValueType.primitive(
                  WasmComponentPrimitiveValueType.u32,
                ),
              ),
            ),
          ),
        ],
      );

      taskHost.runWithTask(task, () {
        expect(program.invoke(0, <Object?>[42]), isNull);
      });

      expect(task.state, WASIComponentTaskState.returned);
      expect(task.result, 42);
      expect(subtask.hasResult, isTrue);
      expect(subtask.result, 42);
      expect(
        waitableHost.waitableSetPollToMemory(waitableSet, memory, 64),
        WASIComponentWaitableEventCode.subtask.value,
      );
      expect(data.getUint32(64, Endian.little), subtaskHandle);
      expect(
        data.getUint32(68, Endian.little),
        WASIComponentSubtaskState.returned.code,
      );

      waitableHost.waitableJoin(subtaskHandle, 0);
      waitableHost.waitableSetDrop(waitableSet);
      subtaskHost.subtaskDrop(subtaskHandle);
      expect(subtaskHost.table.activeCount, 0);
    });

    test(
      'bridges subtask cancellation to cancellable waits and task.cancel',
      () async {
        final subtaskHost = WASIComponentSubtaskHost();
        final waitableHost = WASIComponentWaitableHost(
          table: subtaskHost.table,
          waitableResolvers: [subtaskHost.waitableForHandle],
        );
        final taskHost = WASIComponentTaskHost(waitableHost: waitableHost);
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        final subtask = WASIComponentSubtask(name: 'cancelled-subtask');
        final subtaskHandle = subtaskHost.insertSubtask(subtask);
        final subtaskSet = waitableHost.waitableSetNew();
        final cancellationSet = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(subtaskHandle, subtaskSet);
        final task = taskHost.createTask(
          name: 'cancelled-task',
          subtask: subtask,
        );
        final subtaskCancel = subtaskHost.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.subtaskCancel,
            isAsync: true,
          ),
        );
        final program = WASIComponentCanonicalTaskProgram(
          operations: [
            taskHost.bindCanonicalDefinition(
              const WasmComponentCanonicalDefinition(
                kind: WasmComponentCanonicalKind.taskReturn,
                result: WasmComponentCanonicalResult.none(),
              ),
            ),
            taskHost.bindCanonicalDefinition(
              const WasmComponentCanonicalDefinition(
                kind: WasmComponentCanonicalKind.taskCancel,
              ),
            ),
          ],
        );
        var cancellationDelivered = false;

        task.markStarted();
        expect(
          waitableHost.waitableSetPollToMemory(subtaskSet, memory, 80),
          WASIComponentWaitableEventCode.subtask.value,
        );
        expect(
          data.getUint32(84, Endian.little),
          WASIComponentSubtaskState.started.code,
        );

        final pendingCancellation =
            waitableHost.waitableSetWaitToMemory(
              cancellationSet,
              memory,
              88,
              cancellable: true,
            )..then((_) {
              cancellationDelivered = true;
            });
        await Future<void>.delayed(Duration.zero);

        expect(cancellationDelivered, isFalse);
        expect(
          subtaskCancel.subtaskCancel(subtaskHandle),
          wasiComponentSubtaskBlocked,
        );
        expect(task.cancellationRequested, isTrue);

        await expectLater(
          pendingCancellation,
          completion(WASIComponentWaitableEventCode.taskCancelled.value),
        );
        expect(cancellationDelivered, isTrue);
        expect(data.getUint32(88, Endian.little), 0);
        expect(data.getUint32(92, Endian.little), 0);

        taskHost.runWithTask(task, () {
          expect(program.invoke(1, const <Object?>[]), isNull);
        });
        expect(task.state, WASIComponentTaskState.cancelled);

        await expectLater(
          waitableHost.waitableSetWaitToMemory(subtaskSet, memory, 96),
          completion(WASIComponentWaitableEventCode.subtask.value),
        );
        expect(data.getUint32(96, Endian.little), subtaskHandle);
        expect(
          data.getUint32(100, Endian.little),
          WASIComponentSubtaskState.cancelledBeforeReturned.code,
        );

        waitableHost.waitableJoin(subtaskHandle, 0);
        waitableHost.waitableSetDrop(subtaskSet);
        waitableHost.waitableSetDrop(cancellationSet);
        subtaskHost.subtaskDrop(subtaskHandle);
        expect(subtaskHost.table.activeCount, 0);
      },
    );

    test('preserves existing subtask cancellation listeners', () {
      final subtaskHost = WASIComponentSubtaskHost();
      final waitableHost = WASIComponentWaitableHost(
        table: subtaskHost.table,
        waitableResolvers: [subtaskHost.waitableForHandle],
      );
      final taskHost = WASIComponentTaskHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      var schedulerObservedCancellation = false;
      final subtask = WASIComponentSubtask(
        name: 'observed-subtask',
        onCancel: (_) {
          schedulerObservedCancellation = true;
        },
      );
      final subtaskHandle = subtaskHost.insertSubtask(subtask);
      final waitableSet = waitableHost.waitableSetNew();
      waitableHost.waitableJoin(subtaskHandle, waitableSet);
      final task = taskHost.createTask(name: 'observed-task', subtask: subtask);
      final subtaskCancel = subtaskHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.subtaskCancel,
          isAsync: true,
        ),
      );
      final subtaskDrop = subtaskHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.subtaskDrop,
        ),
      );

      expect(
        subtaskCancel.subtaskCancel(subtaskHandle),
        wasiComponentSubtaskBlocked,
      );
      expect(schedulerObservedCancellation, isTrue);
      expect(task.cancellationRequested, isTrue);

      taskHost.runWithTask(task, taskHost.taskCancel);
      expect(task.state, WASIComponentTaskState.cancelled);
      expect(subtask.state, WASIComponentSubtaskState.cancelledBeforeStarted);

      expect(
        waitableHost.waitableSetPollToMemory(waitableSet, memory, 112),
        WASIComponentWaitableEventCode.subtask.value,
      );
      waitableHost.waitableJoin(subtaskHandle, 0);
      waitableHost.waitableSetDrop(waitableSet);
      expect(() => subtaskDrop.subtaskDrop(subtaskHandle), returnsNormally);
      expect(subtaskHost.table.activeCount, 0);
    });

    test('rejects task operations without a current task', () {
      final host = WASIComponentTaskHost();
      final returnOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.taskReturn,
          result: WasmComponentCanonicalResult.none(),
        ),
      );
      final cancelOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.taskCancel,
        ),
      );

      expect(() => returnOperation.taskReturn(), throwsStateError);
      expect(() => cancelOperation.taskCancel(), throwsStateError);
    });

    test('keeps overlapping async tasks isolated', () async {
      final host = WASIComponentTaskHost();
      final returnOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.taskReturn,
          result: WasmComponentCanonicalResult.value(
            WasmComponentValueType.primitive(
              WasmComponentPrimitiveValueType.u32,
            ),
          ),
        ),
      );
      final cancelOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.taskCancel,
        ),
      );
      final leftTask = host.createTask(name: 'left-task');
      final rightTask = host.createTask(name: 'right-task');
      final leftEntered = Completer<void>();
      final releaseLeft = Completer<void>();
      final rightEntered = Completer<void>();
      final releaseRight = Completer<void>();

      rightTask.markStarted();
      rightTask.requestCancellation();

      final leftResult = host.runWithTaskAsync(leftTask, () async {
        expect(host.currentTask, same(leftTask));
        leftEntered.complete();
        await releaseLeft.future;
        expect(host.currentTask, same(leftTask));
        returnOperation.taskReturn(result: 7);
        return host.currentTask;
      });
      await leftEntered.future;

      final rightResult = host.runWithTaskAsync(rightTask, () async {
        expect(host.currentTask, same(rightTask));
        rightEntered.complete();
        await releaseRight.future;
        expect(host.currentTask, same(rightTask));
        cancelOperation.taskCancel();
        return host.currentTask;
      });
      await rightEntered.future;

      try {
        releaseLeft.complete();
        expect(await leftResult, same(leftTask));
      } finally {
        if (!releaseRight.isCompleted) {
          releaseRight.complete();
        }
      }
      expect(await rightResult, same(rightTask));
      expect(host.currentTask, isNull);
      expect(leftTask.state, WASIComponentTaskState.returned);
      expect(leftTask.result, 7);
      expect(rightTask.state, WASIComponentTaskState.cancelled);
    });

    test('lets synchronous task scopes override async current tasks', () async {
      final host = WASIComponentTaskHost();
      final outer = host.createTask(name: 'outer-task');
      final nested = host.createTask(name: 'nested-task');

      await host.runWithTaskAsync(outer, () async {
        expect(host.currentTask, same(outer));

        final nestedResult = host.runWithTask(nested, () {
          return host.currentTask;
        });

        expect(nestedResult, same(nested));
        expect(host.currentTask, same(outer));
      });

      expect(host.currentTask, isNull);
    });

    test('returns canonical memory-backed values', () {
      final host = WASIComponentTaskHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final data = ByteData.view(memory.buffer);
      bytes.setAll(96, 'done'.codeUnits);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 4, Endian.little);
      final program = WASIComponentCanonicalTaskProgram(
        operations: [
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.taskReturn,
              result: WasmComponentCanonicalResult.value(
                WasmComponentValueType.primitive(
                  WasmComponentPrimitiveValueType.string,
                ),
              ),
              options: [
                WasmComponentCanonicalOption(
                  kind: WasmComponentCanonicalOptionKind.stringEncodingUtf8,
                ),
                WasmComponentCanonicalOption(
                  kind: WasmComponentCanonicalOptionKind.memory,
                  index: 0,
                ),
              ],
            ),
          ),
        ],
      );
      final task = host.createTask(name: 'memory-result-task');

      host.runWithTask(task, () {
        expect(
          program.invokeWithMemory(0, memory, const <Object?>[32]),
          isNull,
        );
      });

      expect(task.state, WASIComponentTaskState.returned);
      expect(task.result, 'done');
      expect(
        () => program.invokeWithMemory(0, memory, const <Object?>[]),
        throwsStateError,
      );
    });

    test('returns type-indexed canonical memory values', () {
      final host = WASIComponentTaskHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 7, Endian.little);
      data.setUint32(36, 9, Endian.little);
      final recordType = WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.definedValue,
        definedValue: WasmComponentDefinedValueType(
          kind: WasmComponentDefinedValueTypeKind.record,
          fields: [
            WasmComponentLabeledValueType(
              label: 'left',
              type: WasmComponentValueType.primitive(
                WasmComponentPrimitiveValueType.u32,
              ),
            ),
            WasmComponentLabeledValueType(
              label: 'right',
              type: WasmComponentValueType.primitive(
                WasmComponentPrimitiveValueType.u32,
              ),
            ),
          ],
        ),
      );
      final program = WASIComponentCanonicalTaskProgram(
        operations: [
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.taskReturn,
              result: WasmComponentCanonicalResult.value(
                WasmComponentValueType.typeIndex(0),
              ),
              options: [
                WasmComponentCanonicalOption(
                  kind: WasmComponentCanonicalOptionKind.memory,
                  index: 0,
                ),
              ],
            ),
            typeDefinitions: [recordType],
          ),
        ],
      );
      final task = host.createTask(name: 'record-result-task');

      host.runWithTask(task, () {
        expect(
          program.invokeWithMemory(0, memory, const <Object?>[32]),
          isNull,
        );
      });

      final result = task.result as WasmComponentValueData;
      expect(result.kind, WasmComponentValueDataKind.record);
      expect(result.items.map((item) => item.integer), [7, 9]);
    });

    test(
      'validates return arity, cancellation request, and active borrows',
      () {
        final host = WASIComponentTaskHost();
        final noResultProgram = WASIComponentCanonicalTaskProgram(
          operations: [
            host.bindCanonicalDefinition(
              const WasmComponentCanonicalDefinition(
                kind: WasmComponentCanonicalKind.taskReturn,
                result: WasmComponentCanonicalResult.none(),
              ),
            ),
          ],
        );
        final resultProgram = WASIComponentCanonicalTaskProgram(
          operations: [
            host.bindCanonicalDefinition(
              const WasmComponentCanonicalDefinition(
                kind: WasmComponentCanonicalKind.taskReturn,
                result: WasmComponentCanonicalResult.value(
                  WasmComponentValueType.primitive(
                    WasmComponentPrimitiveValueType.string,
                  ),
                ),
              ),
            ),
          ],
        );
        final cancelProgram = WASIComponentCanonicalTaskProgram(
          operations: [
            host.bindCanonicalDefinition(
              const WasmComponentCanonicalDefinition(
                kind: WasmComponentCanonicalKind.taskCancel,
              ),
            ),
          ],
        );

        host.runWithTask(WASIComponentTask(name: 'arity'), () {
          expect(
            () => noResultProgram.invoke(0, <Object?>['unexpected']),
            throwsStateError,
          );
          expect(
            () => resultProgram.invoke(0, const <Object?>[]),
            throwsStateError,
          );
        });

        host.runWithTask(WASIComponentTask(name: 'cancel-without-request'), () {
          expect(
            () => cancelProgram.invoke(0, const <Object?>[]),
            throwsStateError,
          );
        });

        final borrowed = WASIComponentTask(name: 'borrowed');
        borrowed.addBorrow();
        host.runWithTask(borrowed, () {
          expect(
            () => noResultProgram.invoke(0, const <Object?>[]),
            throwsStateError,
          );
          borrowed.requestCancellation();
          expect(
            () => cancelProgram.invoke(0, const <Object?>[]),
            throwsStateError,
          );
        });
        borrowed.releaseBorrow();
        host.runWithTask(borrowed, () {
          expect(noResultProgram.invoke(0, const <Object?>[]), isNull);
        });
        expect(borrowed.state, WASIComponentTaskState.returned);
        expect(borrowed.hasResult, isFalse);
        expect(() => borrowed.result, throwsStateError);
      },
    );

    test('rejects non-task canonical definitions', () {
      final host = WASIComponentTaskHost();

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
