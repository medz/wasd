import 'dart:async';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/backpressure.dart';

void main() {
  group('WASIComponentBackpressure', () {
    test('tracks active counter state and waiters', () async {
      final backpressure = WASIComponentBackpressure();
      var released = false;

      expect(backpressure.count, 0);
      expect(backpressure.isActive, isFalse);

      expect(backpressure.increment(), 1);
      final pending = backpressure.waitUntilReleased()
        ..then((_) {
          released = true;
        });
      await Future<void>.delayed(Duration.zero);

      expect(released, isFalse);
      expect(backpressure.decrement(), 0);

      await expectLater(pending, completes);
      expect(released, isTrue);
      expect(backpressure.isActive, isFalse);
    });

    test('rejects counter underflow and overflow', () {
      final backpressure = WASIComponentBackpressure();

      expect(backpressure.decrement, throwsStateError);
      backpressure.setCount(WASIComponentBackpressure.maxCount);

      expect(backpressure.increment, throwsStateError);
      expect(backpressure.count, WASIComponentBackpressure.maxCount);
    });

    test('sets boolean active state', () async {
      final backpressure = WASIComponentBackpressure();

      expect(backpressure.setActive(true), 1);
      expect(backpressure.isActive, isTrue);

      final pending = backpressure.waitUntilReleased();

      expect(backpressure.setActive(false), 0);
      await expectLater(pending, completes);
      expect(backpressure.count, 0);
    });

    test('admits released entries before newcomers', () async {
      final backpressure = WASIComponentBackpressure()..increment();
      final order = <String>[];
      final first = backpressure.enter().then((admitted) {
        expect(admitted, isTrue);
        order.add('first');
      });
      final second = backpressure.enter().then((admitted) {
        expect(admitted, isTrue);
        order.add('second');
      });

      await Future<void>.delayed(Duration.zero);
      backpressure.decrement();
      final newcomer = backpressure.enter().then((admitted) {
        expect(admitted, isTrue);
        order.add('newcomer');
      });

      await Future.wait<void>([first, second, newcomer]);
      expect(order, <String>['first', 'second', 'newcomer']);
    });

    test(
      'cancels a blocked entry without retaining its queue position',
      () async {
        final backpressure = WASIComponentBackpressure()..increment();
        final cancellation = Completer<void>();
        final blocked = backpressure.enter(cancellation: cancellation.future);

        await Future<void>.delayed(Duration.zero);
        cancellation.complete();

        await expectLater(blocked, completion(isFalse));
        backpressure.decrement();
        await expectLater(backpressure.enter(), completion(isTrue));
      },
    );
  });
}
