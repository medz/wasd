import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
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

    test('reports async value memory layouts before binding', () {
      final u32Component = WasmComponent.decode(_streamU32TypeComponentBytes());
      final stringComponent = WasmComponent.decode(
        _streamStringTypeComponentBytes(),
      );
      final host = WASIComponentHost();

      final u32Plan = host.prepareComponent(u32Component);
      final stringPlan = host.prepareComponent(stringComponent);

      expect(u32Plan.canBind, isTrue);
      expect(u32Plan.asyncValueBindings, hasLength(1));
      expect(
        u32Plan.asyncValueBindings.single.kind,
        WASIComponentAsyncValueBindingKind.stream,
      );
      expect(
        u32Plan.asyncValueBindings.single.primitive,
        WasmComponentPrimitiveValueType.u32,
      );
      expect(
        u32Plan.asyncValueBindings.single.fixedWidthMemoryLayout,
        isNotNull,
      );
      expect(
        u32Plan.asyncValueBindings.single.fixedWidthMemoryLayout!.byteLength,
        4,
      );
      expect(
        u32Plan.asyncValueBindings.single.fixedWidthMemoryLayout!.alignment,
        4,
      );

      expect(stringPlan.canBind, isTrue);
      expect(stringPlan.asyncValueBindings, hasLength(1));
      expect(
        stringPlan.asyncValueBindings.single.primitive,
        WasmComponentPrimitiveValueType.string,
      );
      expect(
        stringPlan.asyncValueBindings.single.fixedWidthMemoryLayout,
        isNull,
      );
    });

    test('binds decoded stream async values before canonical builtins', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      final host = WASIComponentHost();
      final dropped = <String>[];

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.validationErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(
        plan.asyncValueBindings.single.kind,
        WASIComponentAsyncValueBindingKind.stream,
      );
      expect(plan.asyncValueBindings.single.isUnit, isTrue);

      final binding = plan.bind(
        asyncValueName: (value) => 'component-${value.name}',
        onAsyncValueDrop: (value) => dropped.add(value.name),
      );

      expect(binding.asyncValueBindings.single.name, 'stream[0]');

      final packed = binding.program.invoke(0, const <Object?>[])! as int;
      final handles = WASIComponentAsyncEndpointHandles.unpack(packed);

      expect(
        binding.program.invoke(2, <Object?>[
          handles.writable,
          <Object?>[null, null],
        ]),
        2,
      );
      expect(
        binding.program.invoke(1, <Object?>[handles.readable, 1]),
        <Object?>[null],
      );
      expect(
        binding.program.invoke(1, <Object?>[handles.readable, 2]),
        <Object?>[null],
      );

      expect(binding.program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(dropped, isEmpty);
      expect(binding.program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(dropped, ['stream[0]']);
      expect(host.table.activeCount, 0);
    });

    test('binds decoded future async values before canonical builtins', () {
      final component = WasmComponent.decode(_canonicalFutureProgramBytes());
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(
        plan.asyncValueBindings.single.kind,
        WASIComponentAsyncValueBindingKind.future,
      );
      expect(plan.asyncValueBindings.single.isUnit, isTrue);

      final binding = plan.bind();
      final packed = binding.program.invoke(0, const <Object?>[])! as int;
      final handles = WASIComponentAsyncEndpointHandles.unpack(packed);

      expect(
        binding.program.invoke(2, <Object?>[handles.writable, null]),
        isNull,
      );
      expect(binding.program.invoke(1, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('reports unsupported composite stream bindings before binding', () {
      final component = WasmComponent.decode(
        _streamIndexedCompositeCanonicalBytes(),
      );
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isFalse);
      expect(plan.asyncValueBindings, isEmpty);
      expect(plan.bindingErrors, hasLength(1));
      expect(plan.bindingErrors.single.canonicalIndex, 0);
      expect(
        plan.bindingErrors.single.kind,
        WasmComponentCanonicalKind.streamNew,
      );
      expect(
        () => plan.bind(),
        throwsA(
          isA<WASIComponentHostBindingException>().having(
            (error) => error.toString(),
            'message',
            contains('supported stream/future async value binding'),
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

Uint8List _streamU32TypeComponentBytes() => Uint8List.fromList(const <int>[
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
  0x66,
  0x01,
  0x79,
]);

Uint8List _streamStringTypeComponentBytes() => Uint8List.fromList(const <int>[
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
  0x66,
  0x01,
  0x73,
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

Uint8List _canonicalFutureProgramBytes() => Uint8List.fromList(const <int>[
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
  0x65,
  0x00,
  0x08,
  0x13,
  0x07,
  0x15,
  0x00,
  0x16,
  0x00,
  0x00,
  0x17,
  0x00,
  0x00,
  0x18,
  0x00,
  0x00,
  0x19,
  0x00,
  0x00,
  0x1a,
  0x00,
  0x1b,
  0x00,
]);

Uint8List _streamIndexedCompositeCanonicalBytes() =>
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
      0x06,
      0x02,
      0x70,
      0x73,
      0x66,
      0x01,
      0x00,
      0x08,
      0x03,
      0x01,
      0x0e,
      0x01,
    ]);
