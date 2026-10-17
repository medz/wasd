import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/adapter_host.dart';
import 'package:wasd/src/wasi/component/adapter_plan.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/canonical_handles.dart';
import 'package:wasd/src/wasi/component/context.dart';
import 'package:wasd/src/wasi/component/error_context.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasi/component/resource_table.dart';
import 'package:wasd/src/wasi/component/string_memory.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

import 'support/component_fixtures.dart' as fixtures;

void main() {
  for (final mode in ['sync', 'async flat', 'async indirect']) {
    for (final duplicate in [false, true]) {
      test(
        'result transaction preserves $mode ${duplicate ? 'duplicate' : 'invalid'} owners',
        () async {
          final store = _Store();
          await _scoped(store, () {
            final width = mode == 'async indirect' ? 17 : 2;
            final component = _types([
              0x3f,
              0x7f,
              0,
              0x69,
              0,
              0x6f,
              width,
              ...List.filled(width, 1),
            ], 3);
            final type = store.type();
            final instance = _Instance(store, component, type);
            final uses = [
              for (var i = 0; i < width; i++)
                WASIComponentResourceUse(
                  canonicalIndex: 0,
                  canonicalKind: WasmComponentCanonicalKind.lift,
                  path: 'canonical[0].result.item[$i]',
                  handleKind: WASIComponentResourceHandleKind.own,
                  resourceTypeIndex: 0,
                  binding: null,
                ),
            ];
            const resultType = WasmComponentValueType.typeIndex(2);
            final plan = WASIComponentCanonicalAdapterPlan(
              canonicalIndex: 0,
              definition: const WasmComponentCanonicalDefinition(
                kind: WasmComponentCanonicalKind.lift,
                coreFunctionIndex: 0,
              ),
              functionType: const WasmComponentFunctionType(
                params: [],
                result: resultType,
              ),
              params: const [],
              result: WASIComponentCanonicalAdapterValuePlan(
                path: 'canonical[0].result',
                label: null,
                type: resultType,
                memoryCodec: null,
                flatLayout: componentCanonicalFlatLayout(
                  resultType,
                  component.componentTypeIndexDefinitions,
                  typeScope: component.componentTypeIndexScope,
                ),
                resourceUses: uses,
              ),
              resourceUses: uses,
              stringEncoding: WASIComponentCanonicalStringEncoding.utf8,
              memoryIndex: 0,
              reallocIndex: null,
              postReturnIndex: null,
              callbackIndex: null,
              isAsync: mode != 'sync',
            );
            final guests = [
              for (var i = 0; i < width; i++)
                instance.handles.newResource(0, i + 1),
            ];
            final memory = _memory();
            final data = ByteData.view(memory.buffer);
            final failing = [
              ...guests.take(width - 1),
              duplicate ? guests.first : 0,
            ];
            for (var i = 0; i < width; i++) {
              data.setUint32(64 + i * 4, failing[i], Endian.little);
            }
            var calls = 0;
            final program = const WASIComponentCanonicalAdapterHost()
                .bindCanonicalAdapterPlans(
                  [plan],
                  endpointBindings: instance.handles,
                  coreFunctions: {
                    0: (_) {
                      calls++;
                      return 64;
                    },
                  },
                );
            Object? load(List<int> values) => mode == 'sync'
                ? program.invokeLiftedCore(0, [], memory: memory)
                : program.operations.single.finishAsyncLiftResult(
                    mode == 'async flat' ? values : 64,
                    memory: memory,
                  );
            expect(() => load(failing), throwsStateError);
            expect(calls, mode == 'sync' ? 1 : 0);
            for (var i = 0; i < width; i++) {
              expect(instance.handles.resourceRep(0, guests[i]), i + 1);
            }
            expect(store.dropped, isEmpty);
            for (var i = 0; i < width; i++) {
              data.setUint32(64 + i * 4, guests[i], Endian.little);
            }
            final result = load(guests)! as WasmComponentValueData;
            expect(calls, mode == 'sync' ? 2 : 0);
            for (final guest in guests) {
              expect(
                () => instance.handles.resourceRep(0, guest),
                throwsStateError,
              );
            }
            for (final item
                in result.itemValues.cast<WasmComponentValueData>()) {
              store.table.drop(type, item.integer! as int);
            }
            expect(store.dropped, [for (var i = 0; i < width; i++) i + 1]);
            expect(store.table.activeCount, 0);
          });
        },
      );
    }
  }

  for (final future in [false, true]) {
    for (final enumeration in [false, true]) {
      for (final difference in ['same', 'order', 'label', 'nominal']) {
        test(
          '${future ? 'future' : 'stream'} own-resource ${enumeration ? 'enum' : 'flags'} payload key: $difference',
          () async {
            final store = _Store();
            await _scoped(store, () {
              WasmComponent component(List<String> labels) => _types([
                0x3f,
                0x7f,
                0,
                0x69,
                0,
                enumeration ? 0x6d : 0x6e,
                labels.length,
                for (final label in labels) ...[
                  label.length,
                  ...label.codeUnits,
                ],
                0x6f,
                2,
                1,
                2,
                future ? 0x65 : 0x66,
                1,
                3,
              ], 5);
              final type = store.type();
              final source = _Instance(
                store,
                component(['first', 'second']),
                type,
              );
              final target = _Instance(
                store,
                component(switch (difference) {
                  'order' => ['second', 'first'],
                  'label' => ['first', 'third'],
                  _ => ['first', 'second'],
                }),
                difference == 'nominal' ? store.type() : type,
              );
              final pair = future ? source.future(4) : source.stream(4);
              final endpoint = source.handles.liftReadableEndpoint(
                4,
                pair.readable,
              );
              final _Instance receiver;
              final int readable;
              if (difference == 'same') {
                receiver = target;
                readable = target.handles.lowerReadableEndpoint(4, endpoint);
              } else {
                expect(
                  () => target.handles.lowerReadableEndpoint(4, endpoint),
                  throwsStateError,
                );
                receiver = source;
                readable = source.handles.lowerReadableEndpoint(4, endpoint);
              }
              if (future) {
                final owner = source.handles.liftResourceHandle(
                  0,
                  source.handles.newResource(0, 42),
                  owned: true,
                );
                source
                    .operation(WasmComponentCanonicalKind.futureWrite, 4)
                    .futureWriteHandle(
                      source.backing(pair.writable),
                      WasmComponentValueData(
                        kind: WasmComponentValueDataKind.tuple,
                        rawBytes: Uint8List(0),
                        items: [
                          WasmComponentValueData(
                            kind: WasmComponentValueDataKind.integer,
                            rawBytes: Uint8List(0),
                            integer: owner,
                          ),
                          WasmComponentValueData(
                            kind: enumeration
                                ? WasmComponentValueDataKind.enumeration
                                : WasmComponentValueDataKind.flags,
                            rawBytes: Uint8List(0),
                            index: enumeration ? 0 : null,
                            label: enumeration ? 'first' : null,
                            labels: enumeration ? [] : ['first'],
                          ),
                        ],
                      ),
                    );
                receiver
                    .operation(WasmComponentCanonicalKind.futureDropReadable, 4)
                    .futureDropReadableHandle(receiver.backing(readable));
                source
                    .operation(WasmComponentCanonicalKind.futureDropWritable, 4)
                    .futureDropWritableHandle(source.backing(pair.writable));
              } else {
                receiver
                    .operation(WasmComponentCanonicalKind.streamDropReadable, 4)
                    .streamDropReadableHandle(receiver.backing(readable));
                source
                    .operation(WasmComponentCanonicalKind.streamDropWritable, 4)
                    .streamDropWritableHandle(source.backing(pair.writable));
              }
              expect(store.table.activeCount, 0);
            });
          },
        );
      }
    }
  }

  test(
    'scoped numeric aliases keep same-instance rendezvous numeric',
    () async {
      final store = _Store();
      await _scoped(store, () async {
        final instance = _Instance(
          store,
          WasmComponent.decode(
            fixtures.scopedPrimitiveStreamTypeComponentBytes(),
          ),
          store.type(),
        );
        final pair = instance.stream(0);
        final memory = _memory();
        final data = ByteData.view(memory.buffer)
          ..setUint32(0, 42, Endian.little);
        Object? readFailure;
        final reading = instance
            .operation(WasmComponentCanonicalKind.streamRead, 0)
            .streamReadHandleToMemoryWhenAvailable(
              instance.backing(pair.readable),
              memory,
              16,
              1,
            )
            .then<WASIComponentAsyncCopyResult?>(
              (result) => result,
              onError: (Object error) {
                readFailure = error;
                return null;
              },
            );
        Object? writeFailure;
        WASIComponentAsyncCopyResult? written;
        try {
          written = instance
              .operation(WasmComponentCanonicalKind.streamWrite, 0)
              .streamWriteHandleFromMemory(
                instance.backing(pair.writable),
                memory,
                0,
                1,
              );
        } catch (error) {
          writeFailure = error;
        }
        final read = await reading;
        expect(writeFailure, isNull);
        expect(readFailure, isNull);
        expect(written?.packedResult, 16);
        expect(read?.packedResult, 16);
        expect(data.getUint32(16, Endian.little), 42);
      });
    },
  );

  test('moving an owner preserves its live children and drop guard', () async {
    final store = _Store();
    await _scoped(store, () {
      final type = store.type();
      final childType = store.type();
      final source = _Instance(store, _ownStream(), type);
      final target = _Instance(store, _ownStream(), type);
      final owner = source.handles.newResource(0, 77);
      final child = store.table.resourceNew(childType, 18);
      store.table.attachChild(source.backing(owner), child);
      expect(() => source.handles.resourceDrop(0, owner), throwsStateError);
      final moved = source.handles.withHandleLifting(
        () => source.handles.liftResourceHandle(0, owner, owned: true),
      );
      expect(() => source.handles.resourceRep(0, owner), throwsStateError);
      final received = target.handles.lowerResourceHandle(
        0,
        moved,
        owned: true,
      );
      expect(target.handles.resourceRep(0, received), 77);
      expect(() => target.handles.resourceDrop(0, received), throwsStateError);
      expect(() => store.table.drop(type, moved), throwsStateError);
      expect(store.dropped, isEmpty);
      store.table.drop(childType, child);
      target.handles.resourceDrop(0, received);
      expect(store.dropped, [18, 77]);
      expect(store.table.activeCount, 0);
    });
  });

  for (final duplicate in [false, true]) {
    test(
      'own parameter transaction preserves guests after ${duplicate ? 'duplicate' : 'invalid'} suffix',
      () async {
        final store = _Store();
        await _scoped(store, () {
          final type = store.type();
          final instance = _Instance(store, _ownStream(), type);
          final first = instance.handles.newResource(0, 11);
          final second = instance.handles.newResource(0, 22);
          expect(
            () => instance.handles.withHandleLifting(() {
              instance.handles.liftResourceHandle(0, first, owned: true);
              instance.handles.liftResourceHandle(
                0,
                duplicate ? first : 0,
                owned: true,
              );
            }),
            throwsStateError,
          );
          expect(instance.handles.resourceRep(0, first), 11);
          expect(instance.handles.resourceRep(0, second), 22);
          final lifted = instance.handles.withHandleLifting(
            () => [
              instance.handles.liftResourceHandle(0, first, owned: true),
              instance.handles.liftResourceHandle(0, second, owned: true),
            ],
          );
          expect(
            () => instance.handles.resourceRep(0, first),
            throwsStateError,
          );
          for (final handle in lifted) {
            store.table.drop(type, handle);
          }
          expect(store.dropped, [11, 22]);
          expect(store.table.activeCount, 0);
        });
      },
    );
  }

  for (final arm in ['ok', 'empty', 'detail']) {
    test(
      'scoped payload aliases retain their original definition context: $arm',
      () async {
        final store = _Store();
        await _scoped(store, () {
          final component = WasmComponent.decode(
            fixtures.scopedResultFutureTypeComponentBytes(),
          );
          final instance = _Instance(store, component, store.type());
          final pair = instance.future(0);
          final target = _Instance(store, component, store.type());
          final endpoint = instance.handles.liftReadableEndpoint(
            0,
            pair.readable,
          );
          final reader = target.handles.lowerReadableEndpoint(0, endpoint);
          final value = WasmComponentValueData(
            kind: WasmComponentValueDataKind.result,
            rawBytes: Uint8List(0),
            isOk: arm == 'ok',
            associatedValue: arm == 'ok'
                ? null
                : WasmComponentValueData(
                    kind: WasmComponentValueDataKind.variant,
                    rawBytes: Uint8List(0),
                    index: arm == 'empty' ? 0 : 1,
                    label: arm,
                    associatedValue: arm == 'empty'
                        ? null
                        : WasmComponentValueData(
                            kind: WasmComponentValueDataKind.tuple,
                            rawBytes: Uint8List(0),
                            items: [
                              WasmComponentValueData(
                                kind: WasmComponentValueDataKind.integer,
                                rawBytes: Uint8List.fromList([42]),
                                integer: 42,
                              ),
                            ],
                          ),
                  ),
          );
          instance
              .operation(WasmComponentCanonicalKind.futureWrite, 0)
              .futureWriteHandle(instance.backing(pair.writable), value);
          final memory = _memory();
          expect(
            target
                .operation(WasmComponentCanonicalKind.futureRead, 0)
                .futureReadHandleToMemory(target.backing(reader), memory, 32)
                .packedResult,
            0,
          );
          final bytes = Uint8List.view(memory.buffer);
          expect(bytes[32], arm == 'ok' ? 0 : 1);
          if (arm != 'ok') expect(bytes[33], arm == 'empty' ? 0 : 1);
          if (arm == 'detail') expect(bytes[34], 42);
          target
              .operation(WasmComponentCanonicalKind.futureDropReadable, 0)
              .futureDropReadableHandle(target.backing(reader));
          instance
              .operation(WasmComponentCanonicalKind.futureDropWritable, 0)
              .futureDropWritableHandle(instance.backing(pair.writable));
          expect(store.table.activeCount, 0);
        });
      },
    );
  }

  for (final owned in [false, true]) {
    test(
      'huge fixed-list ${owned ? 'own' : 'pure'} endpoint initialization stays compact',
      () async {
        final store = _Store();
        await _scoped(store, () {
          final component = _types([
            if (owned) ...[0x3f, 0x7f, 0, 0x69, 0],
            0x67,
            owned ? 1 : 0x7d,
            ..._u32(owned ? 67108863 : 268435455),
            0x66,
            1,
            owned ? 2 : 0,
            0x66,
            1,
            owned ? 2 : 0,
          ], owned ? 5 : 3);
          final instance = _Instance(store, component, store.type());
          final index = owned ? 3 : 1;
          final pair = instance.stream(index);
          // Equivalent aliases still require a full structural/nominal type key.
          final endpoint = instance.handles.liftReadableEndpoint(
            index + 1,
            pair.readable,
          );
          expect(
            instance.handles.lowerReadableEndpoint(index, endpoint),
            pair.readable,
          );
          instance
              .operation(WasmComponentCanonicalKind.streamDropReadable, index)
              .streamDropReadableHandle(instance.backing(pair.readable));
          instance
              .operation(WasmComponentCanonicalKind.streamDropWritable, index)
              .streamDropWritableHandle(instance.backing(pair.writable));
          expect(store.table.activeCount, 0);
        });
      },
    );
  }

  test(
    'equivalent shared payload DAGs keep metadata bounded by type nodes',
    () async {
      final store = _Store();
      await _scoped(store, () {
        final definitions = <int>[];
        const depth = 19;
        for (var chain = 0; chain < 2; chain++) {
          for (var level = 0; level < depth; level++) {
            final child = level == 0 ? 0x7d : chain * depth + level - 1;
            definitions.addAll([0x6f, 2, child, child]);
          }
        }
        definitions.addAll([0x66, 1, depth - 1, 0x66, 1, 2 * depth - 1]);
        final instance = _Instance(
          store,
          _types(definitions, 2 * depth + 2),
          store.type(),
        );
        final pair = instance.stream(2 * depth);
        final endpoint = instance.handles.liftReadableEndpoint(
          2 * depth + 1,
          pair.readable,
        );
        expect(
          instance.handles.lowerReadableEndpoint(2 * depth, endpoint),
          pair.readable,
        );
      });
    },
  );

  for (final shape in [
    (
      name: 'primitive',
      definitions: <int>[0x66, 1, 0x7d, 0x66, 1, 0x7b],
      count: 2,
      first: 0,
      second: 1,
    ),
    (
      name: 'fixed length',
      definitions: <int>[0x67, 0x7d, 2, 0x67, 0x7d, 3, 0x66, 1, 0, 0x66, 1, 1],
      count: 4,
      first: 2,
      second: 3,
    ),
    (
      name: 'dynamic versus fixed list',
      definitions: <int>[0x70, 0x7d, 0x67, 0x7d, 2, 0x66, 1, 0, 0x66, 1, 1],
      count: 4,
      first: 2,
      second: 3,
    ),
    (
      name: 'record label',
      definitions: <int>[
        0x72,
        1,
        1,
        120,
        0x7d,
        0x72,
        1,
        1,
        121,
        0x7d,
        0x66,
        1,
        0,
        0x66,
        1,
        1,
      ],
      count: 4,
      first: 2,
      second: 3,
    ),
    (
      name: 'tuple versus record',
      definitions: <int>[
        0x6f,
        1,
        0x7d,
        0x72,
        1,
        1,
        120,
        0x7d,
        0x66,
        1,
        0,
        0x66,
        1,
        1,
      ],
      count: 4,
      first: 2,
      second: 3,
    ),
    (
      name: 'option versus result',
      definitions: <int>[0x6b, 0x7d, 0x6a, 1, 0x7d, 0, 0x66, 1, 0, 0x66, 1, 1],
      count: 4,
      first: 2,
      second: 3,
    ),
  ]) {
    test('payload structural key preserves ${shape.name}', () async {
      final store = _Store();
      await _scoped(store, () {
        final instance = _Instance(
          store,
          _types(shape.definitions, shape.count),
          store.type(),
        );
        final pair = instance.stream(shape.first);
        expect(
          () => instance.handles.liftReadableEndpoint(
            shape.second,
            pair.readable,
          ),
          throwsStateError,
        );
        final endpoint = instance.handles.liftReadableEndpoint(
          shape.first,
          pair.readable,
        );
        expect(
          instance.handles.lowerReadableEndpoint(shape.first, endpoint),
          pair.readable,
        );
      });
    });
  }

  for (final future in [false, true]) {
    test(
      '${future ? 'future' : 'stream'} readable endpoint cannot be owned by two instances',
      () async {
        final store = _Store();
        await _scoped(store, () {
          final type = store.type();
          final component = future ? _ownFuture() : _ownStream();
          final source = _Instance(store, component, type);
          final first = _Instance(store, component, type);
          final second = _Instance(store, component, type);
          final pair = future ? source.future(2) : source.stream(2);
          final endpoint = source.handles.liftReadableEndpoint(
            2,
            pair.readable,
          );
          final reader = first.handles.lowerReadableEndpoint(2, endpoint);
          final count = store.table.activeCount;
          expect(
            () => second.handles.lowerReadableEndpoint(2, endpoint),
            throwsStateError,
          );
          expect(store.table.activeCount, count);
          final returned = first.handles.liftReadableEndpoint(2, reader);
          expect(
            source.handles.lowerReadableEndpoint(2, returned),
            pair.readable,
          );
        });
      },
    );
  }

  for (final asynchronous in [false, true]) {
    test(
      'internal error carriers are reclaimed after ${asynchronous ? 'Future rejection' : 'sync failure'}',
      () async {
        final store = _Store();
        await _scoped(store, () async {
          final instance = _Instance(store, _ownStream(), store.type());
          final guest = instance.handles.add(
            store.errors.create('kept'),
            WASIComponentCanonicalHandleKind.errorContext,
          );
          var temporary = 0;
          if (asynchronous) {
            await expectLater(
              instance.handles.withHandleCall<Future<void>>(() async {
                temporary = instance.handles.liftErrorContextHandle(guest);
                await Future<void>.delayed(Duration.zero);
                expect(store.errors.debugMessage(temporary), 'kept');
                throw StateError('callback failed');
              }, internalCall: true),
              throwsStateError,
            );
          } else {
            expect(
              () => instance.handles.withHandleCall<void>(() {
                temporary = instance.handles.liftErrorContextHandle(guest);
                throw StateError('callback failed');
              }, internalCall: true),
              throwsStateError,
            );
          }
          expect(store.table.contains(temporary), isFalse);
          expect(store.errors.debugMessage(instance.backing(guest)), 'kept');
          expect(store.table.activeCount, 1);
          store.errors.drop(instance.handles.remove(guest));
        });
      },
    );
  }

  test(
    'retained internal error carriers live until explicit completion delivery',
    () async {
      final store = _Store();
      await _scoped(store, () async {
        final instance = _Instance(store, _ownStream(), store.type());
        final guest = instance.handles.add(
          store.errors.create('kept'),
          WASIComponentCanonicalHandleKind.errorContext,
        );
        late void Function() close;
        final temporary = await instance.handles.withHandleCall<Future<int>>(
          () async {
            final carrier = instance.handles.liftErrorContextHandle(guest);
            await Future<void>.delayed(Duration.zero);
            return carrier;
          },
          internalCall: true,
          retain: (release) => close = release,
        );
        expect(store.errors.debugMessage(temporary), 'kept');
        expect(store.table.activeCount, 2);
        close();
        close();
        expect(store.table.contains(temporary), isFalse);
        expect(store.table.activeCount, 1);
        store.errors.drop(instance.handles.remove(guest));
      });
    },
  );

  test(
    'generic callback error references survive the enclosing native carrier scope',
    () async {
      final store = _Store();
      await _scoped(store, () {
        final instance = _Instance(store, _ownStream(), store.type());
        final guest = instance.handles.add(
          store.errors.create('kept'),
          WASIComponentCanonicalHandleKind.errorContext,
        );
        var internal = 0;
        var hostReference = 0;
        instance.handles.withHandleCall(() {
          internal = instance.handles.liftErrorContextHandle(guest);
          hostReference = instance.handles.withHandleCall(
            () => instance.handles.liftErrorContextHandle(guest),
            internalCall: false,
          );
        }, internalCall: true);
        expect(store.table.contains(internal), isFalse);
        expect(store.errors.debugMessage(hostReference), 'kept');
        store.errors.drop(instance.handles.remove(guest));
        expect(store.errors.debugMessage(hostReference), 'kept');
        store.errors.drop(hostReference);
        expect(store.table.activeCount, 0);
      });
    },
  );

  test(
    'pending stream source retains its remaining owners until event delivery',
    () async {
      final store = _Store();
      await _scoped(store, () async {
        final type = store.type();
        final source = _Instance(store, _ownStream(), type);
        final target = _Instance(store, _ownStream(), type);
        final pair = source.stream(2);
        final first = source.handles.newResource(0, 50);
        final second = source.handles.newResource(0, 51);
        final memory = _memory();
        final data = ByteData.view(memory.buffer)
          ..setUint32(32, first, Endian.little)
          ..setUint32(36, second, Endian.little);
        final writer = source.backing(pair.writable);
        final write = source.operation(
          WasmComponentCanonicalKind.streamWrite,
          2,
        );
        expect(
          write.streamWriteHandleFromMemoryEvent(writer, memory, 32, 2),
          wasiComponentAsyncBlocked,
        );
        final reader = target.handles.lowerReadableEndpoint(
          2,
          source.handles.liftReadableEndpoint(2, pair.readable),
        );
        final read = target.operation(WasmComponentCanonicalKind.streamRead, 2);
        final firstResult = read.streamReadHandleToMemory(
          target.backing(reader),
          memory,
          96,
          1,
        );
        expect(firstResult.copiedElements, 1);
        final receivedFirst = data.getUint32(96, Endian.little);
        target.handles.resourceDrop(0, receivedFirst);
        expect(source.handles.resourceRep(0, second), 51);
        final secondResult = read.streamReadHandleToMemory(
          target.backing(reader),
          memory,
          100,
          1,
        );
        final cancelled = await source
            .operation(WasmComponentCanonicalKind.streamCancelWrite, 2)
            .streamCancelWriteHandleWhenReady(writer);
        expect(
          secondResult.copiedElements,
          1,
          reason: 'the writer event has not consumed its remaining buffer',
        );
        expect(
          cancelled,
          34,
          reason: 'the final event includes both accepted prefixes',
        );
        expect(() => source.handles.resourceRep(0, second), throwsStateError);
        expect(
          target.handles.resourceRep(0, data.getUint32(100, Endian.little)),
          51,
        );
        target.handles.resourceDrop(0, data.getUint32(100, Endian.little));
        expect(store.dropped, [50, 51]);
      });
    },
  );

  test(
    'pending stream target retains its remaining memory until event delivery',
    () async {
      final store = _Store();
      await _scoped(store, () async {
        final type = store.type();
        final source = _Instance(store, _ownStream(), type);
        final target = _Instance(store, _ownStream(), type);
        final pair = source.stream(2);
        final first = source.handles.newResource(0, 50);
        final second = source.handles.newResource(0, 51);
        final memory = _memory();
        final data = ByteData.view(memory.buffer)
          ..setUint32(32, first, Endian.little)
          ..setUint32(36, second, Endian.little)
          ..setUint32(104, 0xdeadbeef, Endian.little);
        final reader = target.handles.lowerReadableEndpoint(
          2,
          source.handles.liftReadableEndpoint(2, pair.readable),
        );
        final read = target.operation(WasmComponentCanonicalKind.streamRead, 2);
        expect(
          read.streamReadHandleToMemoryEvent(
            target.backing(reader),
            memory,
            96,
            2,
          ),
          wasiComponentAsyncBlocked,
        );
        final write = source.operation(
          WasmComponentCanonicalKind.streamWrite,
          2,
        );
        final firstResult = write.streamWriteHandleFromMemory(
          source.backing(pair.writable),
          memory,
          32,
          1,
        );
        final secondResult = write.streamWriteHandleFromMemory(
          source.backing(pair.writable),
          memory,
          36,
          1,
        );
        final cancelled = await target
            .operation(WasmComponentCanonicalKind.streamCancelRead, 2)
            .streamCancelReadHandleWhenReady(target.backing(reader));
        expect(firstResult.copiedElements, 1);
        expect(
          secondResult.copiedElements,
          1,
          reason: 'the pending reader still has one destination slot',
        );
        expect(cancelled, 34);
        expect(() => source.handles.resourceRep(0, first), throwsStateError);
        expect(() => source.handles.resourceRep(0, second), throwsStateError);
        final receivedFirst = data.getUint32(96, Endian.little);
        final receivedSecond = data.getUint32(100, Endian.little);
        expect(target.handles.resourceRep(0, receivedFirst), 50);
        expect(target.handles.resourceRep(0, receivedSecond), 51);
        expect(data.getUint32(104, Endian.little), 0xdeadbeef);
        target.handles.resourceDrop(0, receivedFirst);
        target.handles.resourceDrop(0, receivedSecond);
        expect(store.dropped, [50, 51]);
      });
    },
  );

  test('endpoint payload provenance survives a different async host', () async {
    final sourceStore = _Store();
    final targetStore = _Store();
    await _scoped(sourceStore, () async {
      await _scoped(targetStore, () {
        final component = _ownStream();
        final source = _Instance(sourceStore, component, sourceStore.type());
        final target = _Instance(targetStore, component, targetStore.type());
        final pair = source.stream(2);
        final endpoint = source.handles.liftReadableEndpoint(2, pair.readable);
        final count = targetStore.table.activeCount;
        expect(
          () => target.handles.lowerReadableEndpoint(2, endpoint),
          throwsStateError,
        );
        expect(
          targetStore.table.activeCount,
          count,
          reason: 'reject before inserting a foreign nominal endpoint',
        );
        expect(
          source.handles.lowerReadableEndpoint(2, endpoint),
          pair.readable,
        );
      });
    });
  });

  test(
    'composite discard releases every owner even when the first destructor traps',
    () async {
      final store = _Store();
      await _scoped(store, () {
        final component = _types([
          0x3f,
          0x7f,
          0,
          0x69,
          0,
          0x6f,
          2,
          1,
          1,
          0x66,
          1,
          2,
        ], 4);
        final source = _Instance(
          store,
          component,
          store.type(throwOnDrop: 42),
          capacity: 1,
        );
        final pair = source.stream(3);
        final first = source.handles.newResource(0, 42);
        final second = source.handles.newResource(0, 51);
        final memory = _memory();
        ByteData.view(memory.buffer)
          ..setUint32(32, first, Endian.little)
          ..setUint32(36, second, Endian.little);
        source
            .operation(WasmComponentCanonicalKind.streamWrite, 3)
            .streamWriteHandleFromMemory(
              source.backing(pair.writable),
              memory,
              32,
              1,
            );
        expect(store.dropped, isEmpty);
        expect(
          () => source
              .operation(WasmComponentCanonicalKind.streamDropReadable, 3)
              .streamDropReadableHandle(source.backing(pair.readable)),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'destructor failed',
            ),
          ),
        );
        expect(store.dropped, [42, 51]);
        expect(() => source.handles.resourceRep(0, first), throwsStateError);
        expect(() => source.handles.resourceRep(0, second), throwsStateError);
        source
            .operation(WasmComponentCanonicalKind.streamDropWritable, 3)
            .streamDropWritableHandle(source.backing(pair.writable));
        expect(store.dropped, [42, 51]);
      });
    },
  );

  test(
    'accepted stream prefix moves its owner and never reads an invalid tail',
    () async {
      final store = _Store();
      await _scoped(store, () {
        final type = store.type();
        final source = _Instance(store, _ownStream(), type, capacity: 1);
        final target = _Instance(store, _ownStream(), type);
        final pair = source.stream(2);
        final first = source.handles.newResource(0, 50);
        final second = source.handles.newResource(0, 51);
        final memory = _memory();
        final data = ByteData.view(memory.buffer)
          ..setUint32(32, first, Endian.little)
          ..setUint32(36, 0, Endian.little);
        expect(
          source
              .operation(WasmComponentCanonicalKind.streamWrite, 2)
              .streamWriteHandleFromMemory(
                source.backing(pair.writable),
                memory,
                32,
                2,
              )
              .copiedElements,
          1,
        );
        expect(() => source.handles.resourceRep(0, first), throwsStateError);
        expect(source.handles.resourceRep(0, second), 51);
        expect(store.dropped, isEmpty);
        final endpoint = source.handles.liftReadableEndpoint(2, pair.readable);
        final reader = target.handles.lowerReadableEndpoint(2, endpoint);
        expect(reader, 1);
        expect(
          target
              .operation(WasmComponentCanonicalKind.streamRead, 2)
              .streamReadHandleToMemory(target.backing(reader), memory, 96, 1)
              .copiedElements,
          1,
        );
        final received = data.getUint32(96, Endian.little);
        expect(target.handles.resourceRep(0, received), 50);
        expect(data.getUint32(36, Endian.little), 0);
        target.handles.resourceDrop(0, received);
        source.handles.resourceDrop(0, second);
        expect(store.dropped, [50, 51]);
      });
    },
  );

  test('duplicate accepted owners are rejected before moving any G', () async {
    final store = _Store();
    await _scoped(store, () {
      final source = _Instance(store, _ownStream(), store.type(), capacity: 2);
      final pair = source.stream(2);
      final owner = source.handles.newResource(0, 42);
      final memory = _memory();
      ByteData.view(memory.buffer)
        ..setUint32(32, owner, Endian.little)
        ..setUint32(36, owner, Endian.little);
      expect(
        () => source
            .operation(WasmComponentCanonicalKind.streamWrite, 2)
            .streamWriteHandleFromMemory(
              source.backing(pair.writable),
              memory,
              32,
              2,
            ),
        throwsStateError,
      );
      expect(source.handles.resourceRep(0, owner), 42);
      expect(store.dropped, isEmpty);
      source.handles.resourceDrop(0, owner);
      expect(store.dropped, [42]);
    });
  });

  test(
    'wrong nominal owner in an accepted prefix preserves the earlier owner',
    () async {
      final store = _Store();
      await _scoped(store, () {
        final type = store.type();
        final other = store.type();
        final source = _Instance(store, _ownStream(), type, capacity: 2);
        final pair = source.stream(2);
        final first = source.handles.newResource(0, 42);
        final wrongBacking = store.table.insert(other, 77);
        final wrong = source.handles.add(
          wrongBacking,
          WASIComponentCanonicalHandleKind.resource,
        );
        final memory = _memory();
        ByteData.view(memory.buffer)
          ..setUint32(32, first, Endian.little)
          ..setUint32(36, wrong, Endian.little);
        expect(
          () => source
              .operation(WasmComponentCanonicalKind.streamWrite, 2)
              .streamWriteHandleFromMemory(
                source.backing(pair.writable),
                memory,
                32,
                2,
              ),
          throwsStateError,
        );
        expect(source.handles.resourceRep(0, first), 42);
        expect(store.table.get(other, wrongBacking), 77);
        expect(store.dropped, isEmpty);
        source.handles.resourceDrop(0, first);
        store.table.drop(other, wrongBacking);
        expect(store.dropped, [42, 77]);
      });
    },
  );

  test(
    'same-model endpoint rejects a fresh nominal payload token before insertion',
    () async {
      final store = _Store();
      await _scoped(store, () {
        final component = _ownStream();
        final source = _Instance(store, component, store.type());
        final target = _Instance(store, component, store.type());
        final pair = source.stream(2);
        final owner = source.handles.newResource(0, 42);
        final endpoint = source.handles.liftReadableEndpoint(2, pair.readable);
        final count = store.table.activeCount;
        expect(
          () => target.handles.lowerReadableEndpoint(2, endpoint),
          throwsStateError,
        );
        expect(store.table.activeCount, count);
        expect(source.handles.resourceRep(0, owner), 42);
        expect(store.dropped, isEmpty);
        expect(
          source.handles.lowerReadableEndpoint(2, endpoint),
          pair.readable,
        );
        source.handles.resourceDrop(0, owner);
      });
    },
  );

  test(
    'equivalent own-bearing aliases share backing only with the same runtime token',
    () async {
      final store = _Store();
      await _scoped(store, () {
        final component = _types([
          0x3f,
          0x7f,
          0,
          0x69,
          0,
          0x66,
          1,
          1,
          0x66,
          1,
          1,
        ], 4);
        final source = _Instance(store, component, store.type(), capacity: 1);
        final pair = source.stream(2);
        final endpoint = source.handles.liftReadableEndpoint(3, pair.readable);
        expect(
          source.handles.lowerReadableEndpoint(2, endpoint),
          pair.readable,
        );
        source
            .operation(WasmComponentCanonicalKind.streamDropReadable, 3)
            .streamDropReadableHandle(source.backing(pair.readable));
        source
            .operation(WasmComponentCanonicalKind.streamDropWritable, 3)
            .streamDropWritableHandle(source.backing(pair.writable));
        expect(store.table.activeCount, 0);
      });
    },
  );

  test(
    'discarding an accepted queued stream owner runs its destructor once',
    () async {
      final store = _Store();
      await _scoped(store, () {
        final source = _Instance(
          store,
          _ownStream(),
          store.type(),
          capacity: 1,
        );
        final pair = source.stream(2);
        final owner = source.handles.newResource(0, 42);
        final memory = _memory();
        ByteData.view(memory.buffer).setUint32(32, owner, Endian.little);
        source
            .operation(WasmComponentCanonicalKind.streamWrite, 2)
            .streamWriteHandleFromMemory(
              source.backing(pair.writable),
              memory,
              32,
              1,
            );
        expect(() => source.handles.resourceRep(0, owner), throwsStateError);
        expect(store.dropped, isEmpty);
        source
            .operation(WasmComponentCanonicalKind.streamDropReadable, 2)
            .streamDropReadableHandle(source.backing(pair.readable));
        expect(store.dropped, [42]);
        source
            .operation(WasmComponentCanonicalKind.streamDropWritable, 2)
            .streamDropWritableHandle(source.backing(pair.writable));
        expect(store.dropped, [42]);
      });
    },
  );

  test(
    'unaccepted invalid future owner is not loaded during cancellation',
    () async {
      final store = _Store();
      await _scoped(store, () async {
        final source = _Instance(store, _ownFuture(), store.type());
        final pair = source.future(2);
        final owner = source.handles.newResource(0, 42);
        final memory = _memory();
        ByteData.view(memory.buffer).setUint32(32, 0, Endian.little);
        expect(
          source
              .operation(WasmComponentCanonicalKind.futureWrite, 2)
              .futureWriteHandleFromMemoryEvent(
                source.backing(pair.writable),
                memory,
                32,
              ),
          wasiComponentAsyncBlocked,
        );
        expect(source.handles.resourceRep(0, owner), 42);
        expect(
          await source
              .operation(WasmComponentCanonicalKind.futureCancelWrite, 2)
              .futureCancelWriteHandleWhenReady(source.backing(pair.writable)),
          2,
        );
        expect(source.handles.resourceRep(0, owner), 42);
        expect(store.dropped, isEmpty);
        source.handles.resourceDrop(0, owner);
        expect(store.dropped, [42]);
      });
    },
  );

  test(
    'discarding a host-owned future value releases its canonical owner once',
    () async {
      final store = _Store();
      await _scoped(store, () {
        final source = _Instance(store, _ownFuture(), store.type());
        final pair = source.future(2);
        final guest = source.handles.newResource(0, 42);
        final owner = source.handles.liftResourceHandle(0, guest, owned: true);
        source
            .operation(WasmComponentCanonicalKind.futureWrite, 2)
            .futureWriteHandle(source.backing(pair.writable), owner);
        expect(store.dropped, isEmpty);
        source
            .operation(WasmComponentCanonicalKind.futureDropReadable, 2)
            .futureDropReadableHandle(source.backing(pair.readable));
        expect(store.dropped, [42]);
        source
            .operation(WasmComponentCanonicalKind.futureDropWritable, 2)
            .futureDropWritableHandle(source.backing(pair.writable));
        expect(store.dropped, [42]);
      });
    },
  );

  for (final future in [false, true]) {
    test(
      '${future ? 'future' : 'stream'} receiver allocation failure discards the accepted composite owner',
      () async {
        final store = _Store();
        await _scoped(store, () async {
          final component = _types([
            0x3f,
            0x7f,
            0,
            0x69,
            0,
            0x6f,
            2,
            1,
            0x73,
            future ? 0x65 : 0x66,
            1,
            2,
          ], 4);
          final type = store.type();
          final source = _Instance(store, component, type, capacity: 1);
          final target = _Instance(store, component, type);
          final pair = future ? source.future(3) : source.stream(3);
          final guest = source.handles.newResource(0, 42);
          final memory = _memory();
          final data = ByteData.view(memory.buffer)
            ..setUint32(32, guest, Endian.little)
            ..setUint32(36, 256, Endian.little)
            ..setUint32(40, 1, Endian.little)
            ..setUint8(256, 65);
          if (future) {
            expect(
              source
                  .operation(WasmComponentCanonicalKind.futureWrite, 3)
                  .futureWriteHandleFromMemoryEvent(
                    source.backing(pair.writable),
                    memory,
                    32,
                  ),
              wasiComponentAsyncBlocked,
            );
            expect(source.handles.resourceRep(0, guest), 42);
          } else {
            source
                .operation(WasmComponentCanonicalKind.streamWrite, 3)
                .streamWriteHandleFromMemory(
                  source.backing(pair.writable),
                  memory,
                  32,
                  1,
                );
          }
          final endpoint = source.handles.liftReadableEndpoint(
            3,
            pair.readable,
          );
          final reader = target.handles.lowerReadableEndpoint(3, endpoint);
          int failAllocation(
            int oldPointer,
            int oldSize,
            int alignment,
            int newSize,
          ) => throw StateError('allocator failed');
          expect(() {
            if (future) {
              target
                  .operation(WasmComponentCanonicalKind.futureRead, 3)
                  .futureReadHandleToMemory(
                    target.backing(reader),
                    memory,
                    96,
                    failAllocation,
                  );
            } else {
              target
                  .operation(WasmComponentCanonicalKind.streamRead, 3)
                  .streamReadHandleToMemory(
                    target.backing(reader),
                    memory,
                    96,
                    1,
                    failAllocation,
                  );
            }
          }, throwsStateError);
          expect(() => source.handles.resourceRep(0, guest), throwsStateError);
          expect(store.dropped, [42]);
          final stale = data.getUint32(96, Endian.little);
          expect(() => target.handles.resourceRep(0, stale), throwsStateError);
        });
        expect(store.dropped, [42]);
      },
    );
  }

  test(
    'unmatched stream copies guard the whole memory range without reading owners',
    () async {
      final store = _Store();
      await _scoped(store, () {
        final source = _Instance(store, _ownStream(), store.type());
        final pair = source.stream(2);
        final owner = source.handles.newResource(0, 42);
        final memory = _memory();
        final operation = source.operation(
          WasmComponentCanonicalKind.streamWrite,
          2,
        );
        expect(
          () => operation.streamWriteHandleFromMemoryEvent(
            source.backing(pair.writable),
            memory,
            memory.buffer.lengthInBytes - 4,
            2,
          ),
          throwsRangeError,
        );
        expect(
          () => operation.streamWriteHandleFromMemoryEvent(
            source.backing(pair.writable),
            memory,
            1,
            1,
          ),
          throwsStateError,
        );
        expect(source.handles.resourceRep(0, owner), 42);
        expect(store.dropped, isEmpty);
        source.handles.resourceDrop(0, owner);
      });
    },
  );
}

