import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/versioned_host.dart';
import 'package:wasd/src/wasi/preview2/component_host.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasi/version.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('WASIComponentVersionProfile', () {
    test('describes component canonical areas by WASI version', () {
      expect(WASIComponentVersionProfile.preview1.canonicalAreas, isEmpty);
      expect(
        WASIComponentVersionProfile.preview2.canonicalAreas,
        containsAll(<WASIComponentCanonicalCapabilityArea>[
          WASIComponentCanonicalCapabilityArea.adapterGeneration,
          WASIComponentCanonicalCapabilityArea.resource,
        ]),
      );
      expect(
        WASIComponentVersionProfile.preview2.canonicalAreas,
        isNot(contains(WASIComponentCanonicalCapabilityArea.asyncValue)),
      );
      expect(
        WASIComponentVersionProfile.preview3.canonicalAreas,
        containsAll(<WASIComponentCanonicalCapabilityArea>[
          WASIComponentCanonicalCapabilityArea.asyncValue,
          WASIComponentCanonicalCapabilityArea.waitable,
          WASIComponentCanonicalCapabilityArea.threadScheduling,
        ]),
      );
      expect(
        () => WASIComponentVersionProfile.preview3.canonicalAreas.add(
          WASIComponentCanonicalCapabilityArea.resource,
        ),
        throwsUnsupportedError,
      );
      expect(
        WASIComponentVersionProfile.forVersion(WASIVersion.preview3),
        same(WASIComponentVersionProfile.preview3),
      );
    });
  });

  group('WASIComponentVersionedHost', () {
    test('rejects component canonical definitions for Preview1', () {
      final component = WasmComponent.decode(_canonicalResourceProgramBytes());
      final host = WASIComponentVersionedHost(version: WASIVersion.preview1);

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isFalse);
      expect(plan.validationErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.versionErrors, hasLength(3));
      expect(
        plan.versionErrors.map((error) => error.kind),
        <WasmComponentCanonicalKind>[
          WasmComponentCanonicalKind.resourceNew,
          WasmComponentCanonicalKind.resourceRep,
          WasmComponentCanonicalKind.resourceDrop,
        ],
      );
      expect(
        () => plan.bind(),
        throwsA(
          isA<WASIComponentVersionUnsupportedException>()
              .having((error) => error.errors, 'errors', hasLength(3))
              .having(
                (error) => error.toString(),
                'message',
                contains('WASI Preview1'),
              ),
        ),
      );
      expect(host.componentHost.table.activeCount, 0);
    });

    test('binds Preview2 resource components through the shared host', () {
      final component = WasmComponent.decode(_canonicalResourceProgramBytes());
      final host = WASIComponentVersionedHost(version: WASIVersion.preview2);
      final dropped = <int>[];

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isTrue);
      expect(plan.versionErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.bindingErrors, isEmpty);

      final binding = plan.bind(
        onResourceDrop: (_, resource) => dropped.add(resource as int),
      );
      final handle = binding.program.invoke(0, <Object?>[123]);

      expect(binding.program.invoke(1, <Object?>[handle]), 123);
      expect(binding.program.invoke(2, <Object?>[handle]), isNull);
      expect(dropped, [123]);
      expect(host.componentHost.table.activeCount, 0);
    });

    test('rejects Preview2 async stream canonical definitions', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      final componentHost = WASIComponentHost();
      final host = WASIComponentVersionedHost(
        version: WASIVersion.preview2,
        componentHost: componentHost,
      );

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isFalse);
      expect(plan.validationErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.versionErrors, hasLength(7));
      expect(plan.versionErrors.map((error) => error.capability.area).toSet(), {
        WASIComponentCanonicalCapabilityArea.asyncValue,
      });
      expect(
        plan.versionErrors.map((error) => error.kind),
        <WasmComponentCanonicalKind>[
          WasmComponentCanonicalKind.streamNew,
          WasmComponentCanonicalKind.streamRead,
          WasmComponentCanonicalKind.streamWrite,
          WasmComponentCanonicalKind.streamCancelRead,
          WasmComponentCanonicalKind.streamCancelWrite,
          WasmComponentCanonicalKind.streamDropReadable,
          WasmComponentCanonicalKind.streamDropWritable,
        ],
      );
      expect(
        () => plan.bind(),
        throwsA(
          isA<WASIComponentVersionUnsupportedException>()
              .having((error) => error.errors, 'errors', hasLength(7))
              .having(
                (error) => error.toString(),
                'message',
                allOf(contains('WASI 0.2 / Preview2'), contains('streamNew')),
              ),
        ),
      );
      expect(componentHost.table.activeCount, 0);
    });

    test('allows Preview3 async stream components through the profile', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      final host = WASIComponentVersionedHost(version: WASIVersion.preview3);

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isTrue);
      expect(plan.versionErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);

      final binding = plan.bind();
      final handles = WASIComponentAsyncEndpointHandles.unpack(
        binding.program.invoke(0, const <Object?>[])! as int,
      );

      expect(binding.asyncValueBindings, hasLength(1));
      expect(host.componentHost.table.activeCount, 2);
      expect(binding.program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.componentHost.table.activeCount, 0);
    });

    test('keeps Preview3 host capability gaps separate from version gates', () {
      final component = WasmComponent.decode(_canonicalMixedResourceBytes());
      final host = WASIComponentVersionedHost(version: WASIVersion.preview3);

      final plan = host.prepareComponent(component, validate: false);

      expect(plan.canBind, isFalse);
      expect(plan.versionErrors, isEmpty);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.unsupportedDefinitions, hasLength(1));
      expect(
        plan.unsupportedDefinitions.single.kind,
        WasmComponentCanonicalKind.lower,
      );
      expect(
        () => plan.bind(),
        throwsA(isA<WASIComponentCanonicalHostUnsupportedException>()),
      );
      expect(host.componentHost.table.activeCount, 0);
    });
  });

  group('fixed WASI component host versions', () {
    test('Preview2 wrapper enforces the Preview2 profile', () {
      final resourceComponent = WasmComponent.decode(
        _canonicalResourceProgramBytes(),
      );
      final streamComponent = WasmComponent.decode(
        _canonicalStreamProgramBytes(),
      );
      final sharedHost = WASIComponentHost();
      final host = WASIPreview2ComponentHost(componentHost: sharedHost);

      expect(host.profile, same(WASIComponentVersionProfile.preview2));
      expect(host.componentHost, same(sharedHost));

      final resourcePlan = host.prepareComponent(resourceComponent);
      final streamPlan = host.prepareComponent(streamComponent);

      expect(resourcePlan.canBind, isTrue);
      expect(streamPlan.canBind, isFalse);
      expect(streamPlan.versionErrors, hasLength(7));
      expect(sharedHost.table.activeCount, 0);
    });

    test('Preview3 wrapper accepts async stream profile bindings', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      final host = WASIPreview3ComponentHost();

      expect(host.profile, same(WASIComponentVersionProfile.preview3));

      final binding = host.bindComponent(component);
      final handles = WASIComponentAsyncEndpointHandles.unpack(
        binding.program.invoke(0, const <Object?>[])! as int,
      );

      expect(binding.asyncValueBindings, hasLength(1));
      expect(host.componentHost.table.activeCount, 2);
      expect(binding.program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.componentHost.table.activeCount, 0);
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
