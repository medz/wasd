import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/adapter_host.dart';
import 'package:wasd/src/wasi/component/adapter_plan.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasi/component/string_memory.dart';
import 'package:wasd/src/wasi/component/value_memory.dart';
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

    test('plan error-context flat handle layouts', () {
      final component = WasmComponent.decode(
        canonicalErrorContextLiftLowerComponentBytes(),
      );

      expect(component.validate(), isEmpty);

      final plans = componentCanonicalAdapterPlans(component);

      expect(plans, hasLength(2));
      for (final plan in plans) {
        expect(plan.params, hasLength(1));
        expect(plan.params.single.label, 'input');
        expect(plan.params.single.hasMemoryCodec, isTrue);
        expect(plan.params.single.byteLength, 4);
        expect(plan.params.single.alignment, 4);
        expect(plan.params.single.flatLength, 1);
        expect(
          plan.params.single.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.errorContext,
        );
        expect(plan.result, isNotNull);
        expect(plan.result!.hasMemoryCodec, isTrue);
        expect(plan.result!.byteLength, 4);
        expect(plan.result!.alignment, 4);
        expect(plan.result!.flatLength, 1);
        expect(
          plan.result!.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.errorContext,
        );
        expect(plan.hasDynamicPayload, isFalse);
        expect(plan.hasResourceHandles, isFalse);
        expect(plan.memoryIndex, 0);
        expect(plan.reallocIndex, 0);
      }
    });

    test('plan record lift and lower flat value layouts', () {
      final component = WasmComponent.decode(
        canonicalRecordLiftLowerComponentBytes(),
      );

      expect(component.validate(), isEmpty);

      final plans = componentCanonicalAdapterPlans(component);

      expect(plans, hasLength(2));
      for (final plan in plans) {
        expect(plan.params, hasLength(1));
        expect(plan.params.single.label, 'input');
        expect(plan.params.single.byteLength, 8);
        expect(plan.params.single.alignment, 4);
        expect(plan.params.single.flatLength, 2);
        expect(plan.result, isNotNull);
        expect(plan.result!.byteLength, 8);
        expect(plan.result!.alignment, 4);
        expect(plan.result!.flatLength, 2);
        expect(plan.hasDynamicPayload, isFalse);
      }
    });

    test('plan tuple and fixed-list lift and lower flat value layouts', () {
      final tupleComponent = WasmComponent.decode(
        canonicalTupleLiftLowerComponentBytes(),
      );
      final fixedListComponent = WasmComponent.decode(
        canonicalFixedListLiftLowerComponentBytes(),
      );

      expect(tupleComponent.validate(), isEmpty);
      expect(fixedListComponent.validate(), isEmpty);

      final cases = [
        (
          plans: componentCanonicalAdapterPlans(tupleComponent),
          kind: WASIComponentCanonicalAdapterFlatValueKind.tuple,
          flatLength: 2,
          byteLength: 8,
          alignment: 4,
        ),
        (
          plans: componentCanonicalAdapterPlans(fixedListComponent),
          kind: WASIComponentCanonicalAdapterFlatValueKind.fixedList,
          flatLength: 3,
          byteLength: 12,
          alignment: 4,
        ),
      ];

      for (final case_ in cases) {
        expect(case_.plans, hasLength(2));
        for (final plan in case_.plans) {
          expect(plan.params, hasLength(1));
          expect(plan.params.single.label, 'input');
          expect(plan.params.single.byteLength, case_.byteLength);
          expect(plan.params.single.alignment, case_.alignment);
          expect(plan.params.single.flatLength, case_.flatLength);
          expect(plan.params.single.flatLayout!.kind, case_.kind);
          expect(plan.result, isNotNull);
          expect(plan.result!.byteLength, case_.byteLength);
          expect(plan.result!.alignment, case_.alignment);
          expect(plan.result!.flatLength, case_.flatLength);
          expect(plan.result!.flatLayout!.kind, case_.kind);
          expect(plan.hasDynamicPayload, isFalse);
        }
      }
    });

    test('plan flags and enum flat value layouts', () {
      final component = WasmComponent.decode(
        canonicalFlagsEnumLiftLowerComponentBytes(),
      );

      expect(component.validate(), isEmpty);

      final plans = componentCanonicalAdapterPlans(component);

      expect(plans, hasLength(4));
      for (final plan in plans.take(2)) {
        expect(plan.params.single.flatLength, 1);
        expect(
          plan.params.single.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.flags,
        );
        expect(plan.result!.flatLength, 1);
        expect(
          plan.result!.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.flags,
        );
      }
      for (final plan in plans.skip(2)) {
        expect(plan.params.single.flatLength, 1);
        expect(
          plan.params.single.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.enumeration,
        );
        expect(plan.result!.flatLength, 1);
        expect(
          plan.result!.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.enumeration,
        );
      }
    });

    test('plan list flat value layouts', () {
      final component = WasmComponent.decode(
        canonicalU32ListLiftLowerComponentBytes(),
      );

      expect(component.validate(), isEmpty);

      final plans = componentCanonicalAdapterPlans(component);

      expect(plans, hasLength(2));
      for (final plan in plans) {
        expect(plan.params, hasLength(1));
        expect(plan.params.single.label, 'input');
        expect(plan.params.single.byteLength, 8);
        expect(plan.params.single.alignment, 4);
        expect(plan.params.single.flatLength, 2);
        expect(
          plan.params.single.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.list,
        );
        expect(plan.result, isNotNull);
        expect(plan.result!.byteLength, 8);
        expect(plan.result!.alignment, 4);
        expect(plan.result!.flatLength, 2);
        expect(
          plan.result!.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.list,
        );
        expect(plan.hasDynamicPayload, isTrue);
        expect(plan.memoryIndex, 0);
        expect(plan.reallocIndex, 0);
      }
    });

    test('plan variant flat value layouts', () {
      final component = WasmComponent.decode(
        canonicalU32VariantLiftLowerComponentBytes(),
      );

      expect(component.validate(), isEmpty);

      final plans = componentCanonicalAdapterPlans(component);

      expect(plans, hasLength(2));
      for (final plan in plans) {
        expect(plan.params, hasLength(1));
        expect(plan.params.single.label, 'input');
        expect(plan.params.single.byteLength, 8);
        expect(plan.params.single.alignment, 4);
        expect(plan.params.single.flatLength, 2);
        final paramLayout = plan.params.single.flatLayout!;
        expect(
          paramLayout.kind,
          WASIComponentCanonicalAdapterFlatValueKind.variant,
        );
        expect(paramLayout.cases.map((case_) => case_.label), [
          'empty',
          'left',
          'right',
        ]);
        expect(paramLayout.cases[0].value, isNull);
        expect(paramLayout.cases[1].value!.flatLength, 1);
        expect(paramLayout.cases[2].value!.flatLength, 1);
        expect(plan.result, isNotNull);
        expect(plan.result!.byteLength, 8);
        expect(plan.result!.alignment, 4);
        expect(plan.result!.flatLength, 2);
        expect(
          plan.result!.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.variant,
        );
        expect(plan.hasDynamicPayload, isFalse);
        expect(plan.memoryIndex, 0);
        expect(plan.reallocIndex, 0);
      }
    });

    test('plan option flat value layouts', () {
      final component = WasmComponent.decode(
        canonicalU32OptionLiftLowerComponentBytes(),
      );

      expect(component.validate(), isEmpty);

      final plans = componentCanonicalAdapterPlans(component);

      expect(plans, hasLength(2));
      for (final plan in plans) {
        expect(plan.params, hasLength(1));
        expect(plan.params.single.label, 'input');
        expect(plan.params.single.byteLength, 8);
        expect(plan.params.single.alignment, 4);
        expect(plan.params.single.flatLength, 2);
        expect(
          plan.params.single.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.option,
        );
        expect(plan.result, isNotNull);
        expect(plan.result!.byteLength, 8);
        expect(plan.result!.alignment, 4);
        expect(plan.result!.flatLength, 2);
        expect(
          plan.result!.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.option,
        );
        expect(plan.hasDynamicPayload, isFalse);
        expect(plan.memoryIndex, 0);
        expect(plan.reallocIndex, 0);
      }
    });

    test('plan result flat value layouts', () {
      final component = WasmComponent.decode(
        canonicalU32ResultLiftLowerComponentBytes(),
      );

      expect(component.validate(), isEmpty);

      final plans = componentCanonicalAdapterPlans(component);

      expect(plans, hasLength(2));
      for (final plan in plans) {
        expect(plan.params, hasLength(1));
        expect(plan.params.single.label, 'input');
        expect(plan.params.single.byteLength, 8);
        expect(plan.params.single.alignment, 4);
        expect(plan.params.single.flatLength, 2);
        expect(
          plan.params.single.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.result,
        );
        expect(plan.result, isNotNull);
        expect(plan.result!.byteLength, 8);
        expect(plan.result!.alignment, 4);
        expect(plan.result!.flatLength, 2);
        expect(
          plan.result!.flatLayout!.kind,
          WASIComponentCanonicalAdapterFlatValueKind.result,
        );
        expect(plan.hasDynamicPayload, isFalse);
        expect(plan.memoryIndex, 0);
        expect(plan.reallocIndex, 0);
      }
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

    test('invokes record adapter programs through flat scalar values', () {
      final component = WasmComponent.decode(
        canonicalRecordLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          0: (args) {
            expect(args.single, isA<WasmComponentValueData>());
            final record = args.single! as WasmComponentValueData;
            expect(record.kind, WasmComponentValueDataKind.record);
            expect(record.items.map((item) => item.integer), [11, 12]);
            return WasmComponentValueData(
              kind: WasmComponentValueDataKind.record,
              rawBytes: Uint8List(0),
              items: [
                WasmComponentValueData(
                  kind: WasmComponentValueDataKind.integer,
                  rawBytes: Uint8List(0),
                  integer: 21,
                ),
                WasmComponentValueData(
                  kind: WasmComponentValueDataKind.integer,
                  rawBytes: Uint8List(0),
                  integer: 22,
                ),
              ],
            );
          },
        },
        componentFunctions: {
          0: (args) {
            final record = args.single! as WasmComponentValueData;
            expect(record.kind, WasmComponentValueDataKind.record);
            expect(record.items.map((item) => item.integer), [31, 32]);
            return WasmComponentValueData(
              kind: WasmComponentValueDataKind.record,
              rawBytes: Uint8List(0),
              items: [
                WasmComponentValueData(
                  kind: WasmComponentValueDataKind.integer,
                  rawBytes: Uint8List(0),
                  integer: 41,
                ),
                WasmComponentValueData(
                  kind: WasmComponentValueDataKind.integer,
                  rawBytes: Uint8List(0),
                  integer: 42,
                ),
              ],
            );
          },
        },
      );

      expect(program.invokeFlat(0, const <Object?>[11, 12]), [21, 22]);
      expect(program.invokeFlat(1, const <Object?>[31, 32]), [41, 42]);
      expect(
        () => program.invokeFlat(0, const <Object?>[11]),
        throwsStateError,
      );
    });

    test(
      'invokes handle-aware record adapter programs through canonical value memory',
      () {
        final memoryCodec =
            WASIComponentCanonicalValueMemoryCodec.fromAdapterValueType(
              canonicalResourceRecordValueType,
              canonicalResourceRecordDefinitions,
            )!;
        final resourceUses = [
          const WASIComponentResourceUse(
            canonicalIndex: 0,
            canonicalKind: WasmComponentCanonicalKind.lift,
            path: 'canonical[0].param[0].input.owned',
            handleKind: WASIComponentResourceHandleKind.own,
            resourceTypeIndex: 0,
            binding: null,
          ),
          const WASIComponentResourceUse(
            canonicalIndex: 0,
            canonicalKind: WasmComponentCanonicalKind.lift,
            path: 'canonical[0].param[0].input.borrowed',
            handleKind: WASIComponentResourceHandleKind.borrow,
            resourceTypeIndex: 0,
            binding: null,
          ),
          const WASIComponentResourceUse(
            canonicalIndex: 0,
            canonicalKind: WasmComponentCanonicalKind.lift,
            path: 'canonical[0].result.owned',
            handleKind: WASIComponentResourceHandleKind.own,
            resourceTypeIndex: 0,
            binding: null,
          ),
          const WASIComponentResourceUse(
            canonicalIndex: 0,
            canonicalKind: WasmComponentCanonicalKind.lift,
            path: 'canonical[0].result.borrowed',
            handleKind: WASIComponentResourceHandleKind.borrow,
            resourceTypeIndex: 0,
            binding: null,
          ),
        ];
        final plan = WASIComponentCanonicalAdapterPlan(
          canonicalIndex: 0,
          definition: const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.lift,
            coreFunctionIndex: 0,
          ),
          functionType: const WasmComponentFunctionType(
            params: [
              WasmComponentLabeledValueType(
                label: 'input',
                type: canonicalResourceRecordValueType,
              ),
            ],
            result: canonicalResourceRecordValueType,
          ),
          params: [
            WASIComponentCanonicalAdapterValuePlan(
              path: 'canonical[0].param[0].input',
              label: 'input',
              type: canonicalResourceRecordValueType,
              memoryCodec: memoryCodec,
              flatLayout: null,
              resourceUses: resourceUses
                  .where(
                    (use) =>
                        use.path.startsWith('canonical[0].param[0].input.'),
                  )
                  .toList(growable: false),
            ),
          ],
          result: WASIComponentCanonicalAdapterValuePlan(
            path: 'canonical[0].result',
            label: null,
            type: canonicalResourceRecordValueType,
            memoryCodec: memoryCodec,
            flatLayout: null,
            resourceUses: resourceUses
                .where((use) => use.path.startsWith('canonical[0].result.'))
                .toList(growable: false),
          ),
          resourceUses: resourceUses,
          stringEncoding: WASIComponentCanonicalStringEncoding.utf8,
          memoryIndex: 0,
          reallocIndex: null,
          postReturnIndex: null,
          callbackIndex: null,
          isAsync: false,
        );
        final memory = wasm.Memory(const wasm.MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        data.setUint32(32, 101, Endian.little);
        data.setUint32(36, 202, Endian.little);
        data.setUint16(40, 7, Endian.little);

        final program = const WASIComponentCanonicalAdapterHost()
            .bindAdapterPlans(
              [plan],
              coreFunctions: {
                0: (args) {
                  final record = args.single! as WasmComponentValueData;
                  expect(record.kind, WasmComponentValueDataKind.record);
                  expect(record.items.map((item) => item.integer), [
                    101,
                    202,
                    7,
                  ]);
                  return _u32CompositeValue(
                    WasmComponentValueDataKind.record,
                    const [303, 404, 9],
                  );
                },
              },
            );

        final result = program.invokeWithMemory(0, memory, const <int>[
          32,
        ], resultPointer: 64);

        expect(result, isA<WasmComponentValueData>());
        expect(data.getUint32(64, Endian.little), 303);
        expect(data.getUint32(68, Endian.little), 404);
        expect(data.getUint16(72, Endian.little), 9);
        expect(
          () => program.invoke(0, const <Object?>[]),
          throwsUnsupportedError,
        );
      },
    );

    test(
      'invokes tuple and fixed-list adapter programs through flat scalars',
      () {
        final tupleComponent = WasmComponent.decode(
          canonicalTupleLiftLowerComponentBytes(),
        );
        final fixedListComponent = WasmComponent.decode(
          canonicalFixedListLiftLowerComponentBytes(),
        );
        final tuplePlans = componentCanonicalAdapterPlans(tupleComponent);
        final fixedListPlans = componentCanonicalAdapterPlans(
          fixedListComponent,
        );
        final host = const WASIComponentCanonicalAdapterHost();

        final tupleProgram = host.bindAdapterPlans(
          tuplePlans,
          coreFunctions: {
            0: (args) {
              final tuple = args.single! as WasmComponentValueData;
              expect(tuple.kind, WasmComponentValueDataKind.tuple);
              expect(tuple.items.map((item) => item.integer), [11, 12]);
              return _u32CompositeValue(
                WasmComponentValueDataKind.tuple,
                const [21, 22],
              );
            },
          },
          componentFunctions: {
            0: (args) {
              final tuple = args.single! as WasmComponentValueData;
              expect(tuple.kind, WasmComponentValueDataKind.tuple);
              expect(tuple.items.map((item) => item.integer), [31, 32]);
              return _u32CompositeValue(
                WasmComponentValueDataKind.tuple,
                const [41, 42],
              );
            },
          },
        );
        final fixedListProgram = host.bindAdapterPlans(
          fixedListPlans,
          coreFunctions: {
            0: (args) {
              final fixedList = args.single! as WasmComponentValueData;
              expect(fixedList.kind, WasmComponentValueDataKind.fixedList);
              expect(fixedList.items.map((item) => item.integer), [1, 2, 3]);
              return _u32CompositeValue(
                WasmComponentValueDataKind.fixedList,
                const [4, 5, 6],
              );
            },
          },
          componentFunctions: {
            0: (args) {
              final fixedList = args.single! as WasmComponentValueData;
              expect(fixedList.kind, WasmComponentValueDataKind.fixedList);
              expect(fixedList.items.map((item) => item.integer), [7, 8, 9]);
              return _u32CompositeValue(
                WasmComponentValueDataKind.fixedList,
                const [10, 11, 12],
              );
            },
          },
        );

        expect(tupleProgram.invokeFlat(0, const <Object?>[11, 12]), [21, 22]);
        expect(tupleProgram.invokeFlat(1, const <Object?>[31, 32]), [41, 42]);
        expect(fixedListProgram.invokeFlat(0, const <Object?>[1, 2, 3]), [
          4,
          5,
          6,
        ]);
        expect(fixedListProgram.invokeFlat(1, const <Object?>[7, 8, 9]), [
          10,
          11,
          12,
        ]);
        expect(
          () => tupleProgram.invokeFlat(0, const <Object?>[11]),
          throwsStateError,
        );
        expect(
          () => fixedListProgram.invokeFlat(0, const <Object?>[1, 2]),
          throwsStateError,
        );
      },
    );

    test('invokes flags and enum adapter programs through flat scalars', () {
      final component = WasmComponent.decode(
        canonicalFlagsEnumLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          0: (args) {
            final flags = args.single! as WasmComponentValueData;
            expect(flags.kind, WasmComponentValueDataKind.flags);
            expect(flags.labels, ['read', 'exec']);
            return WasmComponentValueData(
              kind: WasmComponentValueDataKind.flags,
              rawBytes: Uint8List(0),
              labels: ['read', 'write'],
            );
          },
          1: (args) {
            final color = args.single! as WasmComponentValueData;
            expect(color.kind, WasmComponentValueDataKind.enumeration);
            expect(color.index, 1);
            expect(color.label, 'green');
            return WasmComponentValueData(
              kind: WasmComponentValueDataKind.enumeration,
              rawBytes: Uint8List(0),
              label: 'blue',
            );
          },
        },
        componentFunctions: {
          0: (args) {
            final flags = args.single! as WasmComponentValueData;
            expect(flags.kind, WasmComponentValueDataKind.flags);
            expect(flags.labels, ['write']);
            return WasmComponentValueData(
              kind: WasmComponentValueDataKind.flags,
              rawBytes: Uint8List(0),
              labels: ['exec'],
            );
          },
          1: (args) {
            final color = args.single! as WasmComponentValueData;
            expect(color.kind, WasmComponentValueDataKind.enumeration);
            expect(color.index, 0);
            expect(color.label, 'red');
            return WasmComponentValueData(
              kind: WasmComponentValueDataKind.enumeration,
              rawBytes: Uint8List(0),
              index: 1,
            );
          },
        },
      );

      expect(program.invokeFlat(0, const <Object?>[0x5]), [0x3]);
      expect(program.invokeFlat(1, const <Object?>[0x2]), [0x4]);
      expect(program.invokeFlat(2, const <Object?>[1]), [2]);
      expect(program.invokeFlat(3, const <Object?>[0]), [1]);
      expect(
        () => program.invokeFlat(0, const <Object?>[0x8]),
        throwsStateError,
      );
      expect(() => program.invokeFlat(2, const <Object?>[3]), throwsStateError);
    });

    test('invokes list adapter programs through flat pointer length pairs', () {
      final component = WasmComponent.decode(
        canonicalU32ListLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();
      final memory = wasm.Memory(const wasm.MemoryDescriptor(initial: 1));
      final realloc = _bumpRealloc(memory, start: 512);
      _writeU32List(memory, 64, const [3, 5]);
      _writeU32List(memory, 96, const [11]);

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          1: (args) {
            final list = args.single! as WasmComponentValueData;
            expect(list.kind, WasmComponentValueDataKind.list);
            expect(list.items.map((item) => item.integer), [3, 5]);
            return _u32ListValue(const [7, 13, 17]);
          },
        },
        componentFunctions: {
          0: (args) {
            final list = args.single! as WasmComponentValueData;
            expect(list.kind, WasmComponentValueDataKind.list);
            expect(list.items.map((item) => item.integer), [11]);
            return _u32ListValue(const [19, 23]);
          },
        },
      );

      final lifted = program.invokeFlat(
        0,
        const <Object?>[64, 2],
        memory: memory,
        realloc: realloc,
      );
      expect(lifted[1], 3);
      expect(_readU32List(memory, lifted[0]! as int, lifted[1]! as int), [
        7,
        13,
        17,
      ]);

      final lowered = program.invokeFlat(
        1,
        const <Object?>[96, 1],
        memory: memory,
        realloc: realloc,
      );
      expect(lowered[1], 2);
      expect(_readU32List(memory, lowered[0]! as int, lowered[1]! as int), [
        19,
        23,
      ]);
      expect(
        () => program.invokeFlat(0, const <Object?>[64, 2]),
        throwsStateError,
      );
      expect(
        () => program.invokeFlat(0, const <Object?>[64, 2], memory: memory),
        throwsUnsupportedError,
      );
    });

    test('invokes variant adapter programs through flat tag payload pairs', () {
      final component = WasmComponent.decode(
        canonicalU32VariantLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          1: (args) {
            final variant = args.single! as WasmComponentValueData;
            expect(variant.kind, WasmComponentValueDataKind.variant);
            expect(variant.index, 1);
            expect(variant.label, 'left');
            expect(variant.associatedValue!.integer, 31);
            return _u32VariantValue(label: 'right', value: 41);
          },
        },
        componentFunctions: {
          0: (args) {
            final variant = args.single! as WasmComponentValueData;
            expect(variant.kind, WasmComponentValueDataKind.variant);
            expect(variant.index, 0);
            expect(variant.label, 'empty');
            expect(variant.associatedValue, isNull);
            return _u32VariantValue(index: 0);
          },
        },
      );

      expect(program.invokeFlat(0, const <Object?>[1, 31]), [2, 41]);
      expect(program.invokeFlat(1, const <Object?>[0, 999]), [0, 0]);
      expect(
        () => program.invokeFlat(0, const <Object?>[3, 0]),
        throwsStateError,
      );
      expect(() => program.invokeFlat(0, const <Object?>[1]), throwsStateError);
    });

    test('invokes option adapter programs through flat tag payload pairs', () {
      final component = WasmComponent.decode(
        canonicalU32OptionLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          1: (args) {
            final option = args.single! as WasmComponentValueData;
            expect(option.kind, WasmComponentValueDataKind.option);
            expect(option.index, 1);
            expect(option.label, 'some');
            expect(option.isSome, isTrue);
            expect(option.associatedValue!.integer, 31);
            return _u32SomeValue(41);
          },
        },
        componentFunctions: {
          0: (args) {
            final option = args.single! as WasmComponentValueData;
            expect(option.kind, WasmComponentValueDataKind.option);
            expect(option.index, 0);
            expect(option.label, 'none');
            expect(option.isSome, isFalse);
            expect(option.associatedValue, isNull);
            return _u32NoneValue();
          },
        },
      );

      expect(program.invokeFlat(0, const <Object?>[1, 31]), [1, 41]);
      expect(program.invokeFlat(1, const <Object?>[0, 999]), [0, 0]);
      expect(
        () => program.invokeFlat(0, const <Object?>[2, 0]),
        throwsStateError,
      );
      expect(() => program.invokeFlat(0, const <Object?>[1]), throwsStateError);
    });

    test('invokes result adapter programs through flat tag payload pairs', () {
      final component = WasmComponent.decode(
        canonicalU32ResultLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          1: (args) {
            final result = args.single! as WasmComponentValueData;
            expect(result.kind, WasmComponentValueDataKind.result);
            expect(result.index, 0);
            expect(result.label, 'ok');
            expect(result.isOk, isTrue);
            expect(result.associatedValue!.integer, 31);
            return _u32OkValue(41);
          },
        },
        componentFunctions: {
          0: (args) {
            final result = args.single! as WasmComponentValueData;
            expect(result.kind, WasmComponentValueDataKind.result);
            expect(result.index, 1);
            expect(result.label, 'error');
            expect(result.isOk, isFalse);
            expect(result.associatedValue!.integer, 7);
            return _u32ErrorValue(11);
          },
        },
      );

      expect(program.invokeFlat(0, const <Object?>[0, 31]), [0, 41]);
      expect(program.invokeFlat(1, const <Object?>[1, 7]), [1, 11]);
      expect(
        () => program.invokeFlat(0, const <Object?>[2, 0]),
        throwsStateError,
      );
      expect(() => program.invokeFlat(0, const <Object?>[0]), throwsStateError);
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

    test('invokes error-context adapter programs through flat handles', () {
      final component = WasmComponent.decode(
        canonicalErrorContextLiftLowerComponentBytes(),
      );
      final plans = componentCanonicalAdapterPlans(component);
      final host = const WASIComponentCanonicalAdapterHost();

      final program = host.bindAdapterPlans(
        plans,
        coreFunctions: {
          1: (args) {
            expect(args, [17]);
            return 19;
          },
        },
        componentFunctions: {
          0: (args) {
            expect(args, [23]);
            return 29;
          },
        },
      );

      expect(program.invokeFlat(0, const <Object?>[17]), [19]);
      expect(program.invokeFlat(1, const <Object?>[23]), [29]);
      expect(
        () => program.invokeFlat(0, const <Object?>[-1]),
        throwsStateError,
      );
      expect(
        () => program.invokeFlat(0, const <Object?>[0x100000000]),
        throwsStateError,
      );
      expect(program.invoke(0, const <Object?>[17]), 19);
      expect(program.invoke(1, const <Object?>[23]), 29);
      expect(() => program.invoke(0, const <Object?>[-1]), throwsStateError);
      expect(
        () => program.invoke(0, const <Object?>[0x100000000]),
        throwsStateError,
      );
      final memory = wasm.Memory(const wasm.MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 17, Endian.little);
      data.setUint32(40, 23, Endian.little);

      expect(
        program.invokeWithMemory(0, memory, const <int>[32], resultPointer: 36),
        19,
      );
      expect(data.getUint32(36, Endian.little), 19);
      expect(
        program.invokeWithMemory(1, memory, const <int>[40], resultPointer: 44),
        29,
      );
      expect(data.getUint32(44, Endian.little), 29);

      final operation = host.bindLiftCoreFunction(plans[0], (_) => 19);
      expect(operation.invoke(const <Object?>[17]), 19);
      expect(
        operation.invokeWithMemory(memory, const <int>[32], resultPointer: 48),
        19,
      );
      expect(data.getUint32(48, Endian.little), 19);
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
      expect(plan.canBindWithAdapters, isTrue);
      expect(plan.validationErrors, isEmpty);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.adapterPlans, hasLength(2));

      final program = plan.bindAdapters(
        coreFunctions: {0: (_) => 21},
        componentFunctions: {0: (_) => 22},
      );

      expect(program.operations, hasLength(2));
      expect(program.invoke(0, const <Object?>[]), 21);
      expect(program.invoke(1, const <Object?>[]), 22);
      final binding = plan.bind(
        coreFunctions: {0: (_) => 23},
        componentFunctions: {0: (_) => 24},
      );
      expect(binding.program.operations, hasLength(2));
      expect(binding.program.invoke(0, const <Object?>[]), 23);
      expect(binding.program.invoke(1, const <Object?>[]), 24);
      expect(() => plan.bind(), throwsStateError);
    });

    test('binds string adapters into unified component host programs', () {
      final component = WasmComponent.decode(
        canonicalStringLiftLowerComponentBytes(),
      );
      final host = WASIComponentHost();
      final memory = wasm.Memory(const wasm.MemoryDescriptor(initial: 1));
      final realloc = _bumpRealloc(memory);
      final input = writeWASIComponentCanonicalString(
        memory,
        realloc,
        'guest',
        WASIComponentCanonicalStringEncoding.utf8,
      );
      writeWASIComponentMemoryStringRecord(memory, 32, input);

      final plan = host.prepareComponent(component);
      final binding = plan.bind(
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

      final lifted = binding.program.invokeFlat(
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

      final lowered = binding.program.invokeFlat(
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
        binding.program.invokeWithMemory(
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
        binding.program.invokeWithMemory(
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
    });

    test('binds primitive adapter programs through Preview3 only', () {
      final component = WasmComponent.decode(
        canonicalPrimitiveLiftLowerComponentBytes(),
      );

      final preview3Plan = WASIPreview3ComponentHost().prepareComponent(
        component,
      );

      expect(preview3Plan.canBind, isFalse);
      expect(preview3Plan.canBindWithAdapters, isTrue);
      expect(preview3Plan.versionErrors, isEmpty);
      expect(preview3Plan.unsupportedDefinitions, isEmpty);
      expect(preview3Plan.adapterPlans, hasLength(2));

      final program = preview3Plan.bindAdapters(
        coreFunctions: {0: (_) => 31},
        componentFunctions: {0: (_) => 32},
      );

      expect(program.invoke(0, const <Object?>[]), 31);
      expect(program.invoke(1, const <Object?>[]), 32);
      final binding = preview3Plan.bind(
        coreFunctions: {0: (_) => 33},
        componentFunctions: {0: (_) => 34},
      );
      expect(binding.program.invoke(0, const <Object?>[]), 33);
      expect(binding.program.invoke(1, const <Object?>[]), 34);

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
      expect(adapter.params[0].hasMemoryCodec, isTrue);
      expect(adapter.params[0].byteLength, 4);
      expect(adapter.params[0].alignment, 4);
      expect(
        adapter.params[0].resourceUses.single.handleKind,
        WASIComponentResourceHandleKind.own,
      );
      expect(adapter.params[0].flatLength, 1);
      expect(
        adapter.params[0].flatLayout!.kind,
        WASIComponentCanonicalAdapterFlatValueKind.resource,
      );
      expect(
        adapter.params[0].flatLayout!.handleKind,
        WASIComponentResourceHandleKind.own,
      );
      expect(
        adapter.params[0].flatLayout!.resourceTypeIndex,
        adapter.params[0].resourceUses.single.resourceTypeIndex,
      );

      expect(adapter.params[1].path, 'canonical[0].param[1].borrowed');
      expect(adapter.params[1].label, 'borrowed');
      expect(adapter.params[1].hasMemoryCodec, isTrue);
      expect(adapter.params[1].byteLength, 4);
      expect(adapter.params[1].alignment, 4);
      expect(
        adapter.params[1].resourceUses.single.handleKind,
        WASIComponentResourceHandleKind.borrow,
      );
      expect(adapter.params[1].flatLength, 1);
      expect(
        adapter.params[1].flatLayout!.kind,
        WASIComponentCanonicalAdapterFlatValueKind.resource,
      );
      expect(
        adapter.params[1].flatLayout!.handleKind,
        WASIComponentResourceHandleKind.borrow,
      );
      expect(
        adapter.params[1].flatLayout!.resourceTypeIndex,
        adapter.params[1].resourceUses.single.resourceTypeIndex,
      );

      expect(adapter.result, isNotNull);
      expect(adapter.result!.path, 'canonical[0].result');
      expect(adapter.result!.hasMemoryCodec, isTrue);
      expect(adapter.result!.byteLength, 4);
      expect(adapter.result!.alignment, 4);
      expect(
        adapter.result!.resourceUses.single.handleKind,
        WASIComponentResourceHandleKind.own,
      );
      expect(adapter.result!.flatLength, 1);
      expect(
        adapter.result!.flatLayout!.kind,
        WASIComponentCanonicalAdapterFlatValueKind.resource,
      );
      expect(
        adapter.result!.flatLayout!.handleKind,
        WASIComponentResourceHandleKind.own,
      );
      expect(
        adapter.result!.flatLayout!.resourceTypeIndex,
        adapter.result!.resourceUses.single.resourceTypeIndex,
      );

      final operation = host.componentHost.canonicalHost.adapterHost
          .bindLiftCoreFunction(adapter, (args) {
            expect(args, [101, 202]);
            return 303;
          });

      expect(operation.invoke(const <Object?>[101, 202]), 303);
      final memory = wasm.Memory(const wasm.MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 101, Endian.little);
      data.setUint32(36, 202, Endian.little);
      expect(
        operation.invokeWithMemory(memory, const <int>[
          32,
          36,
        ], resultPointer: 40),
        303,
      );
      expect(data.getUint32(40, Endian.little), 303);
      expect(
        () => operation.invoke(const <Object?>[-1, 202]),
        throwsStateError,
      );
      expect(
        () => operation.invoke(const <Object?>[0x100000000, 202]),
        throwsStateError,
      );

      final program = host.componentHost.canonicalHost.adapterHost
          .bindAdapterPlans(
            plan.adapterPlans,
            coreFunctions: {
              adapter.definition.coreFunctionIndex!: (args) {
                expect(args, [101, 202]);
                return 303;
              },
            },
          );

      expect(program.invokeFlat(0, const <Object?>[101, 202]), [303]);
      expect(program.invoke(0, const <Object?>[101, 202]), 303);
      expect(
        program.invokeWithMemory(0, memory, const <int>[
          32,
          36,
        ], resultPointer: 44),
        303,
      );
      expect(data.getUint32(44, Endian.little), 303);
      expect(
        () => program.invokeFlat(0, const <Object?>[-1, 202]),
        throwsStateError,
      );
      expect(
        () => program.invokeFlat(0, const <Object?>[0x100000000, 202]),
        throwsStateError,
      );
      expect(
        () => host.componentHost.canonicalHost.adapterHost
            .bindLiftCoreFunction(adapter, (_) => -1)
            .invokeWithMemory(memory, const <int>[32, 36], resultPointer: 48),
        throwsStateError,
      );
      expect(
        () => host.componentHost.canonicalHost.adapterHost
            .bindLiftCoreFunction(adapter, (_) => 0x100000000)
            .invokeWithMemory(memory, const <int>[32, 36], resultPointer: 48),
        throwsStateError,
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

WasmComponentValueData _u32ListValue(List<int> values) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      for (final value in values)
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: value,
        ),
    ],
  );
}

WasmComponentValueData _u32CompositeValue(
  WasmComponentValueDataKind kind,
  List<int> values,
) {
  return WasmComponentValueData(
    kind: kind,
    rawBytes: Uint8List(0),
    items: [
      for (final value in values)
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: value,
        ),
    ],
  );
}

WasmComponentValueData _u32VariantValue({
  int? index,
  String? label,
  int? value,
}) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: index,
    label: label,
    associatedValue: value == null
        ? null
        : WasmComponentValueData(
            kind: WasmComponentValueDataKind.integer,
            rawBytes: Uint8List(0),
            integer: value,
          ),
  );
}

WasmComponentValueData _u32SomeValue(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    isSome: true,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.integer,
      rawBytes: Uint8List(0),
      integer: value,
    ),
  );
}

WasmComponentValueData _u32NoneValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    isSome: false,
  );
}

WasmComponentValueData _u32OkValue(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    isOk: true,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.integer,
      rawBytes: Uint8List(0),
      integer: value,
    ),
  );
}

WasmComponentValueData _u32ErrorValue(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    isOk: false,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.integer,
      rawBytes: Uint8List(0),
      integer: value,
    ),
  );
}

void _writeU32List(wasm.Memory memory, int pointer, List<int> values) {
  final data = ByteData.view(memory.buffer);
  for (var i = 0; i < values.length; i++) {
    data.setUint32(pointer + i * 4, values[i], Endian.little);
  }
}

List<int> _readU32List(wasm.Memory memory, int pointer, int length) {
  final data = ByteData.view(memory.buffer);
  return List<int>.generate(
    length,
    (index) => data.getUint32(pointer + index * 4, Endian.little),
    growable: false,
  );
}
