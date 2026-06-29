import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/wit_adapter.dart';

/// WASI 0.3 `wasi:clocks` host imports.
final class WASIPreview3ClocksHost {
  /// Creates a clocks host import provider.
  WASIPreview3ClocksHost() : _monotonicClock = Stopwatch()..start();

  static final BigInt _nanosecondsPerMicrosecond = BigInt.from(1000);
  static final BigInt _maxDelayNanoseconds =
      BigInt.from(const Duration(days: 1).inMicroseconds) *
      _nanosecondsPerMicrosecond;

  final Stopwatch _monotonicClock;

  /// Import callbacks keyed by canonical WIT adapter names.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:clocks/monotonic-clock@0.3.0.now': (_) => _monotonicNow(),
        'wasi:clocks/monotonic-clock@0.3.0.get-resolution': (_) =>
            BigInt.from(1000),
        'wasi:clocks/monotonic-clock@0.3.0.wait-until': (args) =>
            _waitUntil(args.single),
        'wasi:clocks/monotonic-clock@0.3.0.wait-for': (args) =>
            _waitFor(args.single),
        'wasi:clocks/system-clock@0.3.0.now': (_) => _systemNow(),
        'wasi:clocks/system-clock@0.3.0.get-resolution': (_) =>
            BigInt.from(1000),
        'wasi:clocks/timezone@0.3.0.iana-id': (_) => _none(),
        'wasi:clocks/timezone@0.3.0.utc-offset': (_) => _none(),
        'wasi:clocks/timezone@0.3.0.to-debug-string': (_) =>
            DateTime.now().timeZoneName,
      });

  BigInt _monotonicNow() {
    return BigInt.from(_monotonicClock.elapsedMicroseconds) *
        _nanosecondsPerMicrosecond;
  }

  Future<void> _waitFor(Object? durationValue) async {
    await _delayNanoseconds(_u64(durationValue));
  }

  Future<void> _waitUntil(Object? markValue) async {
    final mark = _u64(markValue);
    final now = _monotonicNow();
    if (mark <= now) {
      return;
    }
    await _delayNanoseconds(mark - now);
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

  WasmComponentValueData _systemNow() {
    final now = DateTime.now().toUtc();
    final micros = now.microsecondsSinceEpoch;
    final seconds = micros ~/ Duration.microsecondsPerSecond;
    final nanoseconds =
        (micros.remainder(Duration.microsecondsPerSecond)) * 1000;
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
}

BigInt _u64(Object? value) {
  return switch (value) {
    int() => BigInt.from(value),
    BigInt() => value,
    _ => BigInt.zero,
  };
}

WasmComponentValueData _none() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
    isSome: false,
  );
}
