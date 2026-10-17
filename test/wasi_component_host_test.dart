import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/preview2/component_host.dart';
import 'package:wasd/src/wasi/preview2/io.dart';
import 'package:wasd/src/wasi/preview2/cli.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasi/component/waitable_set.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

import 'support/component_fixtures.dart' as component_fixtures;

void main() {
  group('canonical standard host nominal tokens', () {
    test(
      'all Preview2 contracts resolve before any H and preserve version aliases',
      () {
        final host = WASIPreview2ComponentHost();
        final table = host.componentHost.table;
        for (final contract in _preview2ResourceContracts.entries) {
          for (final resource in contract.value) {
            final fake = table.defineType<Object>(
              '${contract.key}@0.2.0.$resource',
            );
            final token = host.canonicalResourceType(
              '${contract.key}@0.2.0',
              resource,
            );
            expect(token, isNotNull, reason: '${contract.key}.$resource');
            expect(token, isNot(same(fake)));
            for (var patch = 0; patch <= 12; patch++) {
              expect(
                host.canonicalResourceType(
                  '${contract.key}@0.2.$patch',
                  resource,
                ),
                same(token),
              );
            }
            expect(
              host.canonicalResourceType('${contract.key}@0.2.13', resource),
              isNull,
            );
            expect(
              host.canonicalResourceType('${contract.key}@0.2.01', resource),
              isNull,
            );
            expect(
              host.canonicalResourceType('${contract.key}@0.2.0', 'unknown'),
              isNull,
            );
          }
        }
        expect(
          host.canonicalResourceType(
            'example:io/streams@0.2.0',
            'input-stream',
          ),
          isNull,
        );
        expect(
          host.canonicalResourceType('wasi:sockets/tcp@0.2.0', 'network'),
          isNull,
        );
        expect(table.activeCount, 0);
      },
    );

    test(
      'real stream token accepts its owner and rejects a same-name fake H',
      () {
        final host = WASIPreview2ComponentHost();
        final table = host.componentHost.table;
        final fake = table.defineType<WASIPreview2InputStream>(
          'wasi:io/streams@0.2.0.input-stream',
        );
        final fakeHandle = table.insert(
          fake,
          WASIPreview2InputStream(closed: true),
        );
        final token = host.canonicalResourceType(
          'wasi:io/streams@0.2.0',
          'input-stream',
        )!;
        expect(() => table.get(token, fakeHandle), throwsStateError);
        final value = WASIPreview2InputStream(closed: true);
        final actual = host.streamsHost.insertInputStream(value);
        expect(table.get(token, actual), same(value));
        table.drop(fake, fakeHandle);
        table.drop(token, actual);
        expect(table.activeCount, 0);
      },
    );

    test(
      'constructor override resolves the actual owner among same-table hosts',
      () {
        final shared = WASIComponentHost();
        final owner = WASIPreview2StreamsHost(table: shared.table);
        final other = WASIPreview2StreamsHost(table: shared.table);
        final host = WASIPreview2ComponentHost(
          componentHost: shared,
          streamsHost: owner,
        );
        final token = host.canonicalResourceType(
          'wasi:io/streams@0.2.12',
          'input-stream',
        )!;
        expect(token, same(owner.canonicalResourceType('input-stream')));
        final otherType = other.canonicalResourceType('input-stream')!;
        expect(token, isNot(same(otherType)));
        final otherHandle = other.insertInputStream(
          WASIPreview2InputStream(closed: true),
        );
        expect(() => shared.table.get(token, otherHandle), throwsStateError);
        shared.table.drop(otherType, otherHandle);
        expect(shared.table.activeCount, 0);
      },
    );

    test(
      'all Preview3 contracts keep their owner token across supported aliases',
      () {
        final host = WASIPreview3ComponentHost();
        final table = host.componentHost.table;
        for (final contract in _preview3ResourceContracts.entries) {
          for (final resource in contract.value) {
            final fake = table.defineType<Object>(
              '${contract.key}@0.3.0.$resource',
            );
            final token = host.canonicalResourceType(
              '${contract.key}@0.3.0',
              resource,
            );
            expect(token, isNotNull, reason: '${contract.key}.$resource');
            expect(token, isNot(same(fake)));
            expect(
              host.canonicalResourceType('${contract.key}@0.3.1', resource),
              same(token),
            );
            expect(
              host.canonicalResourceType('${contract.key}@0.3.2', resource),
              isNull,
            );
          }
        }
        expect(table.activeCount, 0);
        host.close(force: true);
      },
    );

    test('Preview3 compatibility uses the supplied actual Preview2 owner', () {
      final shared = WASIComponentHost();
      final compatibility = WASIPreview2ComponentHost(
        componentHost: shared,
        terminalStdin: true,
      );
      final host = WASIPreview3ComponentHost(
        componentHost: shared,
        preview2CompatibilityHost: compatibility,
        terminalStdin: true,
      );
      for (final contract in _preview2ResourceContracts.entries) {
        for (final resource in contract.value) {
          expect(
            host.canonicalResourceType('${contract.key}@0.2.12', resource),
            same(
              compatibility.canonicalResourceType(
                '${contract.key}@0.2.0',
                resource,
              ),
            ),
          );
        }
      }
      final handle = compatibility.cliHost.terminalStdinHandle!;
      final token = host.canonicalResourceType(
        'wasi:cli/terminal-input@0.2.12',
        'terminal-input',
      )!;
      expect(shared.table.get(token, handle), isA<WASIPreview2TerminalInput>());
      expect(
        token,
        isNot(
          same(
            host.canonicalResourceType(
              'wasi:cli/terminal-input@0.3.0',
              'terminal-input',
            ),
          ),
        ),
      );
      shared.table.drop(token, handle);
      host.close(force: true);
      expect(shared.table.activeCount, 0);
    });
  });

  test('missing adapter callbacks do not allocate local async types', () {
    final host = WASIComponentHost();
    final component = WasmComponent.decode(
      component_fixtures.importedScopedOptionStreamComponentBytes(),
    );
    final plan = host.prepareComponent(component);
    expect(plan.validationErrors, isEmpty);
    expect(plan.adapterPlans, isNotEmpty);
    expect(plan.asyncValueBindings, isNotEmpty);
    final before = host.table.defineType<Object>('before').id;
    var metadataCalls = 0;
    expect(
      () => plan.bind(
        instanceLocalAsyncValues: true,
        asyncValueName: (_) {
          metadataCalls++;
          return 'unused';
        },
      ),
      throwsStateError,
    );
    expect(metadataCalls, 0);
    expect(host.table.defineType<Object>('after').id, before + 1);
    expect(host.table.activeCount, 0);
  });

  test(
    'local stream rendezvous uses the shared scheduler and cleans failures',
    () async {
      final host = WASIComponentHost();
      final component = WasmComponent.decode(
        component_fixtures.canonicalU32StreamMemoryComponentBytes(),
      );
      var drops = 0;
      final binding = host
          .prepareComponent(component)
          .bind(
            instanceLocalAsyncValues: true,
            maxBufferedElementsForStream: (_) => 0,
            onAsyncValueDrop: (_) => drops++,
          );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer)
        ..setUint32(32, 42, Endian.little);
      final waitables = host.canonicalHost.waitableHost;
      late int readable;
      late int writable;
      late WASIComponentWaitable endpointWaitable;
      final failure = StateError('component failed');
      await expectLater(
        host.table.runScoped<void>(() async {
          final handles = WASIComponentAsyncEndpointHandles.unpack(
            binding.program.invoke(0, [])! as int,
          );
          readable = handles.readable;
          writable = handles.writable;
          final set = waitables.waitableSetNew();
          waitables.waitableJoin(readable, set);
          endpointWaitable = host.canonicalHost.asyncHost.waitableForHandle(
            readable,
          )!;
          expect(
            binding.program.invokeWithMemoryEvent(1, memory, [readable, 96, 1]),
            wasiComponentAsyncBlocked,
          );
          final write = binding.program.invokeWithMemoryAsync(2, memory, [
            writable,
            32,
            1,
          ]);
          expect(
            await waitables.waitableSetWaitToMemory(set, memory, 128),
            WASIComponentWaitableEventCode.streamRead.value,
          );
          expect(await write, 1 << 4);
          expect(data.getUint32(96, Endian.little), 42);
          expect(data.getUint32(128, Endian.little), readable);
          throw failure;
        }),
        throwsA(same(failure)),
      );
      expect(drops, 1);
      expect(endpointWaitable.inWaitableSet, isFalse);
      expect(host.table.activeCount, 0);
      expect(host.canonicalHost.asyncHost.waitableForHandle(readable), isNull);
      expect(host.canonicalHost.asyncHost.waitableForHandle(writable), isNull);
    },
  );

  test(
    'instance-local future events reach the shared waitable resolver',
    () async {
      final host = WASIComponentHost();
      final component = WasmComponent.decode(
        component_fixtures.canonicalU32FutureMemoryComponentBytes(),
      );
      final binding = host
          .prepareComponent(component)
          .bind(instanceLocalAsyncValues: true);
      final handles = WASIComponentAsyncEndpointHandles.unpack(
        binding.program.invoke(0, [])! as int,
      );
      final waitables = host.canonicalHost.waitableHost;
      final set = waitables.waitableSetNew();
      waitables.waitableJoin(handles.readable, set);
      expect(
        host.canonicalHost.asyncHost.waitableForHandle(handles.readable),
        isNotNull,
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer)
        ..setUint32(32, 42, Endian.little);
      expect(
        binding.program.invokeWithMemoryEvent(1, memory, [
          handles.readable,
          96,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(
        binding.program.invokeWithMemory(2, memory, [handles.writable, 32]),
        0,
      );
      expect(
        await waitables.waitableSetWaitToMemory(set, memory, 128),
        WASIComponentWaitableEventCode.futureRead.value,
      );
      expect(data.getUint32(96, Endian.little), 42);
      expect(data.getUint32(128, Endian.little), handles.readable);
      waitables.waitableJoin(handles.readable, 0);
      waitables.waitableSetDrop(set);
      binding.program.invoke(3, [handles.readable]);
      binding.program.invoke(4, [handles.writable]);
      expect(host.table.activeCount, 0);
      expect(
        host.canonicalHost.asyncHost.waitableForHandle(handles.readable),
        isNull,
      );
    },
  );

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
      expect(() => plan.bind(), throwsStateError);
    });

    test('does not bind resources when canonical capabilities are missing', () {
      final component = WasmComponent.decode(_canonicalMixedResourceBytes());
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component, validate: false);

      expect(plan.validationErrors, isEmpty);
      expect(plan.resourceBindings, hasLength(1));
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.bindingErrors, hasLength(1));
      expect(plan.canBind, isFalse);
      expect(plan.canBindWithAdapters, isFalse);
      expect(
        () => plan.bind(),
        throwsA(isA<WASIComponentHostBindingException>()),
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
      expect(u32Plan.asyncValueBindings.single.memoryLayout, isNotNull);
      expect(u32Plan.asyncValueBindings.single.memoryLayout!.byteLength, 4);
      expect(u32Plan.asyncValueBindings.single.memoryLayout!.alignment, 4);

      expect(stringPlan.canBind, isTrue);
      expect(stringPlan.asyncValueBindings, hasLength(1));
      expect(
        stringPlan.asyncValueBindings.single.primitive,
        WasmComponentPrimitiveValueType.string,
      );
      expect(stringPlan.asyncValueBindings.single.memoryLayout!.byteLength, 8);
      expect(stringPlan.asyncValueBindings.single.memoryLayout!.alignment, 4);
    });

    test('binds decoded unit streams through the no-memory Core ABI', () {
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
        binding.program.invoke(2, <Object?>[handles.writable, 0x1234, 2]),
        2 << 4,
      );
      expect(
        binding.program.invoke(1, <Object?>[handles.readable, 0x5678, 1]),
        1 << 4,
      );
      expect(
        binding.program.invoke(1, <Object?>[handles.readable, 0x9abc, 2]),
        1 << 4,
      );

      expect(binding.program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(dropped, isEmpty);
      expect(binding.program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(dropped, ['stream[0]']);
      expect(host.table.activeCount, 0);
    });

    test('copies primitive streams through decoded core memory options', () {
      final component = WasmComponent.decode(
        component_fixtures.canonicalU32StreamMemoryComponentBytes(),
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
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 4);

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

    test(
      'copies owned resource streams through decoded core memory options',
      () {
        final component = WasmComponent.decode(
          component_fixtures.ownedResourceAsyncMemoryProgramFromU32(
            component_fixtures.canonicalU32StreamMemoryComponentBytes(),
            isStream: true,
          ),
        );
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        data.setUint32(32, 0x7fffffff, Endian.little);
        data.setUint32(36, 0x80000000, Endian.little);
        final host = WASIComponentHost();

        final plan = host.prepareComponent(component);

        expect(component.validate(), isEmpty);
        expect(plan.canBind, isTrue);
        expect(plan.resourceBindings, hasLength(1));
        expect(plan.resourceBindings.single.componentTypeIndex, 0);
        expect(plan.asyncValueBindings, hasLength(1));
        expect(plan.asyncValueBindings.single.componentTypeIndex, 2);
        expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 4);

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
        expect(data.getUint32(96, Endian.little), 0x7fffffff);
        expect(data.getUint32(100, Endian.little), 0x80000000);
        expect(binding.program.invoke(3, <Object?>[handles.readable]), isNull);
        expect(binding.program.invoke(4, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

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
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 8);
      expect(plan.asyncValueBindings.single.memoryLayout!.alignment, 4);

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

    test('copies list streams through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalListStreamMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 2, Endian.little);
      data.setUint32(96, 7, Endian.little);
      data.setUint32(100, 8, Endian.little);
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(plan.asyncValueBindings.single.primitive, isNull);
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 8);
      expect(plan.asyncValueBindings.single.memoryLayout!.alignment, 4);
      expect(plan.bindingErrors, isEmpty);

      final binding = plan.bind();
      final endpoints = _newStreamEndpointHandles(host, typeIndex: 1);
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
            expect(alignment, 4);
            expect(newSize, 8);
            return 128;
          },
        ),
        1 << 4,
      );
      expect(data.getUint32(64, Endian.little), 128);
      expect(data.getUint32(68, Endian.little), 2);
      expect(data.getUint32(128, Endian.little), 7);
      expect(data.getUint32(132, Endian.little), 8);
      _dropStreamEndpointHandles(host, endpoints, typeIndex: 1);
      expect(host.table.activeCount, 0);
    });

    test('copies string list streams through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalStringListStreamMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final data = ByteData.view(memory.buffer);
      bytes.setAll(160, 'go'.codeUnits);
      bytes.setAll(176, 'hi'.codeUnits);
      data.setUint32(96, 160, Endian.little);
      data.setUint32(100, 2, Endian.little);
      data.setUint32(104, 176, Endian.little);
      data.setUint32(108, 2, Endian.little);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 2, Endian.little);
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(plan.asyncValueBindings.single.primitive, isNull);
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 8);
      expect(plan.asyncValueBindings.single.memoryLayout!.alignment, 4);
      expect(plan.bindingErrors, isEmpty);

      final binding = plan.bind();
      final endpoints = _newStreamEndpointHandles(host, typeIndex: 1);
      expect(
        binding.program.invokeWithMemory(1, memory, <Object?>[
          endpoints.writable,
          32,
          1,
        ]),
        1 << 4,
      );
      final allocations = <int>[224, 256, 272];
      expect(
        binding.program.invokeWithMemory(
          0,
          memory,
          <Object?>[endpoints.readable, 64, 1],
          realloc: (oldPointer, oldSize, alignment, newSize) {
            expect(oldPointer, 0);
            expect(oldSize, 0);
            if (allocations.length == 3) {
              expect(alignment, 4);
              expect(newSize, 16);
            } else {
              expect(alignment, 1);
              expect(newSize, 2);
            }
            return allocations.removeAt(0);
          },
        ),
        1 << 4,
      );
      expect(data.getUint32(64, Endian.little), 224);
      expect(data.getUint32(68, Endian.little), 2);
      expect(data.getUint32(224, Endian.little), 256);
      expect(data.getUint32(228, Endian.little), 2);
      expect(data.getUint32(232, Endian.little), 272);
      expect(data.getUint32(236, Endian.little), 2);
      expect(String.fromCharCodes(bytes.sublist(256, 258)), 'go');
      expect(String.fromCharCodes(bytes.sublist(272, 274)), 'hi');
      expect(allocations, isEmpty);
      _dropStreamEndpointHandles(host, endpoints, typeIndex: 1);
      expect(host.table.activeCount, 0);
    });

    test(
      'publishes primitive stream read events through decoded core memory options',
      () async {
        final component = WasmComponent.decode(
          component_fixtures.canonicalU32StreamMemoryComponentBytes(),
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

        await expectLater(
          pending,
          completion(WASIComponentWaitableEventCode.streamRead.value),
        );
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

    test('binds decoded unit futures through the no-memory Core ABI', () async {
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

      final pendingRead = binding.program.invokeAsync(1, <Object?>[
        handles.readable,
        0x1234,
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(binding.program.invoke(2, <Object?>[handles.writable, 0x5678]), 0);
      await expectLater(pendingRead, completion(0));
      expect(binding.program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('copies primitive futures through decoded core memory options', () {
      final component = WasmComponent.decode(
        component_fixtures.canonicalU32FutureMemoryComponentBytes(),
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
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 4);

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

    test(
      'copies owned resource futures through decoded core memory options',
      () {
        final component = WasmComponent.decode(
          component_fixtures.ownedResourceAsyncMemoryProgramFromU32(
            component_fixtures.canonicalU32FutureMemoryComponentBytes(),
            isStream: false,
          ),
        );
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final data = ByteData.view(memory.buffer);
        data.setUint32(32, 0xffffffff, Endian.little);
        final host = WASIComponentHost();

        final plan = host.prepareComponent(component);

        expect(component.validate(), isEmpty);
        expect(plan.canBind, isTrue);
        expect(plan.resourceBindings, hasLength(1));
        expect(plan.resourceBindings.single.componentTypeIndex, 0);
        expect(plan.asyncValueBindings, hasLength(1));
        expect(
          plan.asyncValueBindings.single.kind,
          WASIComponentAsyncValueBindingKind.future,
        );
        expect(plan.asyncValueBindings.single.componentTypeIndex, 2);
        expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 4);

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
        expect(data.getUint32(96, Endian.little), 0xffffffff);
        expect(binding.program.invoke(3, <Object?>[handles.readable]), isNull);
        expect(binding.program.invoke(4, <Object?>[handles.writable]), isNull);
        expect(host.table.activeCount, 0);
      },
    );

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
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 8);

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
          component_fixtures.canonicalU32FutureMemoryComponentBytes(),
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
          completion(WASIComponentWaitableEventCode.futureRead.value),
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

    test('validates nested async stream bindings before binding', () {
      final component = WasmComponent.decode(
        _streamIndexedNestedAsyncCanonicalBytes(),
      );
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      final errors = component.validate();
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('nested async'));
      expect(errors.single.message, contains('stream element type'));
      expect(plan.canBind, isFalse);
      expect(plan.validationErrors, hasLength(1));
      expect(plan.validationErrors.single.message, contains('nested async'));
      expect(plan.asyncValueBindings, isEmpty);
      expect(plan.bindingErrors, isEmpty);
      expect(
        () => plan.bind(),
        throwsA(
          isA<WASIComponentCanonicalHostValidationException>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('invalid component'), contains('nested async')),
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
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 8);
      expect(plan.asyncValueBindings.single.memoryLayout!.alignment, 4);

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
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 8);
      expect(plan.asyncValueBindings.single.memoryLayout!.alignment, 4);
      expect(plan.bindingErrors, isEmpty);

      final binding = plan.bind();
      final endpoints = _newStreamEndpointHandles(host);
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
      _dropStreamEndpointHandles(host, endpoints);
      expect(host.table.activeCount, 0);
    });

    test(
      'publishes string stream read events through decoded core memory options',
      () async {
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

        final binding = host.bindComponent(component);
        final endpoints = _newStreamEndpointHandles(host);
        final waitableHost = host.canonicalHost.waitableHost;
        final waitableSet = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(endpoints.readable, waitableSet);

        expect(
          binding.program.invokeWithMemoryEvent(
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
          wasiComponentAsyncBlocked,
        );
        expect(
          binding.program.invokeWithMemory(1, memory, <Object?>[
            endpoints.writable,
            32,
            1,
          ]),
          1 << 4,
        );

        await expectLater(
          waitableHost.waitableSetWaitToMemory(waitableSet, memory, 160),
          completion(WASIComponentWaitableEventCode.streamRead.value),
        );
        expect(data.getUint32(64, Endian.little), 128);
        expect(data.getUint32(68, Endian.little), 4);
        expect(String.fromCharCodes(bytes.sublist(128, 132)), 'host');
        expect(data.getUint32(160, Endian.little), endpoints.readable);
        expect(data.getUint32(164, Endian.little), 1 << 4);
        waitableHost.waitableJoin(endpoints.readable, 0);
        waitableHost.waitableSetDrop(waitableSet);
        _dropStreamEndpointHandles(host, endpoints);
        expect(host.table.activeCount, 0);
      },
    );

    test('copies string futures through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalStringFutureMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final data = ByteData.view(memory.buffer);
      bytes.setAll(96, 'done'.codeUnits);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 4, Endian.little);
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
        plan.asyncValueBindings.single.primitive,
        WasmComponentPrimitiveValueType.string,
      );
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 8);
      expect(plan.asyncValueBindings.single.memoryLayout!.alignment, 4);
      expect(plan.bindingErrors, isEmpty);

      final binding = plan.bind();
      final endpoints = _newFutureEndpointHandles(host);
      expect(
        binding.program.invokeWithMemory(1, memory, <Object?>[
          endpoints.writable,
          32,
        ]),
        0,
      );
      expect(
        () => binding.program.invokeWithMemory(0, memory, <Object?>[
          endpoints.readable,
          64,
        ]),
        throwsUnsupportedError,
      );
      expect(
        binding.program.invokeWithMemory(
          0,
          memory,
          <Object?>[endpoints.readable, 64],
          realloc: (oldPointer, oldSize, alignment, newSize) {
            expect(oldPointer, 0);
            expect(oldSize, 0);
            expect(alignment, 1);
            expect(newSize, 4);
            return 128;
          },
        ),
        0,
      );
      expect(data.getUint32(64, Endian.little), 128);
      expect(data.getUint32(68, Endian.little), 4);
      expect(String.fromCharCodes(bytes.sublist(128, 132)), 'done');
      _dropFutureEndpointHandles(host, endpoints);
      expect(host.table.activeCount, 0);
    });

    test(
      'publishes string future read events through decoded core memory options',
      () async {
        final component = WasmComponent.decode(
          _canonicalStringFutureMemoryProgramBytes(),
        );
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final bytes = Uint8List.view(memory.buffer);
        final data = ByteData.view(memory.buffer);
        bytes.setAll(96, 'done'.codeUnits);
        data.setUint32(32, 96, Endian.little);
        data.setUint32(36, 4, Endian.little);
        final host = WASIComponentHost();

        final binding = host.bindComponent(component);
        final endpoints = _newFutureEndpointHandles(host);
        final waitableHost = host.canonicalHost.waitableHost;
        final waitableSet = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(endpoints.readable, waitableSet);

        expect(
          binding.program.invokeWithMemoryEvent(
            0,
            memory,
            <Object?>[endpoints.readable, 64],
            realloc: (oldPointer, oldSize, alignment, newSize) {
              expect(oldPointer, 0);
              expect(oldSize, 0);
              expect(alignment, 1);
              expect(newSize, 4);
              return 128;
            },
          ),
          wasiComponentAsyncBlocked,
        );
        expect(
          binding.program.invokeWithMemory(1, memory, <Object?>[
            endpoints.writable,
            32,
          ]),
          0,
        );

        await expectLater(
          waitableHost.waitableSetWaitToMemory(waitableSet, memory, 160),
          completion(WASIComponentWaitableEventCode.futureRead.value),
        );
        expect(data.getUint32(64, Endian.little), 128);
        expect(data.getUint32(68, Endian.little), 4);
        expect(String.fromCharCodes(bytes.sublist(128, 132)), 'done');
        expect(data.getUint32(160, Endian.little), endpoints.readable);
        expect(data.getUint32(164, Endian.little), 0);
        waitableHost.waitableJoin(endpoints.readable, 0);
        waitableHost.waitableSetDrop(waitableSet);
        _dropFutureEndpointHandles(host, endpoints);
        expect(host.table.activeCount, 0);
      },
    );

    test('copies list futures through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalListFutureMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 2, Endian.little);
      data.setUint32(96, 7, Endian.little);
      data.setUint32(100, 8, Endian.little);
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(
        plan.asyncValueBindings.single.kind,
        WASIComponentAsyncValueBindingKind.future,
      );
      expect(plan.asyncValueBindings.single.primitive, isNull);
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 8);
      expect(plan.asyncValueBindings.single.memoryLayout!.alignment, 4);
      expect(plan.bindingErrors, isEmpty);

      final binding = plan.bind();
      final endpoints = _newFutureEndpointHandles(host, typeIndex: 1);
      expect(
        binding.program.invokeWithMemory(1, memory, <Object?>[
          endpoints.writable,
          32,
        ]),
        0,
      );
      expect(
        () => binding.program.invokeWithMemory(0, memory, <Object?>[
          endpoints.readable,
          64,
        ]),
        throwsUnsupportedError,
      );
      expect(
        binding.program.invokeWithMemory(
          0,
          memory,
          <Object?>[endpoints.readable, 64],
          realloc: (oldPointer, oldSize, alignment, newSize) {
            expect(oldPointer, 0);
            expect(oldSize, 0);
            expect(alignment, 4);
            expect(newSize, 8);
            return 128;
          },
        ),
        0,
      );
      expect(data.getUint32(64, Endian.little), 128);
      expect(data.getUint32(68, Endian.little), 2);
      expect(data.getUint32(128, Endian.little), 7);
      expect(data.getUint32(132, Endian.little), 8);
      _dropFutureEndpointHandles(host, endpoints, typeIndex: 1);
      expect(host.table.activeCount, 0);
    });

    test('copies string list futures through decoded core memory options', () {
      final component = WasmComponent.decode(
        _canonicalStringListFutureMemoryProgramBytes(),
      );
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final data = ByteData.view(memory.buffer);
      bytes.setAll(160, 'go'.codeUnits);
      bytes.setAll(176, 'hi'.codeUnits);
      data.setUint32(96, 160, Endian.little);
      data.setUint32(100, 2, Endian.little);
      data.setUint32(104, 176, Endian.little);
      data.setUint32(108, 2, Endian.little);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 2, Endian.little);
      final host = WASIComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isTrue);
      expect(plan.asyncValueBindings, hasLength(1));
      expect(
        plan.asyncValueBindings.single.kind,
        WASIComponentAsyncValueBindingKind.future,
      );
      expect(plan.asyncValueBindings.single.primitive, isNull);
      expect(plan.asyncValueBindings.single.memoryLayout!.byteLength, 8);
      expect(plan.asyncValueBindings.single.memoryLayout!.alignment, 4);
      expect(plan.bindingErrors, isEmpty);

      final binding = plan.bind();
      final endpoints = _newFutureEndpointHandles(host, typeIndex: 1);
      expect(
        binding.program.invokeWithMemory(1, memory, <Object?>[
          endpoints.writable,
          32,
        ]),
        0,
      );
      final allocations = <int>[224, 256, 272];
      expect(
        binding.program.invokeWithMemory(
          0,
          memory,
          <Object?>[endpoints.readable, 64],
          realloc: (oldPointer, oldSize, alignment, newSize) {
            expect(oldPointer, 0);
            expect(oldSize, 0);
            if (allocations.length == 3) {
              expect(alignment, 4);
              expect(newSize, 16);
            } else {
              expect(alignment, 1);
              expect(newSize, 2);
            }
            return allocations.removeAt(0);
          },
        ),
        0,
      );
      expect(data.getUint32(64, Endian.little), 224);
      expect(data.getUint32(68, Endian.little), 2);
      expect(data.getUint32(224, Endian.little), 256);
      expect(data.getUint32(228, Endian.little), 2);
      expect(data.getUint32(232, Endian.little), 272);
      expect(data.getUint32(236, Endian.little), 2);
      expect(String.fromCharCodes(bytes.sublist(256, 258)), 'go');
      expect(String.fromCharCodes(bytes.sublist(272, 274)), 'hi');
      expect(allocations, isEmpty);
      _dropFutureEndpointHandles(host, endpoints, typeIndex: 1);
      expect(host.table.activeCount, 0);
    });

    test(
      'publishes string future write events through decoded core memory options',
      () async {
        final component = WasmComponent.decode(
          _canonicalStringFutureMemoryProgramBytes(),
        );
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final bytes = Uint8List.view(memory.buffer);
        final data = ByteData.view(memory.buffer);
        bytes.setAll(96, 'done'.codeUnits);
        data.setUint32(32, 96, Endian.little);
        data.setUint32(36, 4, Endian.little);
        final host = WASIComponentHost();

        final binding = host.bindComponent(component);
        final endpoints = _newFutureEndpointHandles(host);
        final waitableHost = host.canonicalHost.waitableHost;
        final waitableSet = waitableHost.waitableSetNew();
        waitableHost.waitableJoin(endpoints.writable, waitableSet);

        expect(
          binding.program.invokeWithMemoryEvent(1, memory, <Object?>[
            endpoints.writable,
            32,
          ]),
          wasiComponentAsyncBlocked,
        );
        expect(
          binding.program.invokeWithMemory(
            0,
            memory,
            <Object?>[endpoints.readable, 64],
            realloc: (oldPointer, oldSize, alignment, newSize) {
              expect(oldPointer, 0);
              expect(oldSize, 0);
              expect(alignment, 1);
              expect(newSize, 4);
              return 128;
            },
          ),
          0,
        );

        await expectLater(
          waitableHost.waitableSetWaitToMemory(waitableSet, memory, 160),
          completion(WASIComponentWaitableEventCode.futureWrite.value),
        );
        expect(data.getUint32(64, Endian.little), 128);
        expect(data.getUint32(68, Endian.little), 4);
        expect(String.fromCharCodes(bytes.sublist(128, 132)), 'done');
        expect(data.getUint32(160, Endian.little), endpoints.writable);
        expect(data.getUint32(164, Endian.little), 0);
        waitableHost.waitableJoin(endpoints.writable, 0);
        waitableHost.waitableSetDrop(waitableSet);
        _dropFutureEndpointHandles(host, endpoints);
        expect(host.table.activeCount, 0);
      },
    );
  });
}