final class _Store {
  final table = WASIComponentResourceTable();
  late final asyncHost = WASIComponentAsyncHost(table: table);
  late final errors = WASIComponentErrorContextHost(table: table);
  final dropped = <int>[];
  WASIComponentResourceType<Object> type({int? throwOnDrop}) =>
      table.defineType<Object>(
        'same debug name',
        onDrop: (value) {
          dropped.add(value as int);
          if (value == throwOnDrop) throw StateError('destructor failed');
        },
      );
}

final class _Instance {
  _Instance(
    this.store,
    WasmComponent component,
    WASIComponentResourceType<Object> type, {
    int capacity = 0,
  }) {
    expect(component.validate(), isEmpty);
    final identity = WASIComponentCanonicalResourceIdentity(type, null);
    handles = WASIComponentCanonicalHandles(
      table: store.table,
      errorContexts: store.errors,
      contextHost: WASIComponentContextHost(),
      resourceIdentity: (_) => identity,
      adapterResourceIdentity: (_, _) => identity,
    );
    final descriptors = store.asyncHost.componentAsyncValueBindings(component);
    bindings = store.asyncHost.createAsyncValueBindingSet<Object?>(
      descriptors,
      maxBufferedElementsForStream: (_) => capacity,
    );
    handles.asyncBindings = bindings;
    for (final binding in descriptors) {
      handles.endpointKinds[binding.componentTypeIndex] =
          binding.kind == WASIComponentAsyncValueBindingKind.stream
          ? WASIComponentCanonicalHandleKind.streamReadable
          : WASIComponentCanonicalHandleKind.futureReadable;
    }
    handles.bindAsyncValues(bindings, descriptors, (_, _) => identity);
  }
  final _Store store;
  late final WASIComponentCanonicalHandles handles;
  late final WASIComponentAsyncValueBindingSet bindings;
  WASIComponentCanonicalAsyncOperation operation(
    WasmComponentCanonicalKind kind,
    int index,
  ) => bindings.bindCanonicalDefinition(
    WasmComponentCanonicalDefinition(kind: kind, typeIndex: index),
  );
  int backing(int guest) => handles.host(guest);
  WASIComponentAsyncEndpointHandles stream(int index) {
    final pair = operation(
      WasmComponentCanonicalKind.streamNew,
      index,
    ).streamNewHandles();
    return WASIComponentAsyncEndpointHandles(
      readable: handles.add(
        pair.readable,
        WASIComponentCanonicalHandleKind.streamReadable,
      ),
      writable: handles.add(
        pair.writable,
        WASIComponentCanonicalHandleKind.streamWritable,
      ),
    );
  }

