import 'dart:async';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/context.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('WASIComponentContextHost', () {
    test('gets zero-initialized slots and sets i32 bit patterns', () {
      final host = WASIComponentContextHost();
      final get0 = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextGet,
          contextIndex: 0,
        ),
      );
      final set0 = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextSet,
          contextIndex: 0,
        ),
      );
      final get1 = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextGet,
          contextIndex: 1,
        ),
      );

      expect(get0.contextGet(), 0);
      expect(get1.contextGet(), 0);

      set0.contextSet(0xffffffff);

      expect(get0.contextGet(), 0xffffffff);
      expect(get1.contextGet(), 0);
    });

    test('invokes context programs by canonical definition order', () {
      final host = WASIComponentContextHost();
      final program = WASIComponentCanonicalContextProgram(
        operations: [
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.contextSet,
              contextIndex: 0,
            ),
          ),
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.contextGet,
              contextIndex: 0,
            ),
          ),
        ],
      );

      expect(program.invoke(0, <Object?>[1234]), isNull);
      expect(program.invoke(1, const <Object?>[]), 1234);
    });

    test('scopes current context synchronously and asynchronously', () async {
      final host = WASIComponentContextHost();
      final outerSet = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextSet,
          contextIndex: 0,
        ),
      );
      final outerGet = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextGet,
          contextIndex: 0,
        ),
      );
      final nested = WASIComponentContext(name: 'nested', initialSlots: [77]);

      outerSet.contextSet(11);

      expect(
        host.runWithContext(nested, () {
          expect(outerGet.contextGet(), 77);
          outerSet.contextSet(88);
          return outerGet.contextGet();
        }),
        88,
      );
      expect(nested.get(0), 88);
      expect(outerGet.contextGet(), 11);

      await expectLater(
        host.runWithContextAsync(nested, () async {
          await Future<void>.delayed(Duration.zero);
          return outerGet.contextGet();
        }),
        completion(88),
      );
      expect(outerGet.contextGet(), 11);
    });

    test('validates context indexes, values, and invocation arity', () {
      final host = WASIComponentContextHost();
      final set0 = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextSet,
          contextIndex: 0,
        ),
      );
      final program = WASIComponentCanonicalContextProgram(operations: [set0]);

      expect(() => set0.contextSet(-1), throwsRangeError);
      expect(() => set0.contextSet(0x100000000), throwsRangeError);
      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.contextGet,
            contextIndex: wasiComponentContextSlotCount,
          ),
        ),
        throwsStateError,
      );
      expect(() => program.invoke(0, const <Object?>[]), throwsStateError);
      expect(() => program.invoke(0, <Object?>[-1]), throwsStateError);
      expect(() => program.invoke(9, const <Object?>[]), throwsStateError);
    });

    test('rejects non-context canonical definitions', () {
      final host = WASIComponentContextHost();

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
