import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasi/component/versioned_host.dart';
import 'package:wasd/src/wasi/preview2/component_host.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasi/version.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

import 'support/component_fixtures.dart';

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

    test(
      'Preview2 wrapper rejects owned-resource async values at version gate',
      () {
        final streamComponent = WasmComponent.decode(
          ownedResourceStreamNewDropComponentBytes(),
        );
        final futureComponent = WasmComponent.decode(
          ownedResourceFutureNewDropComponentBytes(),
        );
        final host = WASIPreview2ComponentHost();

        final streamPlan = host.prepareComponent(streamComponent);
        final futurePlan = host.prepareComponent(futureComponent);

        expect(streamComponent.validate(), isEmpty);
        expect(futureComponent.validate(), isEmpty);
        expect(streamPlan.canBind, isFalse);
        expect(futurePlan.canBind, isFalse);
        expect(streamPlan.versionErrors, hasLength(3));
        expect(futurePlan.versionErrors, hasLength(3));
        expect(streamPlan.versionErrors.map((error) => error.kind), [
          WasmComponentCanonicalKind.streamNew,
          WasmComponentCanonicalKind.streamDropReadable,
          WasmComponentCanonicalKind.streamDropWritable,
        ]);
        expect(futurePlan.versionErrors.map((error) => error.kind), [
          WasmComponentCanonicalKind.futureNew,
          WasmComponentCanonicalKind.futureDropReadable,
          WasmComponentCanonicalKind.futureDropWritable,
        ]);
        expect(streamPlan.unsupportedDefinitions, isEmpty);
        expect(futurePlan.unsupportedDefinitions, isEmpty);
        expect(streamPlan.bindingErrors, isEmpty);
        expect(futurePlan.bindingErrors, isEmpty);
        expect(streamPlan.componentPlan.resourceBindings, hasLength(1));
        expect(futurePlan.componentPlan.resourceBindings, hasLength(1));
        expect(
          streamPlan.componentPlan.resourceBindings.single.componentTypeIndex,
          0,
        );
        expect(
          futurePlan.componentPlan.resourceBindings.single.componentTypeIndex,
          0,
        );
        expect(streamPlan.componentPlan.asyncValueBindings, hasLength(1));
        expect(futurePlan.componentPlan.asyncValueBindings, hasLength(1));
        expect(
          streamPlan.componentPlan.asyncValueBindings.single.kind,
          WASIComponentAsyncValueBindingKind.stream,
        );
        expect(
          futurePlan.componentPlan.asyncValueBindings.single.kind,
          WASIComponentAsyncValueBindingKind.future,
        );
        expect(
          streamPlan.componentPlan.asyncValueBindings.single.componentTypeIndex,
          2,
        );
        expect(
          futurePlan.componentPlan.asyncValueBindings.single.componentTypeIndex,
          2,
        );
        expect(
          streamPlan
              .componentPlan
              .asyncValueBindings
              .single
              .memoryLayout!
              .byteLength,
          4,
        );
        expect(
          futurePlan
              .componentPlan
              .asyncValueBindings
              .single
              .memoryLayout!
              .byteLength,
          4,
        );
        expect(
          () => streamPlan.bind(),
          throwsA(isA<WASIComponentVersionUnsupportedException>()),
        );
        expect(
          () => futurePlan.bind(),
          throwsA(isA<WASIComponentVersionUnsupportedException>()),
        );
        expect(host.componentHost.table.activeCount, 0);
      },
    );

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

    test('Preview3 wrapper executes owned-resource async lifecycles', () {
      final streamComponent = WasmComponent.decode(
        ownedResourceStreamNewDropComponentBytes(),
      );
      final futureComponent = WasmComponent.decode(
        ownedResourceFutureNewDropComponentBytes(),
      );
      final streamHost = WASIPreview3ComponentHost();
      final futureHost = WASIPreview3ComponentHost();

      final streamPlan = streamHost.prepareComponent(streamComponent);
      final futurePlan = futureHost.prepareComponent(futureComponent);

      expect(streamComponent.validate(), isEmpty);
      expect(futureComponent.validate(), isEmpty);
      expect(streamPlan.canBind, isTrue);
      expect(futurePlan.canBind, isTrue);
      expect(streamPlan.versionErrors, isEmpty);
      expect(futurePlan.versionErrors, isEmpty);
      expect(streamPlan.unsupportedDefinitions, isEmpty);
      expect(futurePlan.unsupportedDefinitions, isEmpty);
      expect(streamPlan.bindingErrors, isEmpty);
      expect(futurePlan.bindingErrors, isEmpty);
      expect(streamPlan.componentPlan.resourceBindings, hasLength(1));
      expect(futurePlan.componentPlan.resourceBindings, hasLength(1));
      expect(
        streamPlan.componentPlan.resourceBindings.single.componentTypeIndex,
        0,
      );
      expect(
        futurePlan.componentPlan.resourceBindings.single.componentTypeIndex,
        0,
      );
      expect(streamPlan.componentPlan.asyncValueBindings, hasLength(1));
      expect(futurePlan.componentPlan.asyncValueBindings, hasLength(1));
      expect(
        streamPlan.componentPlan.asyncValueBindings.single.kind,
        WASIComponentAsyncValueBindingKind.stream,
      );
      expect(
        futurePlan.componentPlan.asyncValueBindings.single.kind,
        WASIComponentAsyncValueBindingKind.future,
      );
      expect(
        streamPlan.componentPlan.asyncValueBindings.single.componentTypeIndex,
        2,
      );
      expect(
        futurePlan.componentPlan.asyncValueBindings.single.componentTypeIndex,
        2,
      );
      expect(
        streamPlan
            .componentPlan
            .asyncValueBindings
            .single
            .memoryLayout!
            .byteLength,
        4,
      );
      expect(
        futurePlan
            .componentPlan
            .asyncValueBindings
            .single
            .memoryLayout!
            .byteLength,
        4,
      );

      final streamBinding = streamPlan.bind();
      final streamHandles = WASIComponentAsyncEndpointHandles.unpack(
        streamBinding.program.invoke(0, const <Object?>[])! as int,
      );
      expect(streamHost.componentHost.table.activeCount, 2);
      expect(
        streamBinding.program.invoke(1, <Object?>[streamHandles.readable]),
        isNull,
      );
      expect(
        streamBinding.program.invoke(2, <Object?>[streamHandles.writable]),
        isNull,
      );
      expect(streamHost.componentHost.table.activeCount, 0);

      final futureBinding = futurePlan.bind();
      final futureHandles = WASIComponentAsyncEndpointHandles.unpack(
        futureBinding.program.invoke(0, const <Object?>[])! as int,
      );
      expect(futureHost.componentHost.table.activeCount, 2);
      expect(
        futureBinding.program.invoke(1, <Object?>[futureHandles.readable]),
        isNull,
      );
      expect(
        futureBinding.program.invoke(2, <Object?>[futureHandles.writable]),
        isNull,
      );
      expect(futureHost.componentHost.table.activeCount, 0);
    });

    test('Preview2 wrapper rejects owned-resource async memory copies', () {
      final streamComponent = WasmComponent.decode(
        ownedResourceAsyncMemoryProgramFromU32(
          canonicalU32StreamMemoryComponentBytes(),
          isStream: true,
        ),
      );
      final futureComponent = WasmComponent.decode(
        ownedResourceAsyncMemoryProgramFromU32(
          canonicalU32FutureMemoryComponentBytes(),
          isStream: false,
        ),
      );
      final host = WASIPreview2ComponentHost();

      final streamPlan = host.prepareComponent(streamComponent);
      final futurePlan = host.prepareComponent(futureComponent);

      expect(streamComponent.validate(), isEmpty);
      expect(futureComponent.validate(), isEmpty);
      expect(streamPlan.canBind, isFalse);
      expect(futurePlan.canBind, isFalse);
      expect(streamPlan.versionErrors, hasLength(5));
      expect(futurePlan.versionErrors, hasLength(5));
      expect(streamPlan.versionErrors.map((error) => error.kind), [
        WasmComponentCanonicalKind.streamNew,
        WasmComponentCanonicalKind.streamRead,
        WasmComponentCanonicalKind.streamWrite,
        WasmComponentCanonicalKind.streamDropReadable,
        WasmComponentCanonicalKind.streamDropWritable,
      ]);
      expect(futurePlan.versionErrors.map((error) => error.kind), [
        WasmComponentCanonicalKind.futureNew,
        WasmComponentCanonicalKind.futureRead,
        WasmComponentCanonicalKind.futureWrite,
        WasmComponentCanonicalKind.futureDropReadable,
        WasmComponentCanonicalKind.futureDropWritable,
      ]);
      expect(streamPlan.unsupportedDefinitions, isEmpty);
      expect(futurePlan.unsupportedDefinitions, isEmpty);
      expect(streamPlan.bindingErrors, isEmpty);
      expect(futurePlan.bindingErrors, isEmpty);
      expect(streamPlan.componentPlan.resourceBindings, hasLength(1));
      expect(futurePlan.componentPlan.resourceBindings, hasLength(1));
      expect(streamPlan.componentPlan.asyncValueBindings, hasLength(1));
      expect(futurePlan.componentPlan.asyncValueBindings, hasLength(1));
      expect(
        streamPlan
            .componentPlan
            .asyncValueBindings
            .single
            .memoryLayout!
            .byteLength,
        4,
      );
      expect(
        futurePlan
            .componentPlan
            .asyncValueBindings
            .single
            .memoryLayout!
            .byteLength,
        4,
      );
      expect(
        () => streamPlan.bind(),
        throwsA(isA<WASIComponentVersionUnsupportedException>()),
      );
      expect(
        () => futurePlan.bind(),
        throwsA(isA<WASIComponentVersionUnsupportedException>()),
      );
      expect(host.componentHost.table.activeCount, 0);
    });

    test('Preview3 wrapper executes owned-resource async memory copies', () {
      final streamComponent = WasmComponent.decode(
        ownedResourceAsyncMemoryProgramFromU32(
          canonicalU32StreamMemoryComponentBytes(),
          isStream: true,
        ),
      );
      final futureComponent = WasmComponent.decode(
        ownedResourceAsyncMemoryProgramFromU32(
          canonicalU32FutureMemoryComponentBytes(),
          isStream: false,
        ),
      );
      final streamHost = WASIPreview3ComponentHost();
      final futureHost = WASIPreview3ComponentHost();
      final streamMemory = Memory(const MemoryDescriptor(initial: 1));
      final futureMemory = Memory(const MemoryDescriptor(initial: 1));
      final streamData = ByteData.view(streamMemory.buffer);
      final futureData = ByteData.view(futureMemory.buffer);
      streamData.setUint32(32, 0x7fffffff, Endian.little);
      streamData.setUint32(36, 0x80000000, Endian.little);
      futureData.setUint32(32, 0xffffffff, Endian.little);

      final streamPlan = streamHost.prepareComponent(streamComponent);
      final futurePlan = futureHost.prepareComponent(futureComponent);

      expect(streamComponent.validate(), isEmpty);
      expect(futureComponent.validate(), isEmpty);
      expect(streamPlan.canBind, isTrue);
      expect(futurePlan.canBind, isTrue);
      expect(streamPlan.versionErrors, isEmpty);
      expect(futurePlan.versionErrors, isEmpty);
      expect(streamPlan.unsupportedDefinitions, isEmpty);
      expect(futurePlan.unsupportedDefinitions, isEmpty);
      expect(streamPlan.componentPlan.resourceBindings, hasLength(1));
      expect(futurePlan.componentPlan.resourceBindings, hasLength(1));
      expect(streamPlan.componentPlan.asyncValueBindings, hasLength(1));
      expect(futurePlan.componentPlan.asyncValueBindings, hasLength(1));

      final streamBinding = streamPlan.bind();
      final streamHandles = WASIComponentAsyncEndpointHandles.unpack(
        streamBinding.program.invoke(0, const <Object?>[])! as int,
      );
      expect(
        streamBinding.program.invokeWithMemory(2, streamMemory, <Object?>[
          streamHandles.writable,
          32,
          2,
        ]),
        2 << 4,
      );
      expect(
        streamBinding.program.invokeWithMemory(1, streamMemory, <Object?>[
          streamHandles.readable,
          96,
          2,
        ]),
        2 << 4,
      );
      expect(streamData.getUint32(96, Endian.little), 0x7fffffff);
      expect(streamData.getUint32(100, Endian.little), 0x80000000);
      expect(
        streamBinding.program.invoke(3, <Object?>[streamHandles.readable]),
        isNull,
      );
      expect(
        streamBinding.program.invoke(4, <Object?>[streamHandles.writable]),
        isNull,
      );
      expect(streamHost.componentHost.table.activeCount, 0);

      final futureBinding = futurePlan.bind();
      final futureHandles = WASIComponentAsyncEndpointHandles.unpack(
        futureBinding.program.invoke(0, const <Object?>[])! as int,
      );
      expect(
        futureBinding.program.invokeWithMemory(2, futureMemory, <Object?>[
          futureHandles.writable,
          32,
        ]),
        0,
      );
      expect(
        futureBinding.program.invokeWithMemory(1, futureMemory, <Object?>[
          futureHandles.readable,
          96,
        ]),
        0,
      );
      expect(futureData.getUint32(96, Endian.little), 0xffffffff);
      expect(
        futureBinding.program.invoke(3, <Object?>[futureHandles.readable]),
        isNull,
      );
      expect(
        futureBinding.program.invoke(4, <Object?>[futureHandles.writable]),
        isNull,
      );
      expect(futureHost.componentHost.table.activeCount, 0);
    });

    test('Preview3 wrapper reports adapter resource handle uses', () {
      final component = WasmComponent.decode(
        canonicalResourceLiftComponentBytes(),
      );
      final host = WASIPreview3ComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isFalse);
      expect(plan.versionErrors, isEmpty);
      expect(plan.unsupportedDefinitions, hasLength(1));
      expect(
        plan.unsupportedDefinitions.single.kind,
        WasmComponentCanonicalKind.lift,
      );
      expect(plan.resourceUses, hasLength(3));
      expect(plan.resourceUses.map((use) => use.path), [
        'canonical[0].param[0].owned',
        'canonical[0].param[1].borrowed',
        'canonical[0].result',
      ]);
      expect(plan.resourceUses.map((use) => use.handleKind), [
        WASIComponentResourceHandleKind.own,
        WASIComponentResourceHandleKind.borrow,
        WASIComponentResourceHandleKind.own,
      ]);
      expect(plan.resourceUses.map((use) => use.binding?.representation), [
        WASIComponentResourceRepresentation.i32,
        WASIComponentResourceRepresentation.i32,
        WASIComponentResourceRepresentation.i32,
      ]);
      expect(
        () => plan.bind(),
        throwsA(isA<WASIComponentCanonicalHostUnsupportedException>()),
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