  WASIComponentAsyncEndpointHandles future(int index) {
    final pair = operation(
      WasmComponentCanonicalKind.futureNew,
      index,
    ).futureNewHandles();
    return WASIComponentAsyncEndpointHandles(
      readable: handles.add(
        pair.readable,
        WASIComponentCanonicalHandleKind.futureReadable,
      ),
      writable: handles.add(
        pair.writable,
        WASIComponentCanonicalHandleKind.futureWritable,
      ),
    );
  }
}

Future<void> _scoped(_Store store, FutureOr<void> Function() action) async {
  await store.table.runScoped(() async {
    await action();
    await Future<void>.delayed(Duration.zero);
  });
  expect(store.table.activeCount, 0);
}

Memory _memory() => Memory(const MemoryDescriptor(initial: 1));
WasmComponent _ownStream() =>
    WasmComponent.decode(fixtures.streamOwnResourceTypeComponentBytes());
WasmComponent _ownFuture() =>
    WasmComponent.decode(fixtures.futureOwnResourceTypeComponentBytes());
WasmComponent _types(List<int> definitions, int count) => WasmComponent.decode(
  Uint8List.fromList([
    0,
    97,
    115,
    109,
    13,
    0,
    1,
    0,
    7,
    ..._u32(definitions.length + _u32(count).length),
    ..._u32(count),
    ...definitions,
  ]),
);

List<int> _u32(int value) {
  final bytes = <int>[];
  do {
    final next = value & 0x7f;
    value >>= 7;
    bytes.add(next | (value == 0 ? 0 : 0x80));
  } while (value != 0);
  return bytes;
}
