import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';

void main() {
  group('WASIComponentStream', () {
    test('moves values through readable and writable endpoints', () {
      final dropped = <String>[];
      final stream = WASIComponentStream<int>(
        'numbers',
        onDrop: () => dropped.add('numbers'),
      );

      stream.writable.writeAll(<int>[1, 2, 3]);

      expect(stream.queuedLength, 3);
      expect(stream.readable.read(2), <int>[1, 2]);
      expect(stream.readable.read(4), <int>[3]);
      expect(stream.readable.read(1), isEmpty);

      stream.writable.close();

      expect(stream.writable.isClosed, isTrue);
      expect(() => stream.writable.write(4), throwsStateError);
      expect(stream.readable.read(1), isEmpty);

      stream.readable.drop();
      expect(dropped, <String>['numbers']);
      stream.writable.drop();

      expect(stream.isDropped, isTrue);
      expect(dropped, <String>['numbers']);
      expect(() => stream.readable.read(1), throwsStateError);
    });

    test('host stream termination consumes both endpoints exactly once', () {
      var dropCount = 0;
      final stream = WASIComponentStream<int>(
        'terminated-stream',
        onDrop: () => dropCount++,
      );

      stream.readable.cancel();
      expect(stream.readable.isDropped, isTrue);
      expect(dropCount, 0);

      stream.writable.close();
      expect(stream.writable.isDropped, isTrue);
      expect(dropCount, 1);

      stream.readable.drop();
      stream.writable.drop();
      expect(dropCount, 1);
    });

    test('cancels streams without retaining queued values', () {
      final stream = WASIComponentStream<String>('events');

      stream.writable.writeAll(<String>['open', 'close']);
      stream.readable.cancel();

      expect(stream.readable.isCancelled, isTrue);
      expect(stream.queuedLength, 0);
      expect(() => stream.writable.write('late'), throwsStateError);
      expect(() => stream.readable.read(1), throwsStateError);
    });

    test('reports writable closed after the readable endpoint drops', () {
      final stream = WASIComponentStream<int>('events');

      stream.readable.drop();

      expect(stream.writable.isClosed, isTrue);
      expect(() => stream.writable.write(1), throwsStateError);
    });

    test(
      'completes pending readable stream waits when values arrive',
      () async {
        final stream = WASIComponentStream<int>('numbers');
        var completed = false;

        final pending = stream.readable.readWhenAvailable(2)
          ..then((_) {
            completed = true;
          });
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);

        stream.writable.writeAll(<int>[1, 2, 3]);

        await expectLater(pending, completion(<int>[1, 2]));
        expect(completed, isTrue);
        expect(stream.readable.read(2), <int>[3]);
      },
    );

    test('completes pending readable stream waits on close', () async {
      final stream = WASIComponentStream<int>('numbers');
      final pending = stream.readable.readWhenAvailable(2);

      stream.writable.close();

      await expectLater(pending, completion(isEmpty));
      expect(stream.writable.isClosed, isTrue);
    });

    test('fails pending readable stream waits on cancel or drop', () async {
      final cancelled = WASIComponentStream<String>('cancelled');
      final cancelledRead = cancelled.readable.readWhenAvailable(1);

      cancelled.readable.cancel();

      await expectLater(cancelledRead, throwsStateError);

      final dropped = WASIComponentStream<String>('dropped');
      final droppedRead = dropped.readable.readWhenAvailable(1);

      dropped.readable.drop();

      await expectLater(droppedRead, throwsStateError);
    });

    test('reports writer cancellation to pending and later readers', () async {
      final stream = WASIComponentStream<int>('cancelled-writer');
      final pending = stream.readable.readWhenAvailable(1);

      stream.writable.cancel();

      await expectLater(
        pending,
        throwsA(
          isA<WASIComponentAsyncEndpointStateError>().having(
            (error) => error.failure,
            'failure',
            WASIComponentAsyncEndpointFailure.cancelled,
          ),
        ),
      );
      await expectLater(
        stream.readable.readWhenAvailable(1),
        throwsA(
          isA<WASIComponentAsyncEndpointStateError>().having(
            (error) => error.failure,
            'failure',
            WASIComponentAsyncEndpointFailure.cancelled,
          ),
        ),
      );
    });

    test(
      'completes pending bounded stream writes when capacity opens',
      () async {
        final stream = WASIComponentStream<int>(
          'numbers',
          maxBufferedElements: 2,
        );
        stream.writable.writeAll(<int>[1, 2]);
        var completed = false;

        final pending = stream.writable.writeWhenAvailable(<int>[3, 4])
          ..then((_) {
            completed = true;
          });
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);
        expect(stream.queuedLength, 2);
        expect(stream.readable.read(1), <int>[1]);

        await expectLater(pending, completion(1));
        expect(completed, isTrue);
        expect(stream.readable.read(4), <int>[2, 3]);
      },
    );

    test(
      'rendezvous streams copy directly between pending endpoints',
      () async {
        final stream = WASIComponentStream<int>(
          'numbers',
          maxBufferedElements: 0,
        );
        var completed = false;

        final pendingWrite = stream.writable.writeWhenAvailable(<int>[1, 2, 3])
          ..then((_) {
            completed = true;
          });
        await Future<void>.delayed(Duration.zero);

        expect(completed, isFalse);
        expect(stream.queuedLength, 0);

        await expectLater(
          stream.readable.readWhenAvailable(2),
          completion(<int>[1, 2]),
        );
        await expectLater(pendingWrite, completion(2));
        expect(completed, isTrue);
        expect(stream.queuedLength, 0);
      },
    );

    test(
      'forwards queued stream values without retaining source values',
      () async {
        final source = WASIComponentStream<int>(
          'source',
          maxBufferedElements: 3,
        );
        final target = WASIComponentStream<int>('target');
        source.writable.writeAll(<int>[1, 2, 3]);
        final pendingSourceWrite = source.writable.writeWhenAvailable(<int>[4]);

        expect(await source.readable.forwardTo(target.writable, 3), 3);

        await expectLater(pendingSourceWrite, completion(1));
        expect(source.queuedLength, 1);
        expect(target.queuedLength, 3);
        expect(target.readable.read(4), <int>[1, 2, 3]);
        expect(source.readable.read(1), <int>[4]);
      },
    );

    test('awaits bounded stream forwarding destination capacity', () async {
      final source = WASIComponentStream<int>('source');
      final target = WASIComponentStream<int>('target', maxBufferedElements: 1);
      source.writable.writeAll(<int>[1, 2]);
      target.writable.write(0);
      var completed = false;

      final pending = source.readable.forwardTo(target.writable, 2)
        ..then((_) {
          completed = true;
        });
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);
      expect(source.queuedLength, 2);
      expect(target.readable.read(1), <int>[0]);
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);
      expect(source.queuedLength, 1);
      expect(target.readable.read(1), <int>[1]);
      await expectLater(pending, completion(2));
      expect(completed, isTrue);
      expect(target.readable.read(1), <int>[2]);
      expect(source.queuedLength, 0);
    });

    test('does not bypass pending bounded writes while forwarding', () async {
      final source = WASIComponentStream<int>('source');
      final target = WASIComponentStream<int>('target', maxBufferedElements: 1);
      target.writable.write(0);
      final pendingWrite = target.writable.writeWhenAvailable(<int>[1]);
      source.writable.write(2);
      var completed = false;

      final pendingForward = source.readable.forwardTo(target.writable, 1)
        ..then((_) {
          completed = true;
        });
      await Future<void>.delayed(Duration.zero);

      expect(source.queuedLength, 1);
      expect(completed, isFalse);
      expect(target.readable.read(1), <int>[0]);
      await expectLater(pendingWrite, completion(1));
      await Future<void>.delayed(Duration.zero);

      expect(source.queuedLength, 1);
      expect(completed, isFalse);
      expect(target.readable.read(1), <int>[1]);
      await expectLater(pendingForward, completion(1));
      expect(completed, isTrue);
      expect(target.readable.read(1), <int>[2]);
    });

    test('stops stream forwarding when the source closes', () async {
      final source = WASIComponentStream<int>('source');
      final target = WASIComponentStream<int>('target');
      source.writable.write(7);
      source.writable.close();

      expect(await source.readable.forwardTo(target.writable, 3), 1);
      expect(await source.readable.forwardTo(target.writable, 3), 0);
      expect(target.readable.read(3), <int>[7]);
    });

    test('rejects invalid stream forwarding operations', () async {
      final source = WASIComponentStream<int>('source');
      final target = WASIComponentStream<int>('target');

      await expectLater(
        source.readable.forwardTo(source.writable, 1),
        throwsStateError,
      );
      await expectLater(
        source.readable.forwardTo(target.writable, -1),
        throwsRangeError,
      );
      await expectLater(
        source.readable.forwardTo(target.writable, 1, chunkSize: 0),
        throwsRangeError,
      );
    });

    test(
      'fails pending stream forwarding when the destination drops',
      () async {
        final source = WASIComponentStream<int>('source');
        final target = WASIComponentStream<int>(
          'target',
          maxBufferedElements: 1,
        );
        source.writable.write(1);
        target.writable.write(0);

        final pending = source.readable.forwardTo(target.writable, 1);
        await Future<void>.delayed(Duration.zero);

        target.writable.drop();

        await expectLater(pending, throwsStateError);
      },
    );

    test('fails pending bounded stream writes on cancel or drop', () async {
      final cancelled = WASIComponentStream<String>(
        'cancelled',
        maxBufferedElements: 1,
      );
      cancelled.writable.write('open');
      final cancelledWrite = cancelled.writable.writeWhenAvailable(<String>[
        'late',
      ]);

      cancelled.writable.cancel();

      await expectLater(cancelledWrite, throwsStateError);

      final dropped = WASIComponentStream<String>(
        'dropped',
        maxBufferedElements: 1,
      );
      dropped.writable.write('open');
      final droppedWrite = dropped.writable.writeWhenAvailable(<String>[
        'late',
      ]);

      dropped.writable.drop();

      await expectLater(droppedWrite, throwsStateError);
    });

    test('rejects synchronous bounded writes without partial enqueue', () {
      final stream = WASIComponentStream<int>(
        'numbers',
        maxBufferedElements: 2,
      );

      expect(() => stream.writable.writeAll(<int>[1, 2, 3]), throwsStateError);
      expect(stream.queuedLength, 0);

      stream.writable.writeAll(<int>[1, 2]);

      expect(() => stream.writable.write(3), throwsStateError);
      expect(stream.readable.read(4), <int>[1, 2]);
    });

    test('moves unit events through nullable stream endpoints', () {
      final stream = WASIComponentStream<Object?>('ticks');

      stream.writable.write(null);
      stream.writable.writeAll(<Object?>[null, null]);

      expect(stream.queuedLength, 3);
      expect(stream.readable.read(2), <Object?>[null, null]);
      expect(stream.readable.read(2), <Object?>[null]);
    });

    test('discards only values accepted by an unread stream', () async {
      final discarded = <int>[];
      final buffered = WASIComponentStream<int>(
        'buffered-owned-values',
        onDiscard: discarded.add,
      );
      buffered.writable.writeAll(<int>[1, 2, 3]);

      expect(buffered.readable.read(1), <int>[1]);
      buffered.readable.drop();
      expect(discarded, <int>[2, 3]);

      final rendezvous = WASIComponentStream<int>(
        'pending-owned-values',
        maxBufferedElements: 0,
        onDiscard: discarded.add,
      );
      final pending = rendezvous.writable.writeWhenAvailable(<int>[4]);
      rendezvous.readable.drop();

      await expectLater(
        pending,
        throwsA(isA<WASIComponentAsyncEndpointStateError>()),
      );
      expect(discarded, <int>[2, 3]);
    });
  });

  group('WASIComponentFuture', () {
    test('host completion consumes the producer endpoint exactly once', () {
      final dropped = <String>[];
      final future = WASIComponentFuture<int>(
        'answer',
        onDrop: () => dropped.add('answer'),
      );

      expect(future.readable.isReady, isFalse);
      expect(() => future.readable.read(), throwsStateError);

      future.writable.complete(42);

      expect(future.readable.isReady, isTrue);
      expect(future.writable.isDropped, isTrue);
      expect(future.readable.read(), 42);
      expect(() => future.readable.read(), throwsStateError);
      expect(() => future.writable.complete(43), throwsStateError);

      future.readable.drop();
      expect(dropped, <String>['answer']);
      future.writable.drop();

      expect(future.isDropped, isTrue);
      expect(dropped, <String>['answer']);
    });

    test(
      'host completion waiting for delivery releases its producer',
      () async {
        var dropCount = 0;
        final future = WASIComponentFuture<int>(
          'delivered-answer',
          onDrop: () => dropCount++,
        );

        final delivered = future.writable.completeWhenRead(42);

        expect(future.writable.isDropped, isTrue);
        expect(future.isDropped, isFalse);
        expect(await future.readable.readWhenReady(), 42);
        await expectLater(delivered, completes);

        future.readable.drop();
        future.writable.drop();
        expect(future.isDropped, isTrue);
        expect(dropCount, 1);
      },
    );

    test('completes pending readable future waits', () async {
      final future = WASIComponentFuture<int>('answer');
      var completed = false;

      final pending = future.readable.readWhenReady()
        ..then((_) {
          completed = true;
        });
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);

      future.writable.complete(42);

      await expectLater(pending, completion(42));
      expect(completed, isTrue);
      expect(() => future.readable.read(), throwsStateError);
    });

    test('cancels pending futures', () {
      final future = WASIComponentFuture<String>('message');

      future.readable.cancel();

      expect(future.isCancelled, isTrue);
      expect(future.readable.isCancelled, isTrue);
      expect(() => future.writable.complete('late'), throwsStateError);
      expect(() => future.readable.read(), throwsStateError);
    });

    test('host future cancellation consumes both endpoints exactly once', () {
      var dropCount = 0;
      final future = WASIComponentFuture<String>(
        'cancelled-host-future',
        onDrop: () => dropCount++,
      );

      future.readable.cancel();
      expect(future.readable.isDropped, isTrue);
      expect(dropCount, 0);

      future.writable.cancel();
      expect(future.writable.isDropped, isTrue);
      expect(dropCount, 1);

      future.readable.drop();
      future.writable.drop();
      expect(dropCount, 1);
    });

    test('discards rejected and raced host values exactly once', () async {
      final discarded = <String>[];
      var rejectedDrops = 0;
      final rejected = WASIComponentFuture<String>(
        'rejected-host-value',
        onDrop: () => rejectedDrops++,
        onDiscard: discarded.add,
      );

      rejected.readable.drop();
      expect(
        () => rejected.writable.complete('rejected'),
        throwsA(isA<WASIComponentAsyncEndpointStateError>()),
      );
      expect(discarded, <String>['rejected']);
      expect(rejected.isDropped, isTrue);
      expect(rejectedDrops, 1);

      var racedDrops = 0;
      final raced = WASIComponentFuture<String>(
        'raced-host-value',
        onDrop: () => racedDrops++,
        onDiscard: discarded.add,
      );
      final delivery = raced.writable.completeWhenRead('raced');

      raced.readable.drop();

      await expectLater(
        delivery,
        throwsA(
          isA<WASIComponentAsyncEndpointStateError>().having(
            (error) => error.failure,
            'failure',
            WASIComponentAsyncEndpointFailure.dropped,
          ),
        ),
      );
      expect(discarded, <String>['rejected', 'raced']);
      expect(raced.isDropped, isTrue);
      expect(racedDrops, 1);
    });

    test('fails pending readable future waits on cancel or drop', () async {
      final cancelled = WASIComponentFuture<String>('cancelled');
      final cancelledRead = cancelled.readable.readWhenReady();

      cancelled.readable.cancel();

      await expectLater(cancelledRead, throwsStateError);

      final dropped = WASIComponentFuture<String>('dropped');
      expect(() => dropped.writable.drop(), throwsStateError);
      dropped.readable.drop();
      expect(
        () => dropped.writable.complete('returned'),
        throwsA(isA<WASIComponentAsyncEndpointStateError>()),
      );
      dropped.writable.drop();
    });

    test('completes unit futures with null', () async {
      final future = WASIComponentFuture<Object?>('ready');
      final pending = future.readable.readWhenReady();

      future.writable.complete(null);

      await expectLater(pending, completion(isNull));
      expect(() => future.readable.read(), throwsStateError);
    });

    test('allows only one pending read copy', () async {
      final future = WASIComponentFuture<int>('single-reader');
      final pending = future.readable.readWhenReady();

      expect(() => future.readable.readWhenReady(), throwsStateError);
      future.writable.complete(42);

      await expectLater(pending, completion(42));
      expect(() => future.readable.readWhenReady(), throwsStateError);
    });

    test(
      'discards accepted unread values without taking cancelled writes',
      () async {
        final discarded = <String>[];
        final unread = WASIComponentFuture<String>(
          'unread-owned-value',
          onDiscard: discarded.add,
        );
        unread.writable.complete('accepted');

        unread.readable.drop();
        unread.writable.drop();
        expect(discarded, <String>['accepted']);

        final cancelled = WASIComponentFuture<String>(
          'cancelled-owned-value',
          onDiscard: discarded.add,
        );
        final pendingWrite = cancelled.writable.completeWhenReadForCopy(
          'returned',
        );
        cancelled.writable.cancelPendingCopy();

        await expectLater(
          pendingWrite,
          throwsA(isA<WASIComponentAsyncEndpointStateError>()),
        );
        expect(discarded, <String>['accepted']);

        final pendingRead = cancelled.readable.readWhenReady();
        final delivered = cancelled.writable.completeWhenReadForCopy(
          'delivered',
        );
        await expectLater(pendingRead, completion('delivered'));
        await expectLater(delivered, completes);
        cancelled.readable.drop();
        cancelled.writable.drop();
        expect(discarded, <String>['accepted']);
      },
    );
  });
}
