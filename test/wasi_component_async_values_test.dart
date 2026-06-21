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
      expect(dropped, isEmpty);
      stream.writable.drop();

      expect(stream.isDropped, isTrue);
      expect(dropped, <String>['numbers']);
      expect(() => stream.readable.read(1), throwsStateError);
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
  });

  group('WASIComponentFuture', () {
    test('completes readable and writable future endpoints exactly once', () {
      final dropped = <String>[];
      final future = WASIComponentFuture<int>(
        'answer',
        onDrop: () => dropped.add('answer'),
      );

      expect(future.readable.isReady, isFalse);
      expect(() => future.readable.read(), throwsStateError);

      future.writable.complete(42);

      expect(future.readable.isReady, isTrue);
      expect(future.readable.read(), 42);
      expect(() => future.writable.complete(43), throwsStateError);

      future.readable.drop();
      expect(dropped, isEmpty);
      future.writable.drop();

      expect(future.isDropped, isTrue);
      expect(dropped, <String>['answer']);
    });

    test('cancels pending futures', () {
      final future = WASIComponentFuture<String>('message');

      future.readable.cancel();

      expect(future.isCancelled, isTrue);
      expect(future.readable.isCancelled, isTrue);
      expect(() => future.writable.complete('late'), throwsStateError);
      expect(() => future.readable.read(), throwsStateError);
    });
  });
}
