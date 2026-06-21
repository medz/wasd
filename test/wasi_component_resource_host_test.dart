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
        host.defineResourceTypeFromComponent<int>(
          component,
          0,
          'descriptor',
          onDrop: dropped.add,
        );

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

    test('binds decoded canonical resource definitions as a program', () {
      final component = WasmComponent.decode(_canonicalResourceProgramBytes());
      final host = WASIComponentResourceHost();
      final dropped = <int>[];
      host.defineResourceTypeFromComponent<int>(
        component,
        0,
        'descriptor',
        onDrop: dropped.add,
      );

      final program = host.bindCanonicalDefinitions(component);

      expect(program.operations, hasLength(3));
      expect(program.operations.map((operation) => operation.kind), [
        WasmComponentCanonicalKind.resourceNew,
        WasmComponentCanonicalKind.resourceRep,
        WasmComponentCanonicalKind.resourceDrop,
      ]);
      expect(() => program.operations.clear(), throwsUnsupportedError);

      final handle = program.operations[0].resourceNew(21);

      expect(program.operations[1].resourceRep(handle), 21);
      program.operations[2].resourceDrop(handle);
      expect(dropped, [21]);
    });

    test('invokes decoded canonical resource program operations by index', () {
      final component = WasmComponent.decode(_canonicalResourceProgramBytes());
      final host = WASIComponentResourceHost();
      final dropped = <int>[];
      host.defineResourceTypeFromComponent<int>(
        component,
        0,
        'descriptor',
        onDrop: dropped.add,
      );
      final program = host.bindCanonicalDefinitions(component);

      final handle = program.invoke(0, <Object?>[34]);

      expect(handle, isA<int>());
      expect(program.invoke(1, <Object?>[handle]), 34);
      expect(program.invoke(2, <Object?>[handle]), isNull);
      expect(dropped, [34]);
      expect(() => program.invoke(3, const <Object?>[]), throwsStateError);
      expect(() => program.invoke(0, const <Object?>[]), throwsStateError);
      expect(() => program.invoke(1, const <Object?>['bad']), throwsStateError);
    });

    test('rejects non-resource canonical definitions in resource programs', () {
      final component = WasmComponent.decode(_canonicalMixedResourceBytes());
      final host = WASIComponentResourceHost();
      host.defineResourceTypeFromComponent<int>(component, 0, 'descriptor');

      expect(
        () => host.bindCanonicalDefinitions(component),
        throwsUnsupportedError,
      );
    });

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

    test('rejects missing decoded resource type indexes', () {
      final component = WasmComponent.decode(_canonicalResourceNewBytes());
      final host = WASIComponentResourceHost();

      expect(
        () =>
            host.defineResourceTypeFromComponent<int>(component, 1, 'missing'),
        throwsStateError,
      );
    });

    test('rejects values outside decoded i32 resource representation', () {
      final component = WasmComponent.decode(_canonicalResourceNewBytes());
      final host = WASIComponentResourceHost();
      host.defineResourceTypeFromComponent<int>(component, 0, 'descriptor');
      final operation = host.bindCanonicalDefinition(
        component.canonicalDefinitions.single,
      );
      final dropOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.resourceDrop,
          typeIndex: 0,
        ),
      );

      final maxHandle = operation.resourceNew(0x7fffffff);
      final minHandle = operation.resourceNew(-0x80000000);

      expect(maxHandle, isA<int>());
      expect(minHandle, isA<int>());
      expect(() => operation.resourceNew(0x80000000), throwsStateError);
      expect(() => operation.resourceNew(-0x80000001), throwsStateError);
      dropOperation.resourceDrop(maxHandle);
      dropOperation.resourceDrop(minHandle);
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

Uint8List _canonicalResourceProgramBytes() => Uint8List.fromList(const <int>[
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
  0x07,
  0x03,
  0x02,
  0x00,
  0x04,
  0x00,
  0x03,
  0x00,
]);

Uint8List _canonicalMixedResourceBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x08,
  0x02,
  0x3f,
  0x7f,
  0x00,
  0x40,
  0x00,
  0x01,
  0x00,
  0x08,
  0x07,
  0x02,
  0x02,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
]);
