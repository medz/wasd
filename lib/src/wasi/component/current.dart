import 'dart:async';

/// Dynamic current-value storage for Component Model execution scopes.
///
/// Synchronous scopes use a stack-like current pointer so hot non-async
/// canonical operations avoid Zone lookups. Asynchronous scopes use a Zone value
/// so overlapping component tasks, threads, and contexts do not overwrite each
/// other while awaiting.
final class WASIComponentCurrent<T extends Object> {
  /// Creates storage with an optional base current value.
  WASIComponentCurrent([T? current]) : _current = current;

  final Object _zoneKey = Object();
  T? _current;
  int _syncDepth = 0;

  /// Current value visible to the active execution scope.
  T? get current {
    if (_syncDepth > 0) {
      return _current;
    }
    if (!identical(Zone.current, Zone.root)) {
      final value = Zone.current[_zoneKey];
      if (value is T) {
        return value;
      }
    }
    return _current;
  }

  /// Runs [callback] with [value] as the synchronous current value.
  R run<R>(T value, R Function() callback) {
    final previous = _current;
    _current = value;
    _syncDepth++;
    try {
      return callback();
    } finally {
      _current = previous;
      _syncDepth--;
    }
  }

  /// Runs [callback] with [value] as the current value until it completes.
  Future<R> runAsync<R>(T value, Future<R> Function() callback) async {
    return await runZoned<Future<R>>(
      callback,
      zoneValues: <Object?, Object?>{_zoneKey: value},
    );
  }
}
