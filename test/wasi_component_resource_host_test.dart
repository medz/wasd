import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('WASIComponentResourceHost', () {
    test(
      'binds decoded canonical resource operations to the resource table',
      () {
        final component = WasmComponent.decode(_canonicalResourceNewBytes());
        final host = WASIComponentResourceHost();
        final dropped = <int>[];
        host.defineResourceType<int>(0, 'descriptor', onDrop: dropped.add);

        final newOperation = host.bindCanonicalDefinition(
          component.canonicalDefinitions.single,
        );
        final repOperation = host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.resourceRep,
            typeIndex: 0,
          ),
        );
        final dropOperation = host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.resourceDrop,
            typeIndex: 0,
          ),
        );

        final handle = newOperation.resourceNew(9);

        expect(repOperation.resourceRep(handle), 9);
        expect(() => newOperation.resourceRep(handle), throwsStateError);
        dropOperation.resourceDrop(handle);
        expect(dropped, [9]);
        expect(() => repOperation.resourceRep(handle), throwsStateError);
      },
    );

    test('rejects unbound type indexes and non-resource definitions', () {
      final host = WASIComponentResourceHost();

      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.resourceNew,
            typeIndex: 0,
          ),
        ),
        throwsStateError,
      );

      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.lower,
            functionIndex: 0,
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('rejects representation values with the wrong host type', () {
      final host = WASIComponentResourceHost();
      host.defineResourceType<int>(0, 'descriptor');
      final operation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.resourceNew,
          typeIndex: 0,
        ),
      );

      expect(() => operation.resourceNew('bad'), throwsStateError);
    });
  });
}

Uint8List _canonicalResourceNewBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x04,
  0x01,
  0x3f,
  0x7f,
  0x00,
  0x08,
  0x03,
  0x01,
  0x02,
  0x00,
]);
