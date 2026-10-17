import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/canonical_handles.dart';
import 'package:wasd/src/wasi/component/context.dart';
import 'package:wasd/src/wasi/component/error_context.dart';
import 'package:wasd/src/wasi/component/resource_table.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

import 'support/component_fixtures.dart' as fixtures;

void main() {
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
    definitions.length + 1,
    count,
    ...definitions,
  ]),
);
