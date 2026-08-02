import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

import 'support/component_fixtures.dart';

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

    test('binds canonical operations for imported abstract resources', () {
      final component = WasmComponent.decode(
        _importedResourceCanonicalProgramBytes(),
      );
      expect(component.validate(), isEmpty);
      final host = WASIComponentResourceHost();
      final dropped = <int>[];
      final bindings = host.componentResourceBindings(component);

      expect(bindings, hasLength(1));
      expect(bindings.single.componentTypeIndex, 0);
      expect(bindings.single.name, 'resource[0]');
      expect(bindings.single.isAbstract, isTrue);
      expect(
        bindings.single.representation,
        WASIComponentResourceRepresentation.unconstrained,
      );

      final types = host.defineComponentResourceTypes<int>(
        component,
        nameForBinding: (binding) => 'imported-${binding.name}',
        onDrop: (binding, resource) {
          expect(binding.componentTypeIndex, 0);
          dropped.add(resource);
        },
      );

      expect(types.single.name, 'imported-resource[0]');

      final program = host.bindCanonicalDefinitions(component);
      final handle = program.invoke(0, <Object?>[55]);

      expect(program.invoke(1, <Object?>[handle]), 55);
      expect(program.invoke(2, <Object?>[handle]), isNull);
      expect(dropped, [55]);
    });

    test('keeps imported abstract resource types nominally distinct', () {
      final component = WasmComponent.decode(_twoImportedResourceTypesBytes());

      expect(component.validate(), isEmpty);
      final definitions = component.componentTypeIndexDefinitions;
      expect(definitions, hasLength(2));
      expect(
        definitions.every((definition) => definition.resource!.isAbstract),
        isTrue,
      );
      expect(identical(definitions[0], definitions[1]), isFalse);
      expect(
        WASIComponentResourceHost()
            .componentResourceBindings(component)
            .map((binding) => binding.componentTypeIndex),
        [0, 1],
      );
    });

    test('plans and binds all decoded component resource types', () {
      final component = WasmComponent.decode(_canonicalResourceProgramBytes());
      expect(component.validate(), isEmpty);
      final host = WASIComponentResourceHost();
      final bindings = host.componentResourceBindings(component);

      expect(bindings, hasLength(1));
      expect(bindings.single.componentTypeIndex, 0);
      expect(bindings.single.name, 'resource[0]');
      expect(bindings.single.isAbstract, isFalse);
      expect(
        bindings.single.representation,
        WASIComponentResourceRepresentation.i32,
      );
      expect(
        () => bindings.add(
          const WASIComponentResourceBinding(
            componentTypeIndex: 1,
            name: 'resource[1]',
            representation: WASIComponentResourceRepresentation.unconstrained,
            isAbstract: true,
          ),
        ),
        throwsUnsupportedError,
      );

      final dropped = <int>[];
      final types = host.defineComponentResourceTypes<int>(
        component,
        onDrop: (binding, resource) {
          expect(
            binding.representation,
            WASIComponentResourceRepresentation.i32,
          );
          dropped.add(resource);
        },
      );

      expect(types.single.name, 'resource[0]');

      final program = host.bindCanonicalDefinitions(component);
      final handle = program.invoke(0, <Object?>[123]);

      expect(program.invoke(1, <Object?>[handle]), 123);
      expect(program.invoke(2, <Object?>[handle]), isNull);
      expect(dropped, [123]);
    });

    test('reports canonical lift resource handle uses', () {
      final component = WasmComponent.decode(
        canonicalResourceLiftComponentBytes(),
      );
      expect(component.validate(), isEmpty);
      final host = WASIComponentResourceHost();

      final uses = host.componentCanonicalResourceUses(component);

      expect(uses, hasLength(3));
      expect(() => uses.clear(), throwsUnsupportedError);
      expect(uses.map((use) => use.canonicalIndex), [0, 0, 0]);
      expect(uses.map((use) => use.canonicalKind), [
        WasmComponentCanonicalKind.lift,
        WasmComponentCanonicalKind.lift,
        WasmComponentCanonicalKind.lift,
      ]);
      expect(uses.map((use) => use.path), [
        'canonical[0].param[0].owned',
        'canonical[0].param[1].borrowed',
        'canonical[0].result',
      ]);
      expect(uses.map((use) => use.handleKind), [
        WASIComponentResourceHandleKind.own,
        WASIComponentResourceHandleKind.borrow,
        WASIComponentResourceHandleKind.own,
      ]);
      expect(uses.map((use) => use.resourceTypeIndex), [0, 0, 0]);
      expect(uses.map((use) => use.binding?.componentTypeIndex), [0, 0, 0]);
      expect(uses.map((use) => use.binding?.representation), [
        WASIComponentResourceRepresentation.i32,
        WASIComponentResourceRepresentation.i32,
        WASIComponentResourceRepresentation.i32,
      ]);
      expect(uses.every((use) => use.binding?.isAbstract == false), isTrue);
    });

    test('does not report resource operations as adapter handle uses', () {
      final component = WasmComponent.decode(_canonicalResourceProgramBytes());
      final host = WASIComponentResourceHost();

      expect(host.componentCanonicalResourceUses(component), isEmpty);
    });

    test(
      'rejects duplicate prepared bindings before defining resource types',
      () {
        final host = WASIComponentResourceHost();
        final bindings = const [
          WASIComponentResourceBinding(
            componentTypeIndex: 0,
            name: 'first',
            representation: WASIComponentResourceRepresentation.unconstrained,
            isAbstract: true,
          ),
          WASIComponentResourceBinding(
            componentTypeIndex: 0,
            name: 'duplicate',
            representation: WASIComponentResourceRepresentation.unconstrained,
            isAbstract: true,
          ),
        ];

        expect(
          () => host.defineResourceBindings<int>(bindings),
          throwsStateError,
        );
        expect(
          () => host.defineResourceType<int>(0, 'manual-resource'),
          returnsNormally,
        );
      },
    );

    test(
      'binds canonical operations for aliased instance resource exports',
      () {
        final component = WasmComponent.decode(
          _aliasedInstanceResourceCanonicalProgramBytes(),
        );
        expect(component.validate(), isEmpty);
        final host = WASIComponentResourceHost();
        final dropped = <int>[];
        host.defineResourceTypeFromComponent<int>(
          component,
          1,
          'aliased-resource',
          onDrop: dropped.add,
        );

        final program = host.bindCanonicalDefinitions(component);
        final handle = program.invoke(0, <Object?>[89]);

        expect(program.invoke(1, <Object?>[handle]), 89);
        expect(program.invoke(2, <Object?>[handle]), isNull);
        expect(dropped, [89]);
      },
    );

    test(
      'binds canonical operations for instantiated component resource aliases',
      () {
        final component = WasmComponent.decode(
          _instantiatedComponentResourceAliasCanonicalProgramComponentBytes(),
        );
        expect(component.validate(), isEmpty);
        final host = WASIComponentResourceHost();
        final dropped = <int>[];
        host.defineResourceTypeFromComponent<int>(
          component,
          0,
          'instantiated-resource',
          onDrop: dropped.add,
        );

        final program = host.bindCanonicalDefinitions(component);
        final handle = program.invoke(0, <Object?>[144]);

        expect(program.invoke(1, <Object?>[handle]), 144);
        expect(program.invoke(2, <Object?>[handle]), isNull);
        expect(dropped, [144]);
      },
    );

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

Uint8List _importedResourceCanonicalProgramBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x0a,
      0x06,
      0x01,
      0x00,
      0x01,
      0x72,
      0x03,
      0x01,
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

Uint8List _twoImportedResourceTypesBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x0b,
  0x02,
  0x00,
  0x01,
  0x61,
  0x03,
  0x01,
  0x00,
  0x01,
  0x62,
  0x03,
  0x01,
]);

Uint8List _aliasedInstanceResourceCanonicalProgramBytes() =>
    Uint8List.fromList(const <int>[
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
      0x05,
      0x08,
      0x01,
      0x01,
      0x01,
      0x00,
      0x01,
      0x72,
      0x03,
      0x00,
      0x06,
      0x06,
      0x01,
      0x03,
      0x00,
      0x00,
      0x01,
      0x72,
      0x08,
      0x07,
      0x03,
      0x02,
      0x01,
      0x04,
      0x01,
      0x03,
      0x01,
    ]);

Uint8List _instantiatedComponentResourceAliasCanonicalProgramComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x04,
      0x17,
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
      0x0b,
      0x07,
      0x01,
      0x00,
      0x01,
      0x72,
      0x03,
      0x00,
      0x00,
      0x05,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x06,
      0x06,
      0x01,
      0x03,
      0x00,
      0x00,
      0x01,
      0x72,
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