WASIComponentAsyncEndpointHandles _newStreamEndpointHandles(
  WASIComponentHost host, {
  int typeIndex = 0,
}) {
  final handles = host.canonicalHost.asyncHost
      .bindCanonicalDefinition(
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: typeIndex,
        ),
      )
      .streamNewPackedHandles();
  return WASIComponentAsyncEndpointHandles.unpack(handles);
}

void _dropStreamEndpointHandles(
  WASIComponentHost host,
  WASIComponentAsyncEndpointHandles endpoints, {
  int typeIndex = 0,
}) {
  host.canonicalHost.asyncHost
      .bindCanonicalDefinition(
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropReadable,
          typeIndex: typeIndex,
        ),
      )
      .streamDropReadableHandle(endpoints.readable);
  host.canonicalHost.asyncHost
      .bindCanonicalDefinition(
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropWritable,
          typeIndex: typeIndex,
        ),
      )
      .streamDropWritableHandle(endpoints.writable);
}

WASIComponentAsyncEndpointHandles _newFutureEndpointHandles(
  WASIComponentHost host, {
  int typeIndex = 0,
}) {
  final handles = host.canonicalHost.asyncHost
      .bindCanonicalDefinition(
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureNew,
          typeIndex: typeIndex,
        ),
      )
      .futureNewPackedHandles();
  return WASIComponentAsyncEndpointHandles.unpack(handles);
}

