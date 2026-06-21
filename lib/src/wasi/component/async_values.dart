import 'dart:collection';

/// In-memory runtime state for a Component Model `stream<T>` value.
///
/// This is a host-side primitive for future WASI 0.3 canonical stream
/// bindings. It deliberately models readable and writable endpoints separately
/// so canonical `stream.new`, `stream.read`, `stream.write`, cancellation, and
/// drop operations can be layered on top without mixing ownership rules into
/// the queue implementation.
final class WASIComponentStream<T extends Object> {
  /// Creates a stream with a debug [name].
  WASIComponentStream(String name, {void Function()? onDrop})
    : _state = _WASIComponentStreamState<T>(name, onDrop) {
    readable = WASIComponentReadableStream<T>._(_state);
    writable = WASIComponentWritableStream<T>._(_state);
  }

  final _WASIComponentStreamState<T> _state;

  /// Readable endpoint.
  late final WASIComponentReadableStream<T> readable;

  /// Writable endpoint.
  late final WASIComponentWritableStream<T> writable;

  /// Debug label used in diagnostics.
  String get name => _state.name;

  /// Number of queued values waiting to be read.
  int get queuedLength => _state.queue.length;

  /// Whether both endpoints have been dropped.
  bool get isDropped => _state.isDropped;
}

/// Readable endpoint for [WASIComponentStream].
final class WASIComponentReadableStream<T extends Object> {
  const WASIComponentReadableStream._(this._state);

  final _WASIComponentStreamState<T> _state;

  /// Whether reads have been cancelled.
  bool get isCancelled => _state.readCancelled;

  /// Whether this endpoint has been dropped.
  bool get isDropped => _state.readDropped;

  /// Reads up to [maxElements] queued values.
  ///
  /// This is non-blocking: an empty list means no values are currently queued.
  List<T> read(int maxElements) {
    _state.requireReadable();
    RangeError.checkNotNegative(maxElements, 'maxElements');
    if (maxElements == 0 || _state.queue.isEmpty) {
      return <T>[];
    }

    final available = _state.queue.length;
    final count = maxElements < available ? maxElements : available;
    return List<T>.generate(count, (_) => _state.queue.removeFirst());
  }

  /// Cancels future reads and discards queued values.
  void cancel() {
    _state.cancelRead();
  }

  /// Drops this endpoint.
  void drop() {
    _state.dropReadable();
  }
}

/// Writable endpoint for [WASIComponentStream].
final class WASIComponentWritableStream<T extends Object> {
  const WASIComponentWritableStream._(this._state);

  final _WASIComponentStreamState<T> _state;

  /// Whether no more writes are accepted.
  bool get isClosed => _state.writeClosed || _state.writeDropped;

  /// Whether writes have been cancelled.
  bool get isCancelled => _state.writeCancelled;

  /// Whether this endpoint has been dropped.
  bool get isDropped => _state.writeDropped;

  /// Writes one value to the stream.
  void write(T value) {
    _state.requireWritable();
    _state.queue.addLast(value);
  }

  /// Writes all [values] to the stream.
  void writeAll(Iterable<T> values) {
    _state.requireWritable();
    _state.queue.addAll(values);
  }

  /// Closes the writable endpoint without dropping it.
  void close() {
    _state.closeWrite();
  }

  /// Cancels future writes.
  void cancel() {
    _state.cancelWrite();
  }

  /// Drops this endpoint.
  void drop() {
    _state.dropWritable();
  }
}

/// In-memory runtime state for a Component Model `future<T>` value.
final class WASIComponentFuture<T extends Object> {
  /// Creates a future with a debug [name].
  WASIComponentFuture(String name, {void Function()? onDrop})
    : _state = _WASIComponentFutureState<T>(name, onDrop) {
    readable = WASIComponentReadableFuture<T>._(_state);
    writable = WASIComponentWritableFuture<T>._(_state);
  }

  final _WASIComponentFutureState<T> _state;

  /// Readable endpoint.
  late final WASIComponentReadableFuture<T> readable;

  /// Writable endpoint.
  late final WASIComponentWritableFuture<T> writable;

  /// Debug label used in diagnostics.
  String get name => _state.name;

  /// Whether the future has been cancelled.
  bool get isCancelled => _state.isCancelled;

  /// Whether both endpoints have been dropped.
  bool get isDropped => _state.isDropped;
}

/// Readable endpoint for [WASIComponentFuture].
final class WASIComponentReadableFuture<T extends Object> {
  const WASIComponentReadableFuture._(this._state);

  final _WASIComponentFutureState<T> _state;

  /// Whether the future has a completed value.
  bool get isReady => _state.isReady;

  /// Whether the future has been cancelled.
  bool get isCancelled => _state.isCancelled;

  /// Whether this endpoint has been dropped.
  bool get isDropped => _state.readDropped;

  /// Reads the completed value.
  T read() {
    _state.requireReadable();
    if (!_state.isReady) {
      throw StateError('WASI component future ${_state.name} is not ready.');
    }
    return _state.value as T;
  }

