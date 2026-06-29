import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/subtask.dart';
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

    test('rejects unsupported scheduler-dependent canonical definitions', () {
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
        throwsUnsupportedError,
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

      final future = operation
          .invokeAsync(const <Object?>[])
          .then((_) => yielded.add('done'));

      expect(yielded, isEmpty);
      await future;
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

      expect(unsupported, hasLength(2));
      expect(unsupported.map((definition) => definition.canonicalIndex), [
        1,
        2,
      ]);
      expect(unsupported.map((definition) => definition.kind), [
        WasmComponentCanonicalKind.lower,
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
                [1, 2],
              )
              .having(
                (error) =>
                    error.definitions.map((definition) => definition.kind),
                'canonical kinds',
                [
                  WasmComponentCanonicalKind.lower,
                  WasmComponentCanonicalKind.threadSuspend,
                ],
              )
              .having(
                (error) => error.toString(),
                'message',
                allOf(
                  contains('canonical[1].lower'),
                  contains('canonical[2].threadSuspend'),
                ),
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
      expect(lower.isSupported, isFalse);
      expect(
        lower.area,
        WASIComponentCanonicalCapabilityArea.adapterGeneration,
      );
      expect(lower.unsupportedReason, contains('typed core function'));
      expect(
        host.supportsCanonicalKind(WasmComponentCanonicalKind.lower),
        isFalse,
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
