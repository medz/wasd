import 'dart:async';
import 'dart:collection';

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
  final Queue<_WASIComponentBackpressureEntry> _entries =
      Queue<_WASIComponentBackpressureEntry>();

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

  /// Waits to enter guest code while preserving release order.
  ///
  /// Returns false when [cancellation] completes before this entry is
  /// admitted. Released entries retain their queue position until their
  /// continuation resumes, so a newly arriving task cannot bypass them.
  Future<bool> enter({Future<void>? cancellation}) async {
    if (_count == 0 && _entries.isEmpty) {
      return true;
    }

    final entry = _WASIComponentBackpressureEntry();
    _entries.addLast(entry);
    _grantNextEntry();
    try {
      while (true) {
        final admitted = cancellation == null
            ? await entry.granted.future.then((_) => true)
            : await Future.any<bool>([
                entry.granted.future.then((_) => true),
                cancellation.then((_) => false),
              ]);
        if (!admitted) {
          _removeEntry(entry);
          return false;
        }
        if (_count != 0) {
          entry.granted = Completer<void>();
          continue;
        }
        if (_entries.isEmpty || !identical(_entries.first, entry)) {
          throw StateError('WASI component backpressure entry lost its turn.');
        }
        _entries.removeFirst();
        _grantNextEntry();
        return true;
      }
    } catch (_) {
      _removeEntry(entry);
      rethrow;
    }
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
      _grantNextEntry();
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
      _grantNextEntry();
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

  void _grantNextEntry() {
    if (_count != 0 || _entries.isEmpty) {
      return;
    }
    final granted = _entries.first.granted;
    if (!granted.isCompleted) {
      granted.complete();
    }
  }

  void _removeEntry(_WASIComponentBackpressureEntry entry) {
    final wasFirst = _entries.isNotEmpty && identical(_entries.first, entry);
    if (!_entries.remove(entry)) {
      return;
    }
    if (wasFirst) {
      _grantNextEntry();
    }
  }
}

final class _WASIComponentBackpressureEntry {
  Completer<void> granted = Completer<void>();
}
