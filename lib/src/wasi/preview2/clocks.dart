import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/wit_adapter.dart';
import 'poll.dart';

/// WASI 0.2 `wasi:clocks` host imports.
final class WASIPreview2ClocksHost {
  /// Creates a clocks host whose subscriptions are owned by [pollHost].
  WASIPreview2ClocksHost({WASIPreview2PollHost? pollHost})
    : pollHost = pollHost ?? WASIPreview2PollHost(),
      _monotonicClock = Stopwatch()..start();

  static final BigInt _nanosecondsPerMicrosecond = BigInt.from(1000);
  static final BigInt _maxDelayNanoseconds =
      BigInt.from(const Duration(days: 1).inMicroseconds) *
      _nanosecondsPerMicrosecond;

  /// Poll host used for `subscribe-instant` and `subscribe-duration` handles.
  final WASIPreview2PollHost pollHost;

  final Stopwatch _monotonicClock;

  /// Standard `wasi:clocks@0.2.0` import callbacks.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:clocks/monotonic-clock@0.2.0.now': (_) => _monotonicNow(),
        'wasi:clocks/monotonic-clock@0.2.0.resolution': (_) =>
            BigInt.from(1000),
        'wasi:clocks/monotonic-clock@0.2.0.subscribe-instant': (args) =>
            _subscribeInstant(_u64(args.single)),
        'wasi:clocks/monotonic-clock@0.2.0.subscribe-duration': (args) =>
            _subscribeDuration(_u64(args.single)),
        'wasi:clocks/wall-clock@0.2.0.now': (_) => _wallNow(),
        'wasi:clocks/wall-clock@0.2.0.resolution': (_) =>
            _datetime(BigInt.zero, 1000),
      });

  BigInt _monotonicNow() {
    return BigInt.from(_monotonicClock.elapsedMicroseconds) *
        _nanosecondsPerMicrosecond;
  }

  int _subscribeInstant(BigInt when) {
    return pollHost.insert(
      WASIPreview2Pollable(
        isReady: () => _monotonicNow() >= when,
        waitReady: () => _delayUntil(when),
      ),
    );
  }

  int _subscribeDuration(BigInt duration) {
    return _subscribeInstant(_monotonicNow() + duration);
  }

  Future<void> _delayUntil(BigInt mark) async {
    final remaining = mark - _monotonicNow();
    if (remaining <= BigInt.zero) {
      return;
    }
    await _delayNanoseconds(remaining);
  }

  Future<void> _delayNanoseconds(BigInt duration) async {
    var remaining = duration;
    while (remaining > BigInt.zero) {
      final chunk = remaining > _maxDelayNanoseconds
          ? _maxDelayNanoseconds
          : remaining;
      final microseconds =
          (chunk + _nanosecondsPerMicrosecond - BigInt.one) ~/
          _nanosecondsPerMicrosecond;
      if (microseconds > BigInt.zero) {
        await Future<void>.delayed(
          Duration(microseconds: microseconds.toInt()),
        );
      }
      remaining -= chunk;
    }
  }

  WasmComponentValueData _wallNow() {
    final now = DateTime.now().toUtc();
    final micros = now.microsecondsSinceEpoch;
    final seconds = micros ~/ Duration.microsecondsPerSecond;
    final nanoseconds =
        (micros.remainder(Duration.microsecondsPerSecond)) * 1000;
    return _datetime(BigInt.from(seconds), nanoseconds);
  }
}

BigInt _u64(Object? value) {
  return switch (value) {
    int() when value >= 0 => BigInt.from(value),
    BigInt() when value >= BigInt.zero => value,
    _ => throw StateError('Expected u64 nanoseconds value, got $value.'),
  };
}

WasmComponentValueData _datetime(BigInt seconds, int nanoseconds) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    items: [
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.integer,
        rawBytes: Uint8List(0),
        integer: seconds,
      ),
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.integer,
        rawBytes: Uint8List(0),
        integer: nanoseconds,
      ),
    ],
  );
}
