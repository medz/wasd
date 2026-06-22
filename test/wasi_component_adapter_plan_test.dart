import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/adapter_host.dart';
import 'package:wasd/src/wasi/component/adapter_plan.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasi/component/string_memory.dart';
import 'package:wasd/src/wasi/component/versioned_host.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasi/version.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart' as wasm;

import 'support/component_fixtures.dart';

void main() {
  group('WASI component canonical adapter plans', () {
    test('plan primitive lift and lower value memory layouts', () {
      final component = WasmComponent.decode(
        canonicalPrimitiveLiftLowerComponentBytes(),
      );

      expect(component.validate(), isEmpty);

      final plans = componentCanonicalAdapterPlans(component);

      expect(plans, hasLength(2));
      expect(() => plans.clear(), throwsUnsupportedError);

      final lift = plans[0];
      expect(lift.canonicalIndex, 0);
      expect(lift.kind, WasmComponentCanonicalKind.lift);
      expect(lift.params, isEmpty);
      expect(lift.result, isNotNull);
      expect(lift.result!.path, 'canonical[0].result');
      expect(lift.result!.byteLength, 4);
      expect(lift.result!.alignment, 4);
      expect(lift.result!.hasDynamicPayload, isFalse);
      expect(lift.resourceUses, isEmpty);
      expect(lift.hasResourceHandles, isFalse);
      expect(lift.hasDynamicPayload, isFalse);
      expect(lift.stringEncoding, WASIComponentCanonicalStringEncoding.utf8);
      expect(lift.memoryIndex, 0);
      expect(lift.reallocIndex, isNull);
      expect(lift.isAsync, isFalse);

      final lower = plans[1];
      expect(lower.canonicalIndex, 1);
      expect(lower.kind, WasmComponentCanonicalKind.lower);
      expect(lower.params, isEmpty);
      expect(lower.result, isNotNull);
      expect(lower.result!.byteLength, 4);
      expect(lower.result!.alignment, 4);
      expect(lower.memoryIndex, isNull);
      expect(lower.reallocIndex, isNull);
    });

    test('plan string lift and lower value memory layouts', () {
      final component = WasmComponent.decode(
        canonicalStringLiftLowerComponentBytes(),
      );

      expect(component.validate(), isEmpty);

      final plans = componentCanonicalAdapterPlans(component);

      expect(plans, hasLength(2));
      for (final plan in plans) {
        expect(plan.params, hasLength(1));
        expect(plan.params.single.label, 'input');
        expect(plan.params.single.byteLength, 8);
        expect(plan.params.single.alignment, 4);
        expect(plan.params.single.hasDynamicPayload, isTrue);
        expect(plan.result, isNotNull);
        expect(plan.result!.byteLength, 8);
        expect(plan.result!.alignment, 4);
        expect(plan.result!.hasDynamicPayload, isTrue);
        expect(plan.hasDynamicPayload, isTrue);
        expect(plan.stringEncoding, WASIComponentCanonicalStringEncoding.utf8);
        expect(plan.memoryIndex, 0);
      }
      expect(plans[0].kind, WasmComponentCanonicalKind.lift);
      expect(plans[0].reallocIndex, 1);
      expect(plans[1].kind, WasmComponentCanonicalKind.lower);
      expect(plans[1].reallocIndex, 1);
    });

    test('executes primitive lift and lower plans with direct callbacks', () {
      final component = WasmComponent.decode(
        canonicalPrimitiveLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();

      final lift = host.bindLiftCoreFunction(plans[0], (args) {
        expect(args, isEmpty);
        return 41;
      });
      final lower = host.bindLowerComponentFunction(plans[1], (args) {
        expect(args, isEmpty);
        return 42;
      });

      expect(lift.kind, WasmComponentCanonicalKind.lift);
      expect(lift.canonicalIndex, 0);
      expect(lift.invoke(const <Object?>[]), 41);
      expect(lower.kind, WasmComponentCanonicalKind.lower);
      expect(lower.canonicalIndex, 1);
      expect(lower.invoke(const <Object?>[]), 42);
      expect(() => lift.invoke(const <Object?>[1]), throwsStateError);

      final invalidResult = host.bindLiftCoreFunction(
        plans[0],
        (_) => 'not-a-number',
      );
      expect(() => invalidResult.invoke(const <Object?>[]), throwsStateError);
    });

    test('executes string lift and lower plans with direct callbacks', () {
      final component = WasmComponent.decode(
        canonicalStringLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();

      final lift = host.bindLiftCoreFunction(plans[0], (args) {
        expect(args, ['guest']);
        return 'host:${args.single}';
      });
      final lower = host.bindLowerComponentFunction(plans[1], (args) {
        expect(args, ['component']);
        return 'core:${args.single}';
      });

      expect(lift.invoke(const <Object?>['guest']), 'host:guest');
      expect(lower.invoke(const <Object?>['component']), 'core:component');

      final invalidParam = host.bindLiftCoreFunction(plans[0], (_) => 'ok');
      expect(() => invalidParam.invoke(const <Object?>[1]), throwsStateError);

      final invalidResult = host.bindLowerComponentFunction(plans[1], (_) => 1);
      expect(
        () => invalidResult.invoke(const <Object?>['component']),
        throwsStateError,
      );
    });

    test('binds primitive adapter programs by decoded function indexes', () {
      final component = WasmComponent.decode(
        canonicalPrimitiveLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();
      var coreInvocations = 0;
      var componentInvocations = 0;

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          0: (args) {
            expect(args, isEmpty);
            coreInvocations++;
            return 11;
          },
        },
        componentFunctions: {
          0: (args) {
            expect(args, isEmpty);
            componentInvocations++;
            return 12;
          },
        },
      );

      expect(program.operations, hasLength(2));
      expect(() => program.operations.clear(), throwsUnsupportedError);
      expect(program.invoke(0, const <Object?>[]), 11);
      expect(program.invoke(1, const <Object?>[]), 12);
      expect(coreInvocations, 1);
      expect(componentInvocations, 1);
      expect(() => program.invoke(2, const <Object?>[]), throwsStateError);
      expect(
        () => host.bindAdapterPlans(plans, coreFunctions: {0: (_) => 1}),
        throwsStateError,
      );
    });

    test('binds string adapter programs by decoded function indexes', () {
      final component = WasmComponent.decode(
        canonicalStringLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();
      var coreInvocations = 0;
      var componentInvocations = 0;

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          0: (args) {
            expect(args, ['core']);
            coreInvocations++;
            return 'lift:${args.single}';
          },
        },
        componentFunctions: {
          0: (args) {
            expect(args, ['component']);
            componentInvocations++;
            return 'lower:${args.single}';
          },
        },
      );

      expect(program.invoke(0, const <Object?>['core']), 'lift:core');
      expect(
        program.invoke(1, const <Object?>['component']),
        'lower:component',
      );
      expect(coreInvocations, 1);
      expect(componentInvocations, 1);
      expect(() => program.invoke(0, const <Object?>[1]), throwsStateError);
    });

    test('invokes adapter programs through flat primitive values', () {
      final component = WasmComponent.decode(
        canonicalPrimitiveLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {0: (_) => 51},
        componentFunctions: {0: (_) => 52},
      );

      expect(program.invokeFlat(0, const <Object?>[]), [51]);
      expect(program.invokeFlat(1, const <Object?>[]), [52]);
      expect(() => program.invokeFlat(0, const <Object?>[1]), throwsStateError);
    });

    test('invokes string adapter programs through flat scalar values', () {
      final component = WasmComponent.decode(
        canonicalStringLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();
      final memory = wasm.Memory(const wasm.MemoryDescriptor(initial: 1));
      final realloc = _bumpRealloc(memory);
      final input = writeWASIComponentCanonicalString(
        memory,
        realloc,
        'guest',
        WASIComponentCanonicalStringEncoding.utf8,
      );

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          0: (args) {
            expect(args, ['guest']);
            return 'lifted:${args.single}';
          },
        },
        componentFunctions: {
          0: (args) {
            expect(args, ['guest']);
            return 'lowered:${args.single}';
          },
        },
      );

      final lifted = program.invokeFlat(
        0,
        <Object?>[input.pointer, input.canonicalLength],
        memory: memory,
        realloc: realloc,
      );
      expect(lifted, hasLength(2));
      expect(
        readWASIComponentCanonicalString(
          memory,
          lifted[0]! as int,
          lifted[1]! as int,
          WASIComponentCanonicalStringEncoding.utf8,
        ),
        'lifted:guest',
      );

      final lowered = program.invokeFlat(
        1,
        <Object?>[input.pointer, input.canonicalLength],
        memory: memory,
        realloc: realloc,
      );
      expect(lowered, hasLength(2));
      expect(
        readWASIComponentCanonicalString(
          memory,
          lowered[0]! as int,
          lowered[1]! as int,
          WASIComponentCanonicalStringEncoding.utf8,
        ),
        'lowered:guest',
      );
      expect(
        () => program.invokeFlat(0, <Object?>[
          input.pointer,
          input.canonicalLength,
        ]),
        throwsStateError,
      );
      expect(
        () => program.invokeFlat(0, <Object?>[
          input.pointer,
          input.canonicalLength,
        ], memory: memory),
        throwsUnsupportedError,
      );
    });

    test('invokes string adapter programs through canonical value memory', () {
      final component = WasmComponent.decode(
        canonicalStringLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();
      final memory = wasm.Memory(const wasm.MemoryDescriptor(initial: 1));
      final realloc = _bumpRealloc(memory);
      final input = writeWASIComponentCanonicalString(
        memory,
        realloc,
        'guest',
        WASIComponentCanonicalStringEncoding.utf8,
      );
      writeWASIComponentMemoryStringRecord(memory, 32, input);

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          0: (args) {
            expect(args, ['guest']);
            return 'lifted:${args.single}';
          },
        },
        componentFunctions: {
          0: (args) {
            expect(args, ['guest']);
            return 'lowered:${args.single}';
          },
        },
      );

      expect(
        program.invokeWithMemory(
          0,
          memory,
          const <int>[32],
          resultPointer: 64,
          realloc: realloc,
        ),
        'lifted:guest',
      );
      expect(
        readWASIComponentCanonicalStringRecord(
          memory,
          64,
          WASIComponentCanonicalStringEncoding.utf8,
        ),
        'lifted:guest',
      );

      expect(
        program.invokeWithMemory(
          1,
          memory,
          const <int>[32],
          resultPointer: 96,
          realloc: realloc,
        ),
        'lowered:guest',
      );
      expect(
        readWASIComponentCanonicalStringRecord(
          memory,
          96,
          WASIComponentCanonicalStringEncoding.utf8,
        ),
        'lowered:guest',
      );
      expect(
        () => program.invokeWithMemory(0, memory, const <int>[
          32,
        ], realloc: realloc),
        throwsStateError,
      );
      expect(
        () => program.invokeWithMemory(0, memory, const <int>[
          32,
        ], resultPointer: 128),
        throwsUnsupportedError,
      );
    });

    test('binds primitive adapter programs from component host plans', () {
      final component = WasmComponent.decode(
        canonicalPrimitiveLiftLowerComponentBytes(),
      );
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isFalse);
      expect(plan.validationErrors, isEmpty);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.unsupportedDefinitions, hasLength(2));
      expect(plan.adapterPlans, hasLength(2));

      final program = plan.bindAdapters(
        coreFunctions: {0: (_) => 21},
        componentFunctions: {0: (_) => 22},
      );

      expect(program.operations, hasLength(2));
      expect(program.invoke(0, const <Object?>[]), 21);
      expect(program.invoke(1, const <Object?>[]), 22);
      expect(
        () => plan.bind(),
        throwsA(isA<WASIComponentCanonicalHostUnsupportedException>()),
      );
    });

    test('binds primitive adapter programs through Preview3 only', () {
      final component = WasmComponent.decode(
        canonicalPrimitiveLiftLowerComponentBytes(),
      );

      final preview3Plan = WASIPreview3ComponentHost().prepareComponent(
        component,
      );

      expect(preview3Plan.canBind, isFalse);
      expect(preview3Plan.versionErrors, isEmpty);
      expect(preview3Plan.adapterPlans, hasLength(2));

      final program = preview3Plan.bindAdapters(
        coreFunctions: {0: (_) => 31},
        componentFunctions: {0: (_) => 32},
      );

      expect(program.invoke(0, const <Object?>[]), 31);
      expect(program.invoke(1, const <Object?>[]), 32);

      final preview1Plan = WASIComponentVersionedHost(
        version: WASIVersion.preview1,
      ).prepareComponent(component);

      expect(preview1Plan.versionErrors, hasLength(2));
      expect(
        () => preview1Plan.bindAdapters(
          coreFunctions: {0: (_) => 1},
          componentFunctions: {0: (_) => 2},
        ),
        throwsA(isA<WASIComponentVersionUnsupportedException>()),
      );
    });

    test('exposes resource adapter plans through Preview3 preparation', () {
      final component = WasmComponent.decode(
        canonicalResourceLiftComponentBytes(),
      );
      final host = WASIPreview3ComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isFalse);
      expect(plan.versionErrors, isEmpty);
      expect(plan.adapterPlans, hasLength(1));

      final adapter = plan.adapterPlans.single;
      expect(adapter.kind, WasmComponentCanonicalKind.lift);
      expect(adapter.hasResourceHandles, isTrue);
      expect(adapter.hasDynamicPayload, isFalse);
      expect(adapter.resourceUses, hasLength(3));
      expect(adapter.params, hasLength(2));

      expect(adapter.params[0].path, 'canonical[0].param[0].owned');
      expect(adapter.params[0].label, 'owned');
      expect(adapter.params[0].hasMemoryCodec, isFalse);
      expect(
        adapter.params[0].resourceUses.single.handleKind,
        WASIComponentResourceHandleKind.own,
      );

      expect(adapter.params[1].path, 'canonical[0].param[1].borrowed');
      expect(adapter.params[1].label, 'borrowed');
      expect(adapter.params[1].hasMemoryCodec, isFalse);
      expect(
        adapter.params[1].resourceUses.single.handleKind,
        WASIComponentResourceHandleKind.borrow,
      );

      expect(adapter.result, isNotNull);
      expect(adapter.result!.path, 'canonical[0].result');
      expect(adapter.result!.hasMemoryCodec, isFalse);
      expect(
        adapter.result!.resourceUses.single.handleKind,
        WASIComponentResourceHandleKind.own,
      );

      expect(
        () => host.componentHost.canonicalHost.adapterHost.bindLiftCoreFunction(
          adapter,
          (_) => 1,
        ),
        throwsUnsupportedError,
      );
    });
  });
}

WASIComponentCanonicalRealloc _bumpRealloc(
  wasm.Memory memory, {
  int start = 256,
}) {
  var heap = start;
  return (_, _, alignment, newSize) {
    final remainder = heap % alignment;
    if (remainder != 0) {
      heap += alignment - remainder;
    }
    final pointer = heap;
    heap += newSize;
    if (heap > memory.buffer.lengthInBytes) {
      throw StateError('test realloc exceeded memory');
    }
    return pointer;
  };
}