void _dropFutureEndpointHandles(
  WASIComponentHost host,
  WASIComponentAsyncEndpointHandles endpoints, {
  int typeIndex = 0,
}) {
  host.canonicalHost.asyncHost
      .bindCanonicalDefinition(
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropReadable,
          typeIndex: typeIndex,
        ),
      )
      .futureDropReadableHandle(endpoints.readable);
  host.canonicalHost.asyncHost
      .bindCanonicalDefinition(
        WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropWritable,
          typeIndex: typeIndex,
        ),
      )
      .futureDropWritableHandle(endpoints.writable);
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

Uint8List _canonicalListStreamMemoryProgramBytes() =>
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
      0x06,
      0x02,
      0x70,
      0x79,
      0x66,
      0x01,
      0x00,
      0x08,
      0x0d,
      0x02,
      0x0f,
      0x01,
      0x02,
      0x03,
      0x00,
      0x04,
      0x00,
      0x10,
      0x01,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _canonicalStringListStreamMemoryProgramBytes() =>
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
      0x06,
      0x02,
      0x70,
      0x73,
      0x66,
      0x01,
      0x00,
      0x08,
      0x0d,
      0x02,
      0x0f,
      0x01,
      0x02,
      0x03,
      0x00,
      0x04,
      0x00,
      0x10,
      0x01,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _canonicalListFutureMemoryProgramBytes() =>
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
      0x06,
      0x02,
      0x70,
      0x79,
      0x65,
      0x01,
      0x00,
      0x08,
      0x0d,
      0x02,
      0x16,
      0x01,
      0x02,
      0x03,
      0x00,
      0x04,
      0x00,
      0x17,
      0x01,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _canonicalStringListFutureMemoryProgramBytes() =>
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
      0x06,
      0x02,
      0x70,
      0x73,
      0x65,
      0x01,
      0x00,
      0x08,
      0x0d,
      0x02,
      0x16,
      0x01,
      0x02,
      0x03,
      0x00,
      0x04,
      0x00,
      0x17,
      0x01,
      0x01,
      0x03,
      0x00,
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

