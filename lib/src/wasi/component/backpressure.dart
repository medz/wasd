import 'dart:async';

/// Host-side Component Model async backpressure state.
///
/// WASI 0.3 async backpressure is modeled as a bounded counter. A positive
/// count means producers should stop pushing work; waiters complete once the
/// count returns to zero.
final class WASIComponentBackpressure {
  /// Maximum representable backpressure count.
  static const int maxCount = 0xffff;

  int _count = 0;
  List<Completer<void>>? _releaseWaiters;

  /// Current backpressure counter.
  int get count => _count;

  /// Whether backpressure is currently active.
  bool get isActive => _count != 0;

  /// Waits until backpressure is no longer active.
  Future<void> waitUntilReleased() {
    if (_count == 0) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    (_releaseWaiters ??= <Completer<void>>[]).add(completer);
    return completer.future;
  }

  /// Sets backpressure to active or released.
  int setActive(bool active) {
    return setCount(active ? 1 : 0);
  }

  /// Sets the counter to [count].
  int setCount(int count) {
    RangeError.checkValueInInterval(count, 0, maxCount, 'count');
    _count = count;
    if (_count == 0) {
      _completeReleaseWaiters();
    }
    return _count;
  }

  /// Increments the counter and returns the new count.
  int increment() {
    if (_count == maxCount) {
      throw StateError('WASI component backpressure counter overflow.');
    }
    _count++;
    return _count;
  }

  /// Decrements the counter and returns the new count.
  int decrement() {
    if (_count == 0) {
      throw StateError('WASI component backpressure counter underflow.');
    }
    _count--;
    if (_count == 0) {
      _completeReleaseWaiters();
    }
    return _count;
  }

  void _completeReleaseWaiters() {
    final waiters = _releaseWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    _releaseWaiters = null;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}
