import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/backpressure.dart';
import 'package:wasd/src/wasi/component/resource_table.dart';
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
            taskHost.runWithTaskAsync(
              task,
              () => waitableHost.waitableSetWaitToMemory(
                cancellationSet,
                memory,
                88,
                cancellable: true,
              ),
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
        expect(
          task.cancellationState,
          WASIComponentTaskCancellationState.pending,
        );

        await expectLater(
          pendingCancellation,
          completion(WASIComponentWaitableEventCode.taskCancelled.value),
        );
        expect(cancellationDelivered, isTrue);
        expect(
          task.cancellationState,
          WASIComponentTaskCancellationState.delivered,
        );
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

    test('isolates cancellable polls between task scopes', () {
      final waitableHost = WASIComponentWaitableHost();
      final taskHost = WASIComponentTaskHost(waitableHost: waitableHost);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final set = waitableHost.waitableSetNew();
      final left = taskHost.createTask(name: 'left');
      final right = taskHost.createTask(name: 'right');

      left.requestCancellation();

      expect(
        taskHost.runWithTask(
          right,
          () => waitableHost.waitableSetPollToMemory(
            set,
            memory,
            104,
            cancellable: true,
          ),
        ),
        WASIComponentWaitableEventCode.none.value,
      );
      expect(
        taskHost.runWithTask(
          left,
          () => waitableHost.waitableSetPollToMemory(
            set,
            memory,
            104,
            cancellable: true,
          ),
        ),
        WASIComponentWaitableEventCode.taskCancelled.value,
      );
      expect(
        left.cancellationState,
        WASIComponentTaskCancellationState.delivered,
      );

      waitableHost.waitableSetDrop(set);
    });

    test('isolates concurrent cancellable waits between task zones', () async {
      final waitableHost = WASIComponentWaitableHost();
      final taskHost = WASIComponentTaskHost(waitableHost: waitableHost);
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final leftSet = waitableHost.waitableSetNew();
      final rightSet = waitableHost.waitableSetNew();
      final left = taskHost.createTask(name: 'left');
      final right = taskHost.createTask(name: 'right');
      var rightCompleted = false;

      final leftWait = taskHost.runWithTaskAsync(
        left,
        () => waitableHost.waitableSetWaitToMemory(
          leftSet,
          memory,
          112,
          cancellable: true,
        ),
      );
      final rightWait =
          taskHost.runWithTaskAsync(
            right,
            () => waitableHost.waitableSetWaitToMemory(
              rightSet,
              memory,
              120,
              cancellable: true,
            ),
          )..then((_) {
            rightCompleted = true;
          });
      await Future<void>.delayed(Duration.zero);

      left.requestCancellation();

      await expectLater(
        leftWait,
        completion(WASIComponentWaitableEventCode.taskCancelled.value),
      );
      expect(rightCompleted, isFalse);

      right.requestCancellation();
      await expectLater(
        rightWait,
        completion(WASIComponentWaitableEventCode.taskCancelled.value),
      );
      waitableHost.waitableSetDrop(leftSet);
      waitableHost.waitableSetDrop(rightSet);
    });

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
      expect(
        task.cancellationState,
        WASIComponentTaskCancellationState.pending,
      );

      expect(
        () => taskHost.runWithTask(task, taskHost.taskCancel),
        throwsStateError,
      );

      task.deliverCancellation();
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
      rightTask.deliverCancellation();

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

    test('cancels before entering guest code under backpressure', () async {
      final backpressure = WASIComponentBackpressure()..increment();
      final task = WASIComponentTask(name: 'blocked-entry');
      final entry = task.enter(backpressure);

      await Future<void>.delayed(Duration.zero);
      task.requestCancellation();

      await expectLater(entry, completion(isFalse));
      expect(task.state, WASIComponentTaskState.cancelled);
      expect(
        task.cancellationState,
        WASIComponentTaskCancellationState.delivered,
      );

      backpressure.decrement();
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

    test('returns direct canonical string scalars without pre-lifting', () {
      final host = WASIComponentTaskHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      bytes.setAll(96, 'done'.codeUnits);
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
      final indirectTask = host.createTask(name: 'invalid-indirect-task');

      host.runWithTask(indirectTask, () {
        expect(
          () => program.invokeWithMemory(0, memory, const <Object?>[32]),
          throwsStateError,
        );
      });
      expect(indirectTask.state, WASIComponentTaskState.created);

      final task = host.createTask(name: 'direct-result-task');

      host.runWithTask(task, () {
        expect(program.invoke(0, const <Object?>[96, 4]), isNull);
      });

      expect(task.state, WASIComponentTaskState.returned);
      expect(task.result, const <Object?>[96, 4]);
    });

    test('returns direct type-indexed scalars without pre-lifting', () {
      final host = WASIComponentTaskHost();
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
        expect(program.invoke(0, const <Object?>[7, 9]), isNull);
      });

      expect(task.result, const <Object?>[7, 9]);
    });

    test('returns one pointer for canonical results wider than 16 scalars', () {
      final host = WASIComponentTaskHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final tupleType = WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.definedValue,
        definedValue: WasmComponentDefinedValueType(
          kind: WasmComponentDefinedValueTypeKind.tuple,
          types: List<WasmComponentValueType>.filled(
            17,
            const WasmComponentValueType.primitive(
              WasmComponentPrimitiveValueType.u32,
            ),
          ),
        ),
      );
      final operation = host.bindCanonicalDefinition(
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
        typeDefinitions: [tupleType],
      );
      final program = WASIComponentCanonicalTaskProgram(
        operations: [operation],
      );
      final task = host.createTask(name: 'indirect-result-task');

      expect(operation.resultFlatLength, 17);
      host.runWithTask(task, () {
        expect(
          program.invokeWithMemory(0, memory, const <Object?>[32]),
          isNull,
        );
      });

      expect(task.result, 32);
    });

    test('normalizes indirect task return pointers to canonical u32', () {
      final host = WASIComponentTaskHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final tupleType = WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.definedValue,
        definedValue: WasmComponentDefinedValueType(
          kind: WasmComponentDefinedValueTypeKind.tuple,
          types: List<WasmComponentValueType>.filled(
            17,
            const WasmComponentValueType.primitive(
              WasmComponentPrimitiveValueType.u32,
            ),
          ),
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
            typeDefinitions: [tupleType],
          ),
        ],
      );
      final signedTask = host.createTask(name: 'signed-pointer-task');
      final wideTask = host.createTask(name: 'wide-pointer-task');

      host.runWithTask(signedTask, () {
        program.invokeWithMemory(0, memory, const <Object?>[-2147483648]);
      });
      host.runWithTask(wideTask, () {
        program.invokeWithMemory(0, memory, const <Object?>[0x100000020]);
      });

      expect(signedTask.result, 0x80000000);
      expect(wideTask.result, 32);
    });

    test('rejects a task return result without a canonical flat layout', () {
      final host = WASIComponentTaskHost();

      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.taskReturn,
            result: WasmComponentCanonicalResult.value(
              WasmComponentValueType.typeIndex(0),
            ),
          ),
        ),
        throwsUnsupportedError,
      );
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
          borrowed.deliverCancellation();
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

    test('tracks canonical borrow handles by their original task', () {
      final table = WASIComponentResourceTable();
      final taskHost = WASIComponentTaskHost();
      final dropped = <int>[];
      final resourceType = table.defineType<int>(
        'resource',
        onDrop: dropped.add,
      );
      final owned = table.insert<int>(resourceType, 42);

      final waiting = WASIComponentTask(name: 'waiting');
      waiting.markStarted();
      final waitingBorrow = table.insertBorrowHandle(owned, waiting);
      final other = WASIComponentTask(name: 'other');
      other.markStarted();
      taskHost.runWithTask(
        other,
        () => table.dropNamed('resource', waitingBorrow),
      );
      expect(waiting.borrowCount, 0);
      expect(other.borrowCount, 0);
      waiting.returnResult();
      other.returnResult();

      final waitingAgain = WASIComponentTask(name: 'waiting-again');
      waitingAgain.markStarted();
      final otherBorrow = table.insertBorrowHandle(owned, waitingAgain);
      final self = WASIComponentTask(name: 'self');
      self.markStarted();
      final selfBorrow = table.insertBorrowHandle(owned, self);
      taskHost.runWithTask(self, () {
        table.drop<int>(resourceType, otherBorrow);
        table.dropNamed('resource', selfBorrow);
        self.returnResult();
      });
      expect(waitingAgain.borrowCount, 0);
      expect(self.borrowCount, 0);
      waitingAgain.returnResult();

      final finalWaiting = WASIComponentTask(name: 'final-waiting');
      finalWaiting.markStarted();
      final finalOtherBorrow = table.insertBorrowHandle(owned, finalWaiting);
      final wrong = WASIComponentTask(name: 'wrong');
      wrong.markStarted();
      final wrongBorrow = table.insertBorrowHandle(owned, wrong);
      taskHost.runWithTask(wrong, () {
        table.drop<int>(resourceType, finalOtherBorrow);
        expect(() => wrong.returnResult(), throwsStateError);
      });
      expect(finalWaiting.borrowCount, 0);
      expect(wrong.borrowCount, 1);
      finalWaiting.returnResult();
      table.drop<int>(resourceType, wrongBorrow);
      wrong.returnResult();

      final cancelled = WASIComponentTask(name: 'cancelled');
      cancelled.markStarted();
      final cancelledBorrow = table.insertBorrowHandle(owned, cancelled);
      cancelled.requestCancellation();
      cancelled.deliverCancellation();
      expect(() => cancelled.cancel(), throwsStateError);
      table.drop<int>(resourceType, cancelledBorrow);
      cancelled.cancel();
      expect(cancelled.state, WASIComponentTaskState.cancelled);

      expect(table.contains(owned), isTrue);
      expect(table.get<int>(resourceType, owned), 42);
      expect(dropped, isEmpty);
      table.drop<int>(resourceType, owned);
      expect(dropped, [42]);
    });

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