Uint8List _canonicalStringFutureMemoryProgramBytes() =>
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
      0x65,
      0x01,
      0x73,
      0x08,
      0x0d,
      0x02,
      0x16,
      0x00,
      0x02,
      0x03,
      0x00,
      0x04,
      0x00,
      0x17,
      0x00,
      0x01,
      0x03,
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

Uint8List _streamIndexedNestedAsyncCanonicalBytes() =>
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
      0x07,
      0x02,
      0x66,
      0x01,
      0x79,
      0x66,
      0x01,
      0x00,
      0x08,
      0x03,
      0x01,
      0x0e,
      0x01,
    ]);

const _preview2ResourceContracts = <String, List<String>>{
  'wasi:cli/terminal-input': ['terminal-input'],
  'wasi:cli/terminal-output': ['terminal-output'],
  'wasi:io/error': ['error'],
  'wasi:io/poll': ['pollable'],
  'wasi:io/streams': ['input-stream', 'output-stream'],
  'wasi:filesystem/types': ['descriptor', 'directory-entry-stream'],
  'wasi:http/types': [
    'fields',
    'incoming-request',
    'outgoing-request',
    'request-options',
    'response-outparam',
    'incoming-response',
    'incoming-body',
    'future-trailers',
    'outgoing-response',
    'outgoing-body',
    'future-incoming-response',
  ],
  'wasi:sockets/network': ['network'],
  'wasi:sockets/ip-name-lookup': ['resolve-address-stream'],
  'wasi:sockets/tcp': ['tcp-socket'],
  'wasi:sockets/udp': [
    'udp-socket',
    'incoming-datagram-stream',
    'outgoing-datagram-stream',
  ],
};

const _preview3ResourceContracts = <String, List<String>>{
  'wasi:cli/terminal-input': ['terminal-input'],
  'wasi:cli/terminal-output': ['terminal-output'],
  'wasi:filesystem/types': ['descriptor'],
  'wasi:http/types': ['fields', 'request', 'request-options', 'response'],
  'wasi:sockets/types': ['tcp-socket', 'udp-socket'],
};
