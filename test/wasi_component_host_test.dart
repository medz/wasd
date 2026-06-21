import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('WASIComponentHost', () {
    test('binds component resources and canonical builtins together', () {
      final component = WasmComponent.decode(_canonicalResourceProgramBytes());
      final host = WASIComponentHost();
      final dropped = <int>[];

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isTrue);
      expect(plan.validationErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.resourceBindings, hasLength(1));
      expect(plan.resourceBindings.single.componentTypeIndex, 0);
      expect(
        plan.resourceBindings.single.representation,
        WASIComponentResourceRepresentation.i32,
      );

      final binding = plan.bind(
        resourceName: (resource) => 'component-${resource.name}',
        onResourceDrop: (resource, value) {
          expect(resource.componentTypeIndex, 0);
          dropped.add(value as int);
        },
      );

      expect(binding.host, same(host));
      expect(binding.resourceTypes.single.name, 'component-resource[0]');

      final handle = binding.program.invoke(0, <Object?>[321]);

      expect(binding.program.invoke(1, <Object?>[handle]), 321);
      expect(binding.program.invoke(2, <Object?>[handle]), isNull);
      expect(dropped, [321]);
      expect(host.table.activeCount, 0);
    });

    test('does not bind resources when canonical capabilities are missing', () {
      final component = WasmComponent.decode(_canonicalMixedResourceBytes());
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component, validate: false);

      expect(plan.validationErrors, isEmpty);
      expect(plan.resourceBindings, hasLength(1));
      expect(plan.unsupportedDefinitions, hasLength(1));
      expect(plan.canBind, isFalse);
      expect(
        () => plan.bind(),
        throwsA(isA<WASIComponentCanonicalHostUnsupportedException>()),
      );
      expect(
        () => host.canonicalHost.resourceHost.defineResourceType<int>(
          0,
          'manual-resource',
        ),
        returnsNormally,
      );
    });

    test('reports missing stream and future binding state before binding', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isFalse);
      expect(plan.validationErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.bindingErrors, hasLength(7));
      expect(plan.bindingErrors.first.canonicalIndex, 0);
      expect(
        plan.bindingErrors.first.kind,
        WasmComponentCanonicalKind.streamNew,
      );
      expect(
        () => plan.bind(),
        throwsA(
          isA<WASIComponentHostBindingException>()
              .having((error) => error.errors, 'errors', hasLength(7))
              .having(
                (error) => error.toString(),
                'message',
                contains('stream/future async value bindings'),
              ),
        ),
      );
    });
  });
}

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

Uint8List _canonicalStreamProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x03,
  0x01,
  0x66,
  0x00,
  0x08,
  0x13,
  0x07,
  0x0e,
  0x00,
  0x0f,
  0x00,
  0x00,
  0x10,
  0x00,
  0x00,
  0x11,
  0x00,
  0x00,
  0x12,
  0x00,
  0x00,
  0x13,
  0x00,
  0x14,
  0x00,
]);
