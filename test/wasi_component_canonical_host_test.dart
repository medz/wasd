import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/subtask.dart';
import 'package:wasd/src/wasi/component/task.dart';
import 'package:wasd/src/wasi/component/waitable_set.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

void main() {
  group('WASIComponentCanonicalHost', () {
    test('invokes mixed canonical operations by canonical index', () {
      final host = WASIComponentCanonicalHost(availableParallelism: 3);
      final dropped = <int>[];
      host.resourceHost.defineResourceType<int>(
        0,
        'descriptor',
        onDrop: dropped.add,
      );
      final program = host.bindCanonicalDefinitions(const [
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.resourceNew,
          typeIndex: 0,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.resourceRep,
          typeIndex: 0,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextSet,
          contextIndex: 0,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextGet,
          contextIndex: 0,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadIndex,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadAvailableParallelism,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDebugMessage,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDrop,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.resourceDrop,
          typeIndex: 0,
        ),
      ]);

      expect(program.operations.map((operation) => operation.kind), [
        WasmComponentCanonicalKind.resourceNew,
        WasmComponentCanonicalKind.resourceRep,
        WasmComponentCanonicalKind.contextSet,
        WasmComponentCanonicalKind.contextGet,
        WasmComponentCanonicalKind.threadIndex,
        WasmComponentCanonicalKind.threadAvailableParallelism,
        WasmComponentCanonicalKind.errorContextNew,
        WasmComponentCanonicalKind.errorContextDebugMessage,
        WasmComponentCanonicalKind.errorContextDrop,
        WasmComponentCanonicalKind.resourceDrop,
      ]);

      final resource = program.invoke(0, <Object?>[77]);

      expect(program.invoke(1, <Object?>[resource]), 77);
      expect(program.invoke(2, <Object?>[1234]), isNull);
      expect(program.invoke(3, const <Object?>[]), 1234);
      expect(program.invoke(4, const <Object?>[]), 0);
      expect(program.invoke(5, const <Object?>[]), 3);

      final errorContext = program.invoke(6, <Object?>['bad descriptor']);

      expect(program.invoke(7, <Object?>[errorContext]), 'bad descriptor');
      expect(program.invoke(8, <Object?>[errorContext]), isNull);
      expect(program.invoke(9, <Object?>[resource]), isNull);
      expect(dropped, [77]);
      expect(() => program.invoke(10, const <Object?>[]), throwsStateError);
    });

    test('invokes error-context operations through canonical memory', () {
      final host = WASIComponentCanonicalHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final data = ByteData.view(memory.buffer);
      bytes.setAll(32, 'component failed'.codeUnits);
      final program = host.bindCanonicalDefinitions(const [
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDebugMessage,
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
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDrop,
        ),
      ]);

      final handle = program.invokeWithMemory(0, memory, const <Object?>[
        32,
        16,
      ]);
      expect(
        program.invokeWithMemory(
          1,
          memory,
          <Object?>[handle],
          resultPointer: 64,
          realloc: (oldPointer, oldSize, alignment, newSize) {
            expect(oldPointer, 0);
            expect(oldSize, 0);
            expect(alignment, 1);
            expect(newSize, 16);
            return 128;
          },
        ),
        isNotNull,
      );
      expect(data.getUint32(64, Endian.little), 128);
      expect(data.getUint32(68, Endian.little), 16);
      expect(String.fromCharCodes(bytes.sublist(128, 144)), 'component failed');
      expect(program.invokeWithMemory(2, memory, <Object?>[handle]), isNull);
      expect(() => program.invoke(1, <Object?>[handle]), throwsStateError);
    });

    test('invokes direct task.return through canonical flat scalars', () {
      final host = WASIComponentCanonicalHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      bytes.setAll(96, 'task'.codeUnits);
      final task = host.taskHost.createTask(name: 'canonical-task');
      final program = host.bindCanonicalDefinitions(const [
        WasmComponentCanonicalDefinition(
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
      ]);

      host.taskHost.runWithTask(task, () {
        expect(program.invoke(0, const <Object?>[96, 4]), isNull);
      });

      expect(task.state, WASIComponentTaskState.returned);
      expect(task.result, const <Object?>[96, 4]);
    });

    test('shares table and waitable resolvers across component hosts', () {
      final host = WASIComponentCanonicalHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final subtask = WASIComponentSubtask(name: 'caller-subtask');
      final subtaskHandle = host.subtaskHost.insertSubtask(subtask);
      final program = host.bindCanonicalDefinitions(const [
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.waitableSetNew,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.waitableJoin,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.waitableSetPoll,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.waitableSetDrop,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.subtaskDrop,
        ),
      ]);
      final waitableSet = program.invoke(0, const <Object?>[])! as int;

      expect(program.invoke(1, <Object?>[subtaskHandle, waitableSet]), isNull);

      subtask.markReturned(result: 42, hasResult: true);

      expect(
        program.invokeWithMemory(2, memory, <Object?>[waitableSet, 64]),
        WASIComponentWaitableEventCode.subtask.value,
      );
      expect(data.getUint32(64, Endian.little), subtaskHandle);
      expect(
        data.getUint32(68, Endian.little),
        WASIComponentSubtaskState.returned.code,
      );

      expect(program.invoke(1, <Object?>[subtaskHandle, 0]), isNull);
      expect(program.invoke(3, <Object?>[waitableSet]), isNull);
      expect(program.invoke(4, <Object?>[subtaskHandle]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('separates unsupported definitions from adapter requirements', () {
      final host = WASIComponentCanonicalHost();

      expect(
        host.supportsCanonicalKind(WasmComponentCanonicalKind.threadYield),
        isTrue,
      );
      expect(
        host.supportsCanonicalKind(WasmComponentCanonicalKind.threadIndex),
        isTrue,
      );
      expect(
        host.supportsCanonicalKind(WasmComponentCanonicalKind.threadSuspend),
        isFalse,
      );
      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.threadSuspend,
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.lower,
          ),
        ),
        throwsA(isA<WASIComponentCanonicalHostAdapterException>()),
      );
    });

    test('binds thread.yield as an asynchronous canonical operation', () async {
      final host = WASIComponentCanonicalHost();
      final operation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadYield,
        ),
      );
      final yielded = <String>[];

      final future = operation.invokeAsync(const <Object?>[]).then((result) {
        yielded.add('done');
        return result;
      });

      expect(yielded, isEmpty);
      expect(await future, 0);
      expect(yielded, ['done']);
      expect(() => operation.invoke(const <Object?>[]), throwsUnsupportedError);
    });

    test('reports all unsupported canonical definitions before binding', () {
      final host = WASIComponentCanonicalHost();
      final definitions = const [
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadIndex,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.lower,
          functionIndex: 0,
          typeIndex: 0,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadSuspend,
        ),
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDrop,
        ),
      ];

      final unsupported = host.unsupportedCanonicalDefinitions(definitions);

      expect(unsupported, hasLength(1));
      expect(unsupported.map((definition) => definition.canonicalIndex), [2]);
      expect(unsupported.map((definition) => definition.kind), [
        WasmComponentCanonicalKind.threadSuspend,
      ]);
      expect(
        () => host.bindCanonicalDefinitions(definitions),
        throwsA(
          isA<WASIComponentCanonicalHostUnsupportedException>()
              .having(
                (error) => error.definitions.map(
                  (definition) => definition.canonicalIndex,
                ),
                'canonical indexes',
                [2],
              )
              .having(
                (error) =>
                    error.definitions.map((definition) => definition.kind),
                'canonical kinds',
                [WasmComponentCanonicalKind.threadSuspend],
              )
              .having(
                (error) => error.toString(),
                'message',
                allOf(contains('canonical[2].threadSuspend')),
              ),
        ),
      );
    });

    test('reports canonical kind capabilities by runtime area', () {
      final host = WASIComponentCanonicalHost();

      final capabilities = host.canonicalKindCapabilities;

      expect(
        capabilities.map((capability) => capability.kind),
        WasmComponentCanonicalKind.values,
      );

      final streamRead = host.canonicalKindCapability(
        WasmComponentCanonicalKind.streamRead,
      );
      expect(streamRead.isSupported, isTrue);
      expect(streamRead.area, WASIComponentCanonicalCapabilityArea.asyncValue);
      expect(streamRead.unsupportedReason, isNull);

      final lower = host.canonicalKindCapability(
        WasmComponentCanonicalKind.lower,
      );
      expect(lower.isSupported, isTrue);
      expect(
        lower.area,
        WASIComponentCanonicalCapabilityArea.adapterGeneration,
      );
      expect(lower.unsupportedReason, isNull);
      expect(
        host.supportsCanonicalKind(WasmComponentCanonicalKind.lower),
        isTrue,
      );

      final threadSuspend = host.canonicalKindCapability(
        WasmComponentCanonicalKind.threadSuspend,
      );
      expect(threadSuspend.isSupported, isFalse);
      expect(
        threadSuspend.area,
        WASIComponentCanonicalCapabilityArea.threadScheduling,
      );
      expect(threadSuspend.unsupportedReason, contains('task scheduling'));

      expect(
        host
            .canonicalKindCapability(WasmComponentCanonicalKind.errorContextNew)
            .area,
        WASIComponentCanonicalCapabilityArea.errorContext,
      );
      expect(
        () => capabilities.add(
          const WASIComponentCanonicalKindCapability(
            kind: WasmComponentCanonicalKind.resourceNew,
            area: WASIComponentCanonicalCapabilityArea.resource,
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('prepares a reusable component binding plan', () {
      final component = WasmComponent.decode(_canonicalContextGetBytes());
      final host = WASIComponentCanonicalHost();

      expect(component.validate(), isEmpty);

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isTrue);
      expect(plan.validationErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.canonicalDefinitions.map((definition) => definition.kind), [
        WasmComponentCanonicalKind.contextGet,
      ]);
      expect(
        () => plan.canonicalDefinitions.add(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.contextSet,
            contextIndex: 0,
          ),
        ),
        throwsUnsupportedError,
      );

      final program = plan.bind();
      final secondProgram = plan.bind();

      expect(program.operations.map((operation) => operation.kind), [
        WasmComponentCanonicalKind.contextGet,
      ]);
      expect(secondProgram, isNot(same(program)));
      expect(program.invoke(0, const <Object?>[]), 0);
      expect(secondProgram.invoke(0, const <Object?>[]), 0);
    });

    test('validates decoded components before canonical binding', () {
      final component = WasmComponent.decode(
        _canonicalContextGetOutOfRangeComponentBytes(),
      );
      final host = WASIComponentCanonicalHost();
      final plan = host.prepareComponent(component);

      expect(component.validate(), isNotEmpty);
      expect(plan.canBind, isFalse);
      expect(plan.validationErrors, hasLength(1));
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(
        () => plan.bind(),
        throwsA(
          isA<WASIComponentCanonicalHostValidationException>()
              .having((error) => error.errors, 'errors', hasLength(1))
              .having(
                (error) => error.errors.single.path,
                'path',
                'canonical[0].context',
              ),
        ),
      );
      expect(
        () => host.bindComponent(component),
        throwsA(
          isA<WASIComponentCanonicalHostValidationException>()
              .having((error) => error.errors, 'errors', hasLength(1))
              .having(
                (error) => error.errors.single.path,
                'path',
                'canonical[0].context',
              )
              .having(
                (error) => error.toString(),
                'message',
                contains('context index must be less than 2'),
              ),
        ),
      );
    });
  });
}

Uint8List _canonicalContextGetOutOfRangeComponentBytes() =>
    Uint8List.fromList(const <int>[
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
      0x01,
      0x0a,
      0x7f,
      0x02,
    ]);

Uint8List _canonicalContextGetBytes() => Uint8List.fromList(const <int>[
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
  0x01,
  0x0a,
  0x7f,
  0x00,
]);
