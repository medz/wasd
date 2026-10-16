import 'dart:async';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/preview3/clocks.dart';

void main() {
  test('wait-until is synchronously ready for a past mark', () {
    final host = WASIPreview3ClocksHost();
    final waitUntil =
        host.imports['wasi:clocks/monotonic-clock@0.3.0.wait-until']!;

    expect(waitUntil(<Object?>[BigInt.zero]), isNot(isA<Future<void>>()));
  });

  test('zero waits complete without scheduling a timer', () async {
    final host = WASIPreview3ClocksHost();
    final now = host.imports['wasi:clocks/monotonic-clock@0.3.0.now']!;
    final waitFor = host.imports['wasi:clocks/monotonic-clock@0.3.0.wait-for']!;
    final waitUntil =
        host.imports['wasi:clocks/monotonic-clock@0.3.0.wait-until']!;

    await runZoned(
      () async {
        expect(waitUntil(<Object?>[now([])]), isNot(isA<Future<void>>()));
        final pending = waitFor(<Object?>[BigInt.zero]);
        expect(pending, isA<Future<void>>());
        await pending;
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) =>
            throw StateError('zero waits must not schedule a timer'),
      ),
    );
  });

  for (final operation in ['wait-for', 'wait-until']) {
    test('$operation rechecks the deadline after an early timer', () async {
      final host = WASIPreview3ClocksHost();
      final now = host.imports['wasi:clocks/monotonic-clock@0.3.0.now']!;
      final wait =
          host.imports['wasi:clocks/monotonic-clock@0.3.0.$operation']!;
      final duration = BigInt.from(50000000);
      final deadline = (now([]) as BigInt) + duration;
      var timerCount = 0;

      await runZoned(
        () => wait(<Object?>[operation == 'wait-for' ? duration : deadline]),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, delay, callback) {
            timerCount++;
            // Simulate the timer waking before the monotonic deadline.
            return parent.createTimer(
              zone,
              timerCount == 1 ? Duration.zero : delay,
              callback,
            );
          },
        ),
      );

      expect(now([]) as BigInt, greaterThanOrEqualTo(deadline));
    });

    test('$operation rounds short timer delays up to milliseconds', () async {
      final host = WASIPreview3ClocksHost();
      final now = host.imports['wasi:clocks/monotonic-clock@0.3.0.now']!;
      final wait =
          host.imports['wasi:clocks/monotonic-clock@0.3.0.$operation']!;
      final delays = <Duration>[];

      await runZoned(
        () async {
          for (final nanoseconds in [1, 1000, 999999, 1000000, 1500000]) {
            final duration = BigInt.from(nanoseconds);
            final deadline = (now([]) as BigInt) + duration;
            await wait(<Object?>[
              operation == 'wait-for' ? duration : deadline,
            ]);
            expect(now([]) as BigInt, greaterThanOrEqualTo(deadline));
          }
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, delay, callback) {
            delays.add(delay);
            return parent.createTimer(zone, delay, callback);
          },
        ),
      );

      expect(delays, isNotEmpty);
      for (final delay in delays) {
        expect(delay.inMilliseconds, greaterThanOrEqualTo(1));
        expect(delay.inMicroseconds % Duration.microsecondsPerMillisecond, 0);
      }
    });

    test('$operation chunks long waits at one day', () async {
      final host = WASIPreview3ClocksHost();
      final wait =
          host.imports['wasi:clocks/monotonic-clock@0.3.0.$operation']!;
      final stopped = StateError('stop before scheduling a long timer');
      Duration? delay;

      await expectLater(
        runZoned(
          () => wait(<Object?>[BigInt.parse('18446744073709551615')]),
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              delay = duration;
              throw stopped;
            },
          ),
        ),
        throwsA(same(stopped)),
      );
      expect(delay, const Duration(days: 1));
    });
  }
}