  /// Cancels the future while it is still pending.
  void cancel() {
    _state.cancel();
  }

  /// Drops this endpoint.
  void drop() {
    _state.dropReadable();
  }
}

/// Writable endpoint for [WASIComponentFuture].
final class WASIComponentWritableFuture<T extends Object> {
  const WASIComponentWritableFuture._(this._state);

  final _WASIComponentFutureState<T> _state;

  /// Whether the future has been completed.
  bool get isCompleted => _state.isReady;

  /// Whether the future has been cancelled.
  bool get isCancelled => _state.isCancelled;

  /// Whether this endpoint has been dropped.
  bool get isDropped => _state.writeDropped;

  /// Completes the future exactly once.
  void complete(T value) {
    _state.complete(value);
  }

  /// Cancels the future while it is still pending.
  void cancel() {
    _state.cancel();
  }

  /// Drops this endpoint.
  void drop() {
    _state.dropWritable();
  }
}

final class _WASIComponentStreamState<T extends Object> {
  _WASIComponentStreamState(this.name, this.onDrop);

  final String name;
  final void Function()? onDrop;
  final Queue<T> queue = ListQueue<T>();

  bool readCancelled = false;
  bool writeCancelled = false;
  bool readDropped = false;
  bool writeDropped = false;
  bool writeClosed = false;
  bool _dropCalled = false;

  bool get isDropped => readDropped && writeDropped;

  void requireReadable() {
    if (readDropped) {
      throw StateError('WASI component stream $name readable was dropped.');
    }
    if (readCancelled) {
      throw StateError('WASI component stream $name reads were cancelled.');
    }
  }

  void requireWritable() {
    if (writeDropped) {
      throw StateError('WASI component stream $name writable was dropped.');
    }
    if (writeClosed) {
      throw StateError('WASI component stream $name writable is closed.');
    }
    if (writeCancelled) {
      throw StateError('WASI component stream $name writes were cancelled.');
    }
    if (readDropped || readCancelled) {
      throw StateError('WASI component stream $name readable is closed.');
    }
  }

  void closeWrite() {
    if (writeDropped) {
      throw StateError('WASI component stream $name writable was dropped.');
    }
    writeClosed = true;
  }

  void cancelRead() {
    if (readDropped) {
      throw StateError('WASI component stream $name readable was dropped.');
    }
    readCancelled = true;
    writeClosed = true;
    queue.clear();
  }

  void cancelWrite() {
    if (writeDropped) {
      throw StateError('WASI component stream $name writable was dropped.');
    }
    writeCancelled = true;
    writeClosed = true;
  }

  void dropReadable() {
    if (readDropped) {
      return;
    }
    readDropped = true;
    queue.clear();
    _maybeDrop();
  }

  void dropWritable() {
    if (writeDropped) {
      return;
    }
    writeDropped = true;
    writeClosed = true;
    _maybeDrop();
  }

  void _maybeDrop() {
    if (!_dropCalled && isDropped) {
      _dropCalled = true;
      onDrop?.call();
    }
  }
}

enum _WASIComponentFutureStatus { pending, ready, cancelled }

final class _WASIComponentFutureState<T extends Object> {
  _WASIComponentFutureState(this.name, this.onDrop);

  final String name;
  final void Function()? onDrop;

  _WASIComponentFutureStatus status = _WASIComponentFutureStatus.pending;
  T? value;
  bool readDropped = false;
  bool writeDropped = false;
  bool _dropCalled = false;

  bool get isReady => status == _WASIComponentFutureStatus.ready;

  bool get isCancelled => status == _WASIComponentFutureStatus.cancelled;

  bool get isDropped => readDropped && writeDropped;

  void requireReadable() {
    if (readDropped) {
      throw StateError('WASI component future $name readable was dropped.');
    }
    if (isCancelled) {
      throw StateError('WASI component future $name was cancelled.');
    }
  }

  void complete(T completedValue) {
    if (writeDropped) {
      throw StateError('WASI component future $name writable was dropped.');
    }
    if (readDropped) {
      throw StateError('WASI component future $name readable was dropped.');
    }
    if (status != _WASIComponentFutureStatus.pending) {
      throw StateError('WASI component future $name is not pending.');
    }
    value = completedValue;
    status = _WASIComponentFutureStatus.ready;
  }

  void cancel() {
    if (status != _WASIComponentFutureStatus.pending) {
      throw StateError('WASI component future $name is not pending.');
    }
    status = _WASIComponentFutureStatus.cancelled;
  }

  void dropReadable() {
    if (readDropped) {
      return;
    }
    readDropped = true;
    _maybeDrop();
  }

  void dropWritable() {
    if (writeDropped) {
      return;
    }
    writeDropped = true;
    _maybeDrop();
  }

  void _maybeDrop() {
    if (!_dropCalled && isDropped) {
      _dropCalled = true;
      onDrop?.call();
    }
  }
}
