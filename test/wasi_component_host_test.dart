import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

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

    test('copies primitive streams through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalStreamMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 55, Endian.little);
      data.setUint32(36, 89, Endian.little);
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(
        plan.asyncValueBindings.single.fixedWidthMemoryLayout!.byteLength,
        4,
      );

      final binding = plan.bind();
      final handles = WASIComponentAsyncEndpointHandles.unpack(
        binding.program.invoke(0, const <Object?>[])! as int,
      );

      expect(
        binding.program.invokeWithMemory(2, memory, <Object?>[
          handles.writable,
          32,
          2,
        ]),
        2 << 4,
      );
      expect(
        binding.program.invokeWithMemory(1, memory, <Object?>[
          handles.readable,
          96,
          2,
        ]),
        2 << 4,
      );
      expect(data.getUint32(96, Endian.little), 55);
      expect(data.getUint32(100, Endian.little), 89);
      expect(binding.program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('copies record streams through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalRecordStreamMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 55, Endian.little);
      data.setUint16(36, 13, Endian.little);
      data.setUint32(40, 89, Endian.little);
      data.setUint16(44, 21, Endian.little);
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(plan.asyncValueBindings.single.primitive, isNull);
      expect(
        plan.asyncValueBindings.single.fixedWidthMemoryLayout!.byteLength,
        8,
      );
      expect(
        plan.asyncValueBindings.single.fixedWidthMemoryLayout!.alignment,
        4,
      );

      final binding = plan.bind();
      final handles = WASIComponentAsyncEndpointHandles.unpack(
        binding.program.invoke(0, const <Object?>[])! as int,
      );

      expect(
        binding.program.invokeWithMemory(2, memory, <Object?>[
          handles.writable,
          32,
          2,
        ]),
        2 << 4,
      );
      expect(
        binding.program.invokeWithMemory(1, memory, <Object?>[
          handles.readable,
          96,
          2,
        ]),
        2 << 4,
      );
      expect(data.getUint32(96, Endian.little), 55);
      expect(data.getUint16(100, Endian.little), 13);
      expect(data.getUint32(104, Endian.little), 89);
      expect(data.getUint16(108, Endian.little), 21);
      expect(binding.program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test(
      'publishes primitive stream read events through decoded core memory options',
      () async {
        final component = WasmComponent.decode(
          _canonicalStreamMemoryProgramBytes(),
        );
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        data.setUint32(32, 144, Endian.little);
        data.setUint32(36, 233, Endian.little);
        final host = WASIComponentHost();

        final binding = host.bindComponent(component);
        final handles = WASIComponentAsyncEndpointHandles.unpack(
          binding.program.invoke(0, const <Object?>[])! as int,
        );
        final waitableHost = host.canonicalHost.waitableHost;
        final waitableSet = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(handles.readable, waitableSet);
        var completed = false;

        expect(
          binding.program.invokeWithMemoryEvent(1, memory, <Object?>[
            handles.readable,
            96,
            2,
          ]),
          wasiComponentAsyncBlocked,
        );
        final pending =
            waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128)
              ..then((_) {
                completed = true;
              });
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);
        expect(
          () => binding.program.invoke(3, <Object?>[handles.readable]),
          throwsStateError,
        );
        expect(
          binding.program.invokeWithMemory(2, memory, <Object?>[
            handles.writable,
            32,
            2,
          ]),
          2 << 4,
        );

        await expectLater(pending, completion(2));
        expect(completed, isTrue);
        expect(data.getUint32(96, Endian.little), 144);
        expect(data.getUint32(100, Endian.little), 233);
        expect(data.getUint32(128, Endian.little), handles.readable);
        expect(data.getUint32(132, Endian.little), 2 << 4);
        waitableHost.waitableJoin(handles.readable, 0);
        waitableHost.waitableSetDrop(waitableSet);
        expect(binding.program.invoke(3, <Object?>[handles.readable]), isNull);
        expect(binding.program.invoke(4, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

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

    test('copies primitive futures through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalFutureMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 987, Endian.little);
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(
        plan.asyncValueBindings.single.kind,
        WASIComponentAsyncValueBindingKind.future,
      );
      expect(
        plan.asyncValueBindings.single.fixedWidthMemoryLayout!.byteLength,
        4,
      );

      final binding = plan.bind();
      final handles = WASIComponentAsyncEndpointHandles.unpack(
        binding.program.invoke(0, const <Object?>[])! as int,
      );

      expect(
        binding.program.invokeWithMemory(2, memory, <Object?>[
          handles.writable,
          32,
        ]),
        0,
      );
      expect(
        binding.program.invokeWithMemory(1, memory, <Object?>[
          handles.readable,
          96,
        ]),
        0,
      );
      expect(data.getUint32(96, Endian.little), 987);
      expect(binding.program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('copies record futures through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalRecordFutureMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 987, Endian.little);
      data.setUint16(36, 34, Endian.little);
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(plan.asyncValueBindings.single.primitive, isNull);
      expect(
        plan.asyncValueBindings.single.fixedWidthMemoryLayout!.byteLength,
        8,
      );

      final binding = plan.bind();
      final handles = WASIComponentAsyncEndpointHandles.unpack(
        binding.program.invoke(0, const <Object?>[])! as int,
      );

      expect(
        binding.program.invokeWithMemory(2, memory, <Object?>[
          handles.writable,
          32,
        ]),
        0,
      );
      expect(
        binding.program.invokeWithMemory(1, memory, <Object?>[
          handles.readable,
          96,
        ]),
        0,
      );
      expect(data.getUint32(96, Endian.little), 987);
      expect(data.getUint16(100, Endian.little), 34);
      expect(binding.program.invoke(3, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(4, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test(
      'publishes primitive future read events through decoded core memory options',
      () async {
        final component = WasmComponent.decode(
          _canonicalFutureMemoryProgramBytes(),
        );
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        data.setUint32(32, 1597, Endian.little);
        final host = WASIComponentHost();

        final binding = host.bindComponent(component);
        final handles = WASIComponentAsyncEndpointHandles.unpack(
          binding.program.invoke(0, const <Object?>[])! as int,
        );
        final waitableHost = host.canonicalHost.waitableHost;
        final waitableSet = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(handles.readable, waitableSet);

        expect(
          binding.program.invokeWithMemoryEvent(1, memory, <Object?>[
            handles.readable,
            96,
          ]),
          wasiComponentAsyncBlocked,
        );
        expect(
          binding.program.invokeWithMemory(2, memory, <Object?>[
            handles.writable,
            32,
          ]),
          0,
        );

        await expectLater(
          waitableHost.waitableSetWaitToMemory(waitableSet, memory, 128),
          completion(4),
        );
        expect(data.getUint32(96, Endian.little), 1597);
        expect(data.getUint32(128, Endian.little), handles.readable);
        expect(data.getUint32(132, Endian.little), 0);
        waitableHost.waitableJoin(handles.readable, 0);
        waitableHost.waitableSetDrop(waitableSet);
        expect(binding.program.invoke(3, <Object?>[handles.readable]), isNull);
        expect(binding.program.invoke(4, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

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

    test('copies string stream writes through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalStringStreamWriteMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final data = ByteData.view(memory.buffer);
      bytes.setAll(96, 'host'.codeUnits);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 4, Endian.little);
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(
        plan.asyncValueBindings.single.primitive,
        WasmComponentPrimitiveValueType.string,
      );
      expect(plan.asyncValueBindings.single.fixedWidthMemoryLayout, isNull);

      final binding = plan.bind();
      final handles = WASIComponentAsyncEndpointHandles.unpack(
        binding.program.invoke(0, const <Object?>[])! as int,
      );

      expect(
        binding.program.invokeWithMemory(1, memory, <Object?>[
          handles.writable,
          32,
          1,
        ]),
        1 << 4,
      );
      expect(binding.program.invoke(2, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(3, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('copies string streams through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalStringStreamMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final data = ByteData.view(memory.buffer);
      bytes.setAll(96, 'host'.codeUnits);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 4, Endian.little);
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(
        plan.asyncValueBindings.single.primitive,
        WasmComponentPrimitiveValueType.string,
      );
      expect(plan.asyncValueBindings.single.fixedWidthMemoryLayout, isNull);
      expect(plan.bindingErrors, isEmpty);

      final binding = plan.bind();
      final handles = host.canonicalHost.asyncHost
          .bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.streamNew,
              typeIndex: 0,
            ),
          )
          .streamNewPackedHandles();
      final endpoints = WASIComponentAsyncEndpointHandles.unpack(handles);
      expect(
        binding.program.invokeWithMemory(1, memory, <Object?>[
          endpoints.writable,
          32,
          1,
        ]),
        1 << 4,
      );
      expect(
        () => binding.program.invokeWithMemory(0, memory, <Object?>[
          endpoints.readable,
          64,
          1,
        ]),
        throwsUnsupportedError,
      );
      expect(
        binding.program.invokeWithMemory(
          0,
          memory,
          <Object?>[endpoints.readable, 64, 1],
          realloc: (oldPointer, oldSize, alignment, newSize) {
            expect(oldPointer, 0);
            expect(oldSize, 0);
            expect(alignment, 1);
            expect(newSize, 4);
            return 128;
          },
        ),
        1 << 4,
      );
      expect(data.getUint32(64, Endian.little), 128);
      expect(data.getUint32(68, Endian.little), 4);
      expect(String.fromCharCodes(bytes.sublist(128, 132)), 'host');
      host.canonicalHost.asyncHost
          .bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.streamDropReadable,
              typeIndex: 0,
            ),
          )
          .streamDropReadableHandle(endpoints.readable);
      host.canonicalHost.asyncHost
          .bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.streamDropWritable,
              typeIndex: 0,
            ),
          )
          .streamDropWritableHandle(endpoints.writable);
      expect(host.table.activeCount, 0);
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

Uint8List _canonicalStreamMemoryProgramBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x01,
      0x16,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x05,
      0x03,
      0x01,
      0x00,
      0x01,
      0x07,
      0x07,
      0x01,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x02,
      0x00,
      0x02,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x07,
      0x04,
      0x01,
      0x66,
      0x01,
      0x79,
      0x08,
      0x03,
      0x01,
      0x0e,
      0x00,
      0x06,
      0x09,
      0x01,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x08,
      0x06,
      0x01,
      0x0f,
      0x00,
      0x01,
      0x03,
      0x00,
      0x06,
      0x09,
      0x01,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x08,
      0x0a,
      0x03,
      0x10,
      0x00,
      0x01,
      0x03,
      0x01,
      0x13,
      0x00,
      0x14,
      0x00,
    ]);

Uint8List _canonicalRecordStreamMemoryProgramBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x01,
      0x16,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x05,
      0x03,
      0x01,
      0x00,
      0x01,
      0x07,
      0x07,
      0x01,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x02,
      0x00,
      0x02,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x07,
      0x0c,
      0x02,
      0x72,
      0x02,
      0x01,
      0x61,
      0x79,
      0x01,
      0x62,
      0x7b,
      0x66,
      0x01,
      0x00,
      0x08,
      0x03,
      0x01,
      0x0e,
      0x01,
      0x06,
      0x09,
      0x01,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x08,
      0x06,
      0x01,
      0x0f,
      0x01,
      0x01,
      0x03,
      0x00,
      0x06,
      0x09,
      0x01,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x08,
      0x0a,
      0x03,
      0x10,
      0x01,
      0x01,
      0x03,
      0x01,
      0x13,
      0x01,
      0x14,
      0x01,
    ]);

Uint8List _canonicalStringStreamMemoryProgramBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x01,
      0x37,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x09,
      0x01,
      0x60,
      0x04,
      0x7f,
      0x7f,
      0x7f,
      0x7f,
      0x01,
      0x7f,
      0x03,
      0x02,
      0x01,
      0x00,
      0x05,
      0x03,
      0x01,
      0x00,
      0x01,
      0x07,
      0x11,
      0x02,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x02,
      0x00,
      0x07,
      0x72,
      0x65,
      0x61,
      0x6c,
      0x6c,
      0x6f,
      0x63,
      0x00,
      0x00,
      0x0a,
      0x06,
      0x01,
      0x04,
      0x00,
      0x41,
      0x00,
      0x0b,
      0x02,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x06,
      0x15,
      0x02,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x00,
      0x00,
      0x01,
      0x00,
      0x07,
      0x72,
      0x65,
      0x61,
      0x6c,
      0x6c,
      0x6f,
      0x63,
      0x07,
      0x04,
      0x01,
      0x66,
      0x01,
      0x73,
      0x08,
      0x0d,
      0x02,
      0x0f,
      0x00,
      0x02,
      0x03,
      0x00,
      0x04,
      0x00,
      0x10,
      0x00,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _canonicalStringStreamWriteMemoryProgramBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x01,
      0x16,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x05,
      0x03,
      0x01,
      0x00,
      0x01,
      0x07,
      0x07,
      0x01,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x02,
      0x00,
      0x02,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x06,
      0x09,
      0x01,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x07,
      0x04,
      0x01,
      0x66,
      0x01,
      0x73,
      0x08,
      0x0c,
      0x04,
      0x0e,
      0x00,
      0x10,
      0x00,
      0x01,
      0x03,
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

Uint8List _canonicalFutureMemoryProgramBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x01,
      0x16,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x05,
      0x03,
      0x01,
      0x00,
      0x01,
      0x07,
      0x07,
      0x01,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x02,
      0x00,
      0x02,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x07,
      0x04,
      0x01,
      0x65,
      0x01,
      0x79,
      0x08,
      0x03,
      0x01,
      0x15,
      0x00,
      0x06,
      0x09,
      0x01,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x08,
      0x06,
      0x01,
      0x16,
      0x00,
      0x01,
      0x03,
      0x00,
      0x06,
      0x09,
      0x01,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x08,
      0x0a,
      0x03,
      0x17,
      0x00,
      0x01,
      0x03,
      0x01,
      0x1a,
      0x00,
      0x1b,
      0x00,
    ]);

Uint8List _canonicalRecordFutureMemoryProgramBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x01,
      0x16,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x05,
      0x03,
      0x01,
      0x00,
      0x01,
      0x07,
      0x07,
      0x01,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x02,
      0x00,
      0x02,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x07,
      0x0c,
      0x02,
      0x72,
      0x02,
      0x01,
      0x61,
      0x79,
      0x01,
      0x62,
      0x7b,
      0x65,
      0x01,
      0x00,
      0x08,
      0x03,
      0x01,
      0x15,
      0x01,
      0x06,
      0x09,
      0x01,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x08,
      0x06,
      0x01,
      0x16,
      0x01,
      0x01,
      0x03,
      0x00,
      0x06,
      0x09,
      0x01,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x08,
      0x0a,
      0x03,
      0x17,
      0x01,
      0x01,
      0x03,
      0x01,
      0x1a,
      0x01,
      0x1b,
      0x01,
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
