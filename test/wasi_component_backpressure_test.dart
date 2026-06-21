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
  });
}
