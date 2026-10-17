import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';

void main() {
  group('canonical same-owner copies', () {
    test(
      'reader-first stream traps before loading a same-owner source',
      () async {
        final owner = Object();
        final stream = WASIComponentStream<int>(
          'same reader first',
          maxBufferedElements: 0,
        );
        var loads = 0;
        final reader = stream.readable.readIntoWhenAvailableForCopy(
          WASIComponentAsyncCopyTarget<int>(
            length: 1,
            owner: owner,
            writePrefix: (_) => fail('must not store'),
          ),
        );
        final failedReader = expectLater(reader, throwsStateError);
        expect(
          () => stream.writable.writeSourceForCopy(
            WASIComponentAsyncCopySource<int>(
              length: 1,
              owner: owner,
              checkSameOwner: true,
              readPrefix: (_) {
                loads++;
                return [7];
              },
            ),
          ),
          throwsStateError,
        );
        await failedReader;
        expect(loads, 0);
      },
    );

    test(
      'writer-first stream traps before loading a synchronous target',
      () async {
        final owner = Object();
        final stream = WASIComponentStream<int>(
          'same writer first sync',
          maxBufferedElements: 0,
        );
        var loads = 0;
        final writer = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            owner: owner,
            checkSameOwner: true,
            readPrefix: (_) {
              loads++;
              return [7];
            },
          ),
        );
        final failedWriter = expectLater(writer, throwsStateError);
        expect(
          () => stream.readable.readIntoForCopy(
            WASIComponentAsyncCopyTarget<int>(
              length: 1,
              owner: owner,
              writePrefix: (_) => fail('must not store'),
            ),
          ),
          throwsStateError,
        );
        await failedWriter;
        expect(loads, 0);
      },
    );

    test(
      'writer-first stream traps before loading an asynchronous target',
      () async {
        final owner = Object();
        final stream = WASIComponentStream<int>(
          'same writer first async',
          maxBufferedElements: 0,
        );
        var loads = 0;
        final writer = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            owner: owner,
            checkSameOwner: true,
            readPrefix: (_) {
              loads++;
              return [7];
            },
          ),
        );
        final failedWriter = expectLater(writer, throwsStateError);
        await expectLater(
          stream.readable.readIntoWhenAvailableForCopy(
            WASIComponentAsyncCopyTarget<int>(
              length: 1,
              owner: owner,
              writePrefix: (_) => fail('must not store'),
            ),
          ),
          throwsStateError,
        );
        await failedWriter;
        expect(loads, 0);
      },
    );

    test(
      'reader-first future traps before loading a same-owner source',
      () async {
        final owner = Object();
        final future = WASIComponentFuture<int>('same future reader first');
        var loads = 0;
        final reader = future.readable.readWhenReadyForCanonicalCopy(
          owner: owner,
        );
        final failedReader = expectLater(reader, throwsStateError);
        expect(
          () => future.writable.completeSourceForCopy(
            WASIComponentAsyncCopySource<int>(
              length: 1,
              owner: owner,
              checkSameOwner: true,
              readPrefix: (_) {
                loads++;
                return [7];
              },
            ),
          ),
          throwsStateError,
        );
        await failedReader;
        expect(loads, 0);
      },
    );

    test(
      'writer-first future traps before loading a same-owner source',
      () async {
        final owner = Object();
        final future = WASIComponentFuture<int>('same future writer first');
        var loads = 0;
        final writer = future.writable.completeSourceWhenReadForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            owner: owner,
            checkSameOwner: true,
            readPrefix: (_) {
              loads++;
              return [7];
            },
          ),
        );
        final failedWriter = expectLater(writer, throwsStateError);
        expect(
          () => future.readable.readForCanonicalCopy(owner: owner),
          throwsStateError,
        );
        await failedWriter;
        expect(loads, 0);
      },
    );

    test(
      'numeric copies, distinct owners and host buffers remain allowed',
      () async {
        final owner = Object();
        for (final (sourceOwner, targetOwner, check) in [
          (owner, owner, false),
          (owner, Object(), true),
          (null, owner, true),
          (owner, null, true),
        ]) {
          final stream = WASIComponentStream<int>(
            'allowed stream',
            maxBufferedElements: 0,
          );
          final values = <int>[];
          final reader = stream.readable.readIntoWhenAvailableForCopy(
            WASIComponentAsyncCopyTarget<int>(
              length: 1,
              owner: targetOwner,
              writePrefix: values.addAll,
            ),
          );
          expect(
            stream.writable.writeSourceForCopy(
              WASIComponentAsyncCopySource<int>(
                length: 1,
                owner: sourceOwner,
                checkSameOwner: check,
                readPrefix: (_) => [7],
              ),
            ),
            1,
          );
          expect(await reader, 1);
          expect(values, [7]);
        }
      },
    );

    test('numeric and host future copies remain allowed', () async {
      final owner = Object();
      for (final (sourceOwner, targetOwner, check) in [
        (owner, owner, false),
        (owner, Object(), true),
        (null, owner, true),
        (owner, null, true),
      ]) {
        final future = WASIComponentFuture<int>('allowed future');
        final reader = future.readable.readWhenReadyForCanonicalCopy(
          owner: targetOwner,
        );
        future.writable.completeSourceForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            owner: sourceOwner,
            checkSameOwner: check,
            readPrefix: (_) => [7],
          ),
        );
        expect(await reader, 7);
      }
    });

    test(
      'a retained source checks the owner before every later prefix',
      () async {
        final owner = Object();
        final stream = WASIComponentStream<int>(
          'retained checked source',
          maxBufferedElements: 0,
        );
        var loads = 0;
        final writer = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 2,
            owner: owner,
            checkSameOwner: true,
            readPrefix: (_) => [++loads],
          ),
          deferCompletion: true,
        );
        final copied = <int>[];
        expect(
          stream.readable.readIntoForCopy(
            WASIComponentAsyncCopyTarget<int>(
              length: 1,
              owner: Object(),
              writePrefix: copied.addAll,
            ),
          ),
          1,
        );
        expect(await writer, 1);
        expect(
          () => stream.readable.readIntoForCopy(
            WASIComponentAsyncCopyTarget<int>(
              length: 1,
              owner: owner,
              writePrefix: copied.addAll,
            ),
          ),
          throwsStateError,
        );
        expect(copied, [1]);
        expect(loads, 1);
        stream.writable.finishDeferredCopy(dropped: false);
      },
    );

    test('a retained target checks each new source before it loads', () async {
      final owner = Object();
      final stream = WASIComponentStream<int>(
        'retained checked target',
        maxBufferedElements: 0,
      );
      final copied = <int>[];
      final reader = stream.readable.readIntoWhenAvailableForCopy(
        WASIComponentAsyncCopyTarget<int>(
          length: 2,
          owner: owner,
          writePrefix: copied.addAll,
        ),
        deferCompletion: true,
      );
      stream.writable.writeSourceForCopy(
        WASIComponentAsyncCopySource<int>(
          length: 1,
          owner: Object(),
          checkSameOwner: true,
          readPrefix: (_) => [7],
        ),
      );
      expect(await reader, 1);
      var loads = 0;
      expect(
        () => stream.writable.writeSourceForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            owner: owner,
            checkSameOwner: true,
            readPrefix: (_) {
              loads++;
              return [8];
            },
          ),
        ),
        throwsStateError,
      );
      expect(loads, 0);
      expect(copied, [7]);
      stream.readable.finishDeferredCopy(dropped: false);
    });

    test('bounded direct copies also reject before source loading', () async {
      final owner = Object();
      final stream = WASIComponentStream<int>(
        'bounded checked source',
        maxBufferedElements: 1,
      );
      var loads = 0;
      final reader = stream.readable.readIntoWhenAvailableForCopy(
        WASIComponentAsyncCopyTarget<int>(
          length: 1,
          owner: owner,
          writePrefix: (_) => fail('must not store'),
        ),
      );
      final failedReader = expectLater(reader, throwsStateError);
      expect(
        () => stream.writable.writeSourceForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            owner: owner,
            checkSameOwner: true,
            readPrefix: (_) {
              loads++;
              return [7];
            },
          ),
        ),
        throwsStateError,
      );
      await failedReader;
      expect(loads, 0);
    });

    test(
      'writer-first future checks an asynchronous canonical reader',
      () async {
        final owner = Object();
        final future = WASIComponentFuture<int>('same async future reader');
        var loads = 0;
        final writer = future.writable.completeSourceWhenReadForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            owner: owner,
            checkSameOwner: true,
            readPrefix: (_) {
              loads++;
              return [7];
            },
          ),
        );
        final failedWriter = expectLater(writer, throwsStateError);
        await expectLater(
          Future<int>.sync(
            () => future.readable.readWhenReadyForCanonicalCopy(owner: owner),
          ),
          throwsStateError,
        );
        await failedWriter;
        expect(loads, 0);
      },
    );

    test(
      'cancelled future reader releases its buffer owner before a host retry',
      () async {
        final owner = Object();
        final future = WASIComponentFuture<int>('cancelled checked future');
        final reader = future.readable.readWhenReadyForCanonicalCopy(
          owner: owner,
        );
        final cancelled = expectLater(reader, throwsStateError);
        future.readable.requestCopyCancellation();
        future.readable.cancelRequestedCopy();
        await cancelled;
        final writer = future.writable.completeSourceWhenReadForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            owner: owner,
            checkSameOwner: true,
            readPrefix: (_) => [7],
          ),
        );
        expect(future.readable.readForCopy(), 7);
        await writer;
      },
    );

    test('legacy host reads accept a checked guest source', () async {
      final owner = Object();
      final stream = WASIComponentStream<int>(
        'host reader',
        maxBufferedElements: 0,
      );
      final writer = stream.writable.writeSourceWhenAvailableForCopy(
        WASIComponentAsyncCopySource<int>(
          length: 1,
          owner: owner,
          checkSameOwner: true,
          readPrefix: (_) => [7],
        ),
      );
      expect(stream.readable.readForCopy(1), [7]);
      expect(await writer, 1);
      final future = WASIComponentFuture<int>('host future reader');
      final completed = future.writable.completeSourceWhenReadForCopy(
        WASIComponentAsyncCopySource<int>(
          length: 1,
          owner: owner,
          checkSameOwner: true,
          readPrefix: (_) => [8],
        ),
      );
      expect(future.readable.readForCopy(), 8);
      await completed;
    });
  });

  group('pending stream copy cursors', () {
    test(
      'blocked writer keeps its suffix until the completion event is delivered',
      () async {
        final stream = WASIComponentStream<int>(
          'pending writer',
          maxBufferedElements: 0,
        );
        final values = [7, 8];
        var offset = 0;
        final loaded = <int>[];
        final pending = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: values.length,
            readPrefix: (count) {
              loaded.add(count);
              final prefix = values.sublist(offset, offset + count);
              offset += count;
              return prefix;
            },
          ),
          deferCompletion: true,
        );
        expect(stream.readable.readForCopy(1), [7]);
        expect(await pending, 1);
        expect(stream.readable.readForCopy(1), [8]);
        expect(loaded, [1, 1]);
        expect(stream.writable.copyProgress, 2);
        stream.writable.finishDeferredCopy(dropped: false);
        expect(stream.readable.readForCopy(1), isEmpty);
      },
    );

    test(
      'blocked bounded writer retains its cursor across freed capacity',
      () async {
        final stream = WASIComponentStream<int>(
          'bounded pending writer',
          maxBufferedElements: 1,
        );
        stream.writable.write(3);
        var offset = 0;
        final pending = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 2,
            readPrefix: (count) {
              final prefix = [7, 8].sublist(offset, offset + count);
              offset += count;
              return prefix;
            },
          ),
          deferCompletion: true,
        );
        expect(stream.readable.read(1), [3]);
        expect(await pending, 1);
        expect(stream.readable.read(1), [7]);
        expect(stream.readable.read(1), [8]);
        expect(offset, 2);
        stream.writable.finishDeferredCopy(dropped: false);
      },
    );

    test('event delivery releases an unaccepted writer suffix', () async {
      final stream = WASIComponentStream<int>(
        'delivered writer',
        maxBufferedElements: 0,
      );
      var loaded = 0;
      final pending = stream.writable.writeSourceWhenAvailableForCopy(
        WASIComponentAsyncCopySource<int>(
          length: 2,
          readPrefix: (count) {
            loaded += count;
            return [7];
          },
        ),
        deferCompletion: true,
      );
      expect(stream.readable.readForCopy(1), [7]);
      expect(await pending, 1);
      stream.writable.finishDeferredCopy(dropped: false);
      expect(stream.readable.readForCopy(1), isEmpty);
      expect(loaded, 1);
    });

    test('cancellation releases an unaccepted writer suffix', () async {
      final stream = WASIComponentStream<int>(
        'cancelled writer',
        maxBufferedElements: 0,
      );
      var loaded = 0;
      final pending = stream.writable.writeSourceWhenAvailableForCopy(
        WASIComponentAsyncCopySource<int>(
          length: 2,
          readPrefix: (count) {
            loaded += count;
            return [7];
          },
        ),
        deferCompletion: true,
      );
      expect(stream.readable.readForCopy(1), [7]);
      expect(await pending, 1);
      expect(stream.writable.copyProgress, 1);
      stream.writable.requestCopyCancellation();
      stream.writable.cancelRequestedCopy();
      expect(stream.writable.copyProgress, 1);
      expect(stream.readable.readForCopy(1), isEmpty);
      expect(loaded, 1);
      stream.writable.finishDeferredCopy(dropped: false);
    });

    test(
      'a failure in a retained source stops the cursor without reloading',
      () async {
        final stream = WASIComponentStream<int>(
          'failed suffix',
          maxBufferedElements: 0,
        );
        final failure = StateError('suffix failed');
        var loaded = 0;
        final pending = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 2,
            readPrefix: (count) {
              if (loaded++ != 0) throw failure;
              return [7];
            },
          ),
          deferCompletion: true,
        );
        expect(stream.readable.readForCopy(1), [7]);
        expect(await pending, 1);
        expect(() => stream.readable.readForCopy(1), throwsA(same(failure)));
        stream.writable.finishDeferredCopy(dropped: false);
        expect(stream.readable.readForCopy(1), isEmpty);
        expect(loaded, 2);
      },
    );
  });

  group('retained stream targets', () {
    test('blocked target accepts two writes before event delivery', () async {
      final stream = WASIComponentStream<int>(
        'pending target',
        maxBufferedElements: 0,
      );
      final copied = <int>[];
      final pending = stream.readable.readIntoWhenAvailableForCopy(
        WASIComponentAsyncCopyTarget<int>(
          length: 2,
          writePrefix: copied.addAll,
        ),
        deferCompletion: true,
      );
      expect(stream.writable.canWriteImmediately(2), isFalse);
      expect(stream.writable.canWriteSourceImmediately(2), isTrue);
      expect(
        stream.writable.writeSourceForCopy(
          WASIComponentAsyncCopySource<int>(length: 1, readPrefix: (_) => [7]),
        ),
        1,
      );
      expect(await pending, 1);
      expect(stream.readable.copyProgress, 1);
      expect(
        stream.writable.writeSourceForCopy(
          WASIComponentAsyncCopySource<int>(length: 1, readPrefix: (_) => [8]),
        ),
        1,
      );
      expect(copied, [7, 8]);
      expect(stream.readable.copyProgress, 2);
      stream.readable.finishDeferredCopy(dropped: false);
      expect(stream.writable.canWriteSourceImmediately(1), isFalse);
    });

    test('blocked target also accepts successive queued prefixes', () async {
      final stream = WASIComponentStream<int>(
        'bounded target',
        maxBufferedElements: 1,
      );
      final copied = <int>[];
      final pending = stream.readable.readIntoWhenAvailableForCopy(
        WASIComponentAsyncCopyTarget<int>(
          length: 2,
          writePrefix: copied.addAll,
        ),
        deferCompletion: true,
      );
      stream.writable.write(7);
      expect(await pending, 1);
      stream.writable.write(8);
      expect(copied, [7, 8]);
      expect(stream.readable.copyProgress, 2);
      stream.readable.finishDeferredCopy(dropped: false);
    });

    test(
      'event delivery clears a target before it accepts its suffix',
      () async {
        final stream = WASIComponentStream<int>(
          'delivered target',
          maxBufferedElements: 0,
        );
        final copied = <int>[];
        final pending = stream.readable.readIntoWhenAvailableForCopy(
          WASIComponentAsyncCopyTarget<int>(
            length: 2,
            writePrefix: copied.addAll,
          ),
          deferCompletion: true,
        );
        stream.writable.writeSourceForCopy(
          WASIComponentAsyncCopySource<int>(length: 1, readPrefix: (_) => [7]),
        );
        expect(await pending, 1);
        stream.readable.finishDeferredCopy(dropped: false);
        expect(stream.writable.canWriteSourceImmediately(1), isFalse);
        var loaded = 0;
        expect(
          () => stream.writable.writeSourceForCopy(
            WASIComponentAsyncCopySource<int>(
              length: 1,
              readPrefix: (_) {
                loaded++;
                return [8];
              },
            ),
          ),
          throwsStateError,
        );
        expect(loaded, 0);
        expect(copied, [7]);
      },
    );

    test(
      'cancellation keeps target progress and releases the remaining buffer',
      () async {
        for (final count in [1, 2]) {
          final stream = WASIComponentStream<int>(
            'cancel target',
            maxBufferedElements: 0,
          );
          final copied = <int>[];
          final pending = stream.readable.readIntoWhenAvailableForCopy(
            WASIComponentAsyncCopyTarget<int>(
              length: 3,
              writePrefix: copied.addAll,
            ),
            deferCompletion: true,
          );
          stream.writable.writeSourceForCopy(
            WASIComponentAsyncCopySource<int>(
              length: 1,
              readPrefix: (_) => [7],
            ),
          );
          expect(await pending, 1);
          if (count == 2) {
            stream.writable.writeSourceForCopy(
              WASIComponentAsyncCopySource<int>(
                length: 1,
                readPrefix: (_) => [8],
              ),
            );
          }
          stream.readable.requestCopyCancellation();
          stream.readable.cancelRequestedCopy();
          expect(stream.readable.copyProgress, count);
          expect(stream.writable.canWriteSourceImmediately(1), isFalse);
          stream.readable.finishDeferredCopy(dropped: false);
          expect(copied.length, count);
        }
      },
    );

    test(
      'an immediately matched target does not retain its own suffix',
      () async {
        final stream = WASIComponentStream<int>(
          'immediate target',
          maxBufferedElements: 0,
        );
        final writer = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(length: 1, readPrefix: (_) => [7]),
        );
        final copied = <int>[];
        final count = await stream.readable.readIntoWhenAvailableForCopy(
          WASIComponentAsyncCopyTarget<int>(
            length: 2,
            writePrefix: copied.addAll,
          ),
          deferCompletion: true,
        );
        expect(count, 1);
        expect(await writer, 1);
        expect(stream.writable.canWriteSourceImmediately(1), isFalse);
        expect(copied, [7]);
        stream.readable.finishDeferredCopy(dropped: false);
      },
    );

    test(
      'an immediately matched source does not retain its own suffix',
      () async {
        final stream = WASIComponentStream<int>(
          'immediate source',
          maxBufferedElements: 0,
        );
        final reader = stream.readable.readWhenAvailableForCopy(1);
        var loaded = 0;
        final count = await stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 2,
            readPrefix: (_) {
              loaded++;
              return [7];
            },
          ),
          deferCompletion: true,
        );
        expect(count, 1);
        expect(await reader, [7]);
        expect(stream.readable.readForCopy(1), isEmpty);
        expect(loaded, 1);
        stream.writable.finishDeferredCopy(dropped: false);
      },
    );

    test(
      'a failing target fails both endpoints and stops its cursor',
      () async {
        final stream = WASIComponentStream<int>(
          'failed target',
          maxBufferedElements: 0,
        );
        final failure = StateError('target store failed');
        var attempts = 0;
        final reader = stream.readable.readIntoWhenAvailableForCopy(
          WASIComponentAsyncCopyTarget<int>(
            length: 2,
            writePrefix: (_) {
              attempts++;
              throw failure;
            },
          ),
          deferCompletion: true,
        );
        final observed = expectLater(reader, throwsA(same(failure)));
        expect(
          () => stream.writable.writeSourceForCopy(
            WASIComponentAsyncCopySource<int>(
              length: 1,
              readPrefix: (_) => [7],
            ),
          ),
          throwsA(same(failure)),
        );
        await observed;
        expect(attempts, 1);
        expect(stream.writable.canWriteSourceImmediately(1), isFalse);
        stream.readable.finishDeferredCopy(dropped: false);
      },
    );

    test('a target failure also rejects an already blocked writer', () async {
      final stream = WASIComponentStream<int>(
        'writer before failed target',
        maxBufferedElements: 0,
      );
      final failure = StateError('target store failed');
      final writer = stream.writable.writeSourceWhenAvailableForCopy(
        WASIComponentAsyncCopySource<int>(length: 1, readPrefix: (_) => [7]),
      );
      final observedWriter = expectLater(writer, throwsA(same(failure)));
      await expectLater(
        Future<int>.sync(
          () => stream.readable.readIntoWhenAvailableForCopy(
            WASIComponentAsyncCopyTarget<int>(
              length: 2,
              writePrefix: (_) => throw failure,
            ),
          ),
        ),
        throwsA(same(failure)),
      );
      await observedWriter;
      expect(stream.writable.canWriteSourceImmediately(1), isFalse);
    });

    test('empty targets never call the value store', () async {
      final stream = WASIComponentStream<int>(
        'empty target',
        maxBufferedElements: 0,
      );
      var stored = 0;
      expect(
        await stream.readable.readIntoWhenAvailableForCopy(
          WASIComponentAsyncCopyTarget<int>(
            length: 0,
            writePrefix: (_) => stored++,
          ),
        ),
        0,
      );
      expect(stored, 0);
    });
  });

  group('canonical copy sources', () {
    test(
      'synchronous read accepts a waiting unbuffered source prefix',
      () async {
        final loaded = <int>[];
        final stream = WASIComponentStream<int>(
          'sync rendezvous',
          maxBufferedElements: 0,
        );
        final pending = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 2,
            readPrefix: (count) {
              loaded.add(count);
              return [7, 8].take(count).toList();
            },
          ),
        );
        expect(stream.readable.readForCopy(1), [7]);
        expect(await pending, 1);
        expect(loaded, [1]);
        expect(stream.queuedLength, 0);
      },
    );

    test('stream loads only the accepted bounded prefix', () async {
      final loaded = <int>[];
      final discarded = <int>[];
      final stream = WASIComponentStream<int>(
        'prefix',
        maxBufferedElements: 1,
        onDiscard: discarded.add,
      );
      final source = WASIComponentAsyncCopySource<int>(
        length: 2,
        readPrefix: (count) {
          loaded.add(count);
          return [for (var i = 0; i < count; i++) i + 7];
        },
      );
      expect(await stream.writable.writeSourceWhenAvailableForCopy(source), 1);
      expect(loaded, [1]);
      stream.readable.drop();
      stream.writable.drop();
      expect(discarded, [7]);
    });

    test(
      'stream waits and cancels without loading an unaccepted source',
      () async {
        var loaded = 0;
        final stream = WASIComponentStream<int>(
          'cancel',
          maxBufferedElements: 1,
        );
        stream.writable.write(1);
        final pending = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 2,
            readPrefix: (count) {
              loaded++;
              return [2, 3].take(count).toList();
            },
          ),
        );
        final observed = expectLater(
          pending,
          throwsA(isA<WASIComponentAsyncEndpointStateError>()),
        );
        expect(loaded, 0);
        stream.writable.cancelPendingCopy();
        await observed;
        expect(loaded, 0);
        expect(stream.readable.read(2), [1]);
      },
    );

    test(
      'stream reader drop rejects a waiting source without loading',
      () async {
        var loaded = 0;
        final stream = WASIComponentStream<int>('drop', maxBufferedElements: 0);
        final pending = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            readPrefix: (count) {
              loaded++;
              return [7];
            },
          ),
        );
        final observed = expectLater(
          pending,
          throwsA(isA<WASIComponentAsyncEndpointStateError>()),
        );
        stream.readable.drop();
        await observed;
        expect(loaded, 0);
      },
    );

    test('stream rendezvous loads exactly the matched reader prefix', () async {
      final loaded = <int>[];
      final stream = WASIComponentStream<int>(
        'rendezvous',
        maxBufferedElements: 0,
      );
      final pending = stream.writable.writeSourceWhenAvailableForCopy(
        WASIComponentAsyncCopySource<int>(
          length: 2,
          readPrefix: (count) {
            loaded.add(count);
            return [7, 8].take(count).toList();
          },
        ),
      );
      expect(loaded, isEmpty);
      expect(await stream.readable.readWhenAvailableForCopy(1), [7]);
      expect(await pending, 1);
      expect(loaded, [1]);
      expect(stream.queuedLength, 0);
    });

    test(
      'synchronous source copies accept a prefix and preserve eager APIs',
      () {
        final loaded = <int>[];
        final stream = WASIComponentStream<int>(
          'sync-prefix',
          maxBufferedElements: 1,
        );
        final source = WASIComponentAsyncCopySource<int>(
          length: 2,
          readPrefix: (count) {
            loaded.add(count);
            return [7, 8].take(count).toList();
          },
        );
        expect(stream.writable.writeSourceForCopy(source), 1);
        expect(
          () => stream.writable.writeSourceForCopy(source),
          throwsStateError,
        );
        expect(loaded, [1]);
        expect(stream.readable.read(1), [7]);
        expect(() => stream.writable.writeAllForCopy([1, 2]), throwsStateError);
        expect(stream.queuedLength, 0);
      },
    );

    test(
      'synchronous rendezvous source copies match an awaiting reader',
      () async {
        var loaded = 0;
        final stream = WASIComponentStream<int>(
          'sync-rendezvous',
          maxBufferedElements: 0,
        );
        final read = stream.readable.readWhenAvailableForCopy(1);
        expect(
          stream.writable.writeSourceForCopy(
            WASIComponentAsyncCopySource<int>(
              length: 2,
              readPrefix: (count) {
                loaded++;
                expect(count, 1);
                return [7];
              },
            ),
          ),
          1,
        );
        expect(await read, [7]);
        expect(loaded, 1);
      },
    );

    test('empty stream sources do not load values', () async {
      var loaded = 0;
      final stream = WASIComponentStream<int>('empty', maxBufferedElements: 0);
      final source = WASIComponentAsyncCopySource<int>(
        length: 0,
        readPrefix: (count) {
          loaded++;
          return [];
        },
      );
      expect(stream.writable.writeSourceForCopy(source), 0);
      expect(await stream.writable.writeSourceWhenAvailableForCopy(source), 0);
      expect(loaded, 0);
    });

    test(
      'a failing rendezvous source fails both waits and permits retry',
      () async {
        final stream = WASIComponentStream<int>(
          'failure',
          maxBufferedElements: 0,
        );
        final failure = StateError('source failed');
        final write = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            readPrefix: (_) => throw failure,
          ),
        );
        final writeFailure = expectLater(write, throwsA(same(failure)));
        await expectLater(
          stream.readable.readWhenAvailableForCopy(1),
          throwsA(same(failure)),
        );
        await writeFailure;
        final read = stream.readable.readWhenAvailableForCopy(1);
        expect(
          await stream.writable.writeSourceWhenAvailableForCopy(
            WASIComponentAsyncCopySource<int>(
              length: 1,
              readPrefix: (_) => [9],
            ),
          ),
          1,
        );
        expect(await read, [9]);
      },
    );

    test(
      'a failing bounded source does not lose an unrelated queued read',
      () async {
        final stream = WASIComponentStream<int>(
          'bounded-failure',
          maxBufferedElements: 1,
        );
        stream.writable.write(3);
        final failure = StateError('source failed');
        final write = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            readPrefix: (_) => throw failure,
          ),
        );
        final observed = expectLater(write, throwsA(same(failure)));
        expect(stream.readable.read(1), [3]);
        await observed;
        expect(stream.queuedLength, 0);
        expect(
          stream.writable.writeSourceForCopy(
            WASIComponentAsyncCopySource<int>(
              length: 1,
              readPrefix: (_) => [9],
            ),
          ),
          1,
        );
        expect(stream.readable.read(1), [9]);
      },
    );

    test('future loads only when a reader actually accepts', () async {
      var loaded = 0;
      final discarded = <int>[];
      final future = WASIComponentFuture<int>(
        'future',
        onDiscard: discarded.add,
      );
      final write = future.writable.completeSourceWhenReadForCopy(
        WASIComponentAsyncCopySource<int>(
          length: 1,
          readPrefix: (count) {
            loaded++;
            expect(count, 1);
            return [7];
          },
        ),
      );
      expect(loaded, 0);
      expect(future.writable.hasPendingWriteDelivery, isTrue);
      final readyBeforeRead = future.readable.isReady;
      final completedBeforeRead = future.writable.isCompleted;
      expect(future.readable.readForCopy(), 7);
      await write;
      expect(readyBeforeRead, isTrue);
      expect(completedBeforeRead, isFalse);
      expect(loaded, 1);
      future.readable.drop();
      future.writable.drop();
      expect(discarded, isEmpty);
    });

    test('future cancellation leaves the offered source untouched', () async {
      var loaded = 0;
      final future = WASIComponentFuture<int>('cancelled-future');
      final source = WASIComponentAsyncCopySource<int>(
        length: 1,
        readPrefix: (_) {
          loaded++;
          return [7];
        },
      );
      final write = future.writable.completeSourceWhenReadForCopy(source);
      final observed = expectLater(
        write,
        throwsA(isA<WASIComponentAsyncEndpointStateError>()),
      );
      future.writable.cancelPendingCopy();
      await observed;
      expect(loaded, 0);
      final retry = future.writable.completeSourceWhenReadForCopy(source);
      expect(await future.readable.readWhenReadyForCopy(), 7);
      await retry;
      expect(loaded, 1);
    });

    test(
      'future readable drop does not load or discard an unaccepted source',
      () async {
        var loaded = 0;
        final discarded = <int>[];
        final future = WASIComponentFuture<int>(
          'dropped-future',
          onDiscard: discarded.add,
        );
        final write = future.writable.completeSourceWhenReadForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            readPrefix: (_) {
              loaded++;
              return [7];
            },
          ),
        );
        final observed = expectLater(
          write,
          throwsA(isA<WASIComponentAsyncEndpointStateError>()),
        );
        future.readable.drop();
        await observed;
        expect(loaded, 0);
        expect(discarded, isEmpty);
      },
    );

    test('synchronous future source requires an accepting reader', () async {
      var loaded = 0;
      final future = WASIComponentFuture<int>('sync-future');
      final source = WASIComponentAsyncCopySource<int>(
        length: 1,
        readPrefix: (_) {
          loaded++;
          return [7];
        },
      );
      expect(
        () => future.writable.completeSourceForCopy(source),
        throwsStateError,
      );
      expect(loaded, 0);
      final read = future.readable.readWhenReadyForCopy();
      future.writable.completeSourceForCopy(source);
      expect(await read, 7);
      expect(loaded, 1);
    });

    test(
      'a failing future source fails both waits and permits retry',
      () async {
        final future = WASIComponentFuture<int>('failed-future');
        final failure = StateError('future source failed');
        final read = future.readable.readWhenReadyForCopy();
        final observed = expectLater(read, throwsA(same(failure)));
        final write = future.writable.completeSourceWhenReadForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            readPrefix: (_) => throw failure,
          ),
        );
        await expectLater(write, throwsA(same(failure)));
        await observed;
        final retry = future.writable.completeSourceWhenReadForCopy(
          WASIComponentAsyncCopySource<int>(length: 1, readPrefix: (_) => [9]),
        );
        expect(await future.readable.readWhenReadyForCopy(), 9);
        await retry;
      },
    );

    test('future producer disposal clears an unaccepted source', () async {
      var loaded = 0;
      final discarded = <int>[];
      final future = WASIComponentFuture<int>(
        'disposed-future',
        onDiscard: discarded.add,
      );
      final write = future.writable.completeSourceWhenReadForCopy(
        WASIComponentAsyncCopySource<int>(
          length: 1,
          readPrefix: (_) {
            loaded++;
            return [7];
          },
        ),
      );
      final observed = expectLater(
        write,
        throwsA(isA<WASIComponentAsyncEndpointStateError>()),
      );
      future.writable.dispose();
      await observed;
      future.readable.drop();
      expect(loaded, 0);
      expect(discarded, isEmpty);
      expect(future.isDropped, isTrue);
    });

    test('future source arity errors never invoke the loader', () {
      var loaded = 0;
      final future = WASIComponentFuture<int>('arity');
      for (final length in [0, 2]) {
        final source = WASIComponentAsyncCopySource<int>(
          length: length,
          readPrefix: (_) {
            loaded++;
            return [7];
          },
        );
        expect(
          () => future.writable.completeSourceForCopy(source),
          throwsStateError,
        );
        expect(
          () => future.writable.completeSourceWhenReadForCopy(source),
          throwsStateError,
        );
      }
      expect(loaded, 0);
    });

    test(
      'deferred future cancellation retains copy state until delivery',
      () async {
        var loaded = 0;
        final future = WASIComponentFuture<int>('deferred-cancel');
        final source = WASIComponentAsyncCopySource<int>(
          length: 1,
          readPrefix: (_) {
            loaded++;
            return [7];
          },
        );
        final pending = future.writable.completeSourceWhenReadForCopy(
          source,
          deferCompletion: true,
        );
        final observed = expectLater(
          pending,
          throwsA(isA<WASIComponentAsyncEndpointStateError>()),
        );
        future.writable.cancelPendingCopy();
        await observed;
        expect(loaded, 0);
        expect(future.writable.requireDroppable, throwsStateError);
        future.writable.finishDeferredCopy(cancelled: true);
        final retry = future.writable.completeSourceWhenReadForCopy(source);
        expect(await future.readable.readWhenReadyForCopy(), 7);
        await retry;
        expect(loaded, 1);
      },
    );

    test(
      'queued host writes retain priority over a waiting guest source',
      () async {
        var loaded = 0;
        final stream = WASIComponentStream<int>('fifo', maxBufferedElements: 1);
        stream.writable.write(3);
        final host = stream.writable.writeWhenAvailable([4]);
        final guest = stream.writable.writeSourceWhenAvailableForCopy(
          WASIComponentAsyncCopySource<int>(
            length: 1,
            readPrefix: (_) {
              loaded++;
              return [7];
            },
          ),
        );
        expect(stream.readable.read(1), [3]);
        expect(await host, 1);
        expect(loaded, 0);
        expect(stream.readable.read(1), [4]);
        expect(await guest, 1);
        expect(loaded, 1);
        expect(stream.readable.read(1), [7]);
      },
    );
  });

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
