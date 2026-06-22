import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/adapter_host.dart';
import 'package:wasd/src/wasi/component/adapter_plan.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasi/component/string_memory.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

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
