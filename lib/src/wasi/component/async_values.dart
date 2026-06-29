import 'dart:async';
import 'dart:collection';

/// Async endpoint failure category used by canonical copy event mapping.
enum WASIComponentAsyncEndpointFailure {
  /// A dropped endpoint ended the copy, so no more progress is possible.
  dropped,

  /// The active copy was cancelled by the same endpoint.
  cancelled,
}

/// State error carrying the canonical async endpoint failure kind.
final class WASIComponentAsyncEndpointStateError extends StateError {
  /// Creates an endpoint state error with a canonical [failure].
  WASIComponentAsyncEndpointStateError(this.failure, String message)
    : super(message);

  /// Canonical async endpoint failure kind.
  final WASIComponentAsyncEndpointFailure failure;
}

/// In-memory runtime state for a Component Model `stream<T>` value.
///
/// This host-side primitive models readable and writable endpoints separately
/// so canonical `stream.new`, `stream.read`, `stream.write`, cancellation, and
/// drop operations can be layered on top without mixing ownership rules into
/// the queue implementation.
final class WASIComponentStream<T> {
  /// Creates a stream with a debug [name].
  WASIComponentStream(
    String name, {
    int? maxBufferedElements,
    void Function()? onDrop,
  }) : _state = _WASIComponentStreamState<T>(
         name,
         onDrop,
         maxBufferedElements: maxBufferedElements,
       ) {
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

  /// Maximum queued values before writes apply backpressure.
  int? get maxBufferedElements => _state.maxBufferedElements;

  /// Whether both endpoints have been dropped.
  bool get isDropped => _state.isDropped;
}

/// Readable endpoint for [WASIComponentStream].
final class WASIComponentReadableStream<T> {
  const WASIComponentReadableStream._(this._state);

  final _WASIComponentStreamState<T> _state;

  /// Whether reads have been cancelled.
  bool get isCancelled => _state.readCancelled;

  /// Whether this endpoint has been dropped.
  bool get isDropped => _state.readDropped;

  /// Whether at least one value is currently queued for reading.
  bool get hasQueuedValues => _state.queue.isNotEmpty;

  /// Reads up to [maxElements] queued values.
  ///
  /// This is non-blocking: an empty list means no values are currently queued.
  List<T> read(int maxElements) {
    return _state.readQueued(maxElements);
  }

  /// Returns a Dart future that completes when values or stream closure arrive.
  ///
  /// Completion primitive used by WASI 0.3 async scheduling. The synchronous
  /// [read] API remains useful for polling already queued host-side canonical
  /// operations.
  Future<List<T>> readWhenAvailable(int maxElements) {
    return _state.readWhenAvailable(maxElements);
  }

  /// Forwards up to [maxElements] values into [writable].
  ///
  /// Already queued values are moved directly between stream queues. Pending
  /// source reads and bounded destination writes reuse the existing async
  /// wait primitives so forwarding follows the same cancellation, drop, and
  /// backpressure behavior as canonical read/write operations. [chunkSize]
  /// bounds fallback buffering when the source has no queued values yet.
  Future<int> forwardTo(
    WASIComponentWritableStream<T> writable,
    int maxElements, {
    int chunkSize = 1,
  }) {
    return _state.forwardTo(writable._state, maxElements, chunkSize: chunkSize);
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
final class WASIComponentWritableStream<T> {
  const WASIComponentWritableStream._(this._state);

  final _WASIComponentStreamState<T> _state;

  /// Whether no more writes are accepted.
  bool get isClosed => _state.writeClosed || _state.writeDropped;

  /// Whether writes have been cancelled.
  bool get isCancelled => _state.writeCancelled;

  /// Whether this endpoint has been dropped.
  bool get isDropped => _state.writeDropped;

  /// Whether [elementCount] values can be written without waiting.
  bool canWriteImmediately(int elementCount) {
    return _state.canWriteImmediately(elementCount);
  }

  /// Writes one value to the stream.
  void write(T value) {
    _state.write(value);
  }

  /// Writes all [values] to the stream.
  void writeAll(Iterable<T> values) {
    _state.writeAll(values);
  }

  /// Writes values once the stream has capacity.
  ///
  /// For bounded streams this may wait until reads free capacity and then
  /// complete with the number of values written. For unbounded streams it
  /// completes after writing every value.
  Future<int> writeWhenAvailable(Iterable<T> values) {
    return _state.writeWhenAvailable(values);
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
final class WASIComponentFuture<T> {
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
final class WASIComponentReadableFuture<T> {
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
    _state.markValueObserved();
    return _state.value as T;
  }

  /// Reads the value for a canonical future copy operation.
  T readForCopy() {
    return _state.readForCopy();
  }

  /// Returns a Dart future that completes when this component future is ready.
  ///
  /// Completion primitive used by WASI 0.3 async scheduling. The synchronous
  /// [read] API remains useful for already-ready host-side canonical
  /// operations.
  Future<T> readWhenReady() {
    return _state.readWhenReady();
  }

  /// Returns a Dart future copy result when this component future is ready.
  Future<T> readWhenReadyForCopy() {
    return _state.readWhenReadyForCopy();
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
final class WASIComponentWritableFuture<T> {
  const WASIComponentWritableFuture._(this._state);

  final _WASIComponentFutureState<T> _state;

  /// Whether the future has been completed.
  bool get isCompleted => _state.isReady;

  /// Whether a reader is currently waiting for this future.
  bool get hasPendingReader => _state.hasPendingReadWaiters;

  /// Whether this endpoint can still complete the future.
  bool get canComplete => _state.canComplete;

  /// Whether a completed value is waiting for the first reader observation.
  bool get hasPendingWriteDelivery => _state.hasPendingWriteDelivery;

  /// Whether the future has been cancelled.
  bool get isCancelled => _state.isCancelled;

  /// Whether this endpoint has been dropped.
  bool get isDropped => _state.writeDropped;

  /// Completes the future exactly once.
  void complete(T value) {
    _state.complete(value);
  }

  /// Completes the future for a canonical future copy operation.
  void completeForCopy(T value) {
    _state.completeForCopy(value);
  }

  /// Completes the future and waits until a reader observes the value.
  Future<void> completeWhenRead(T value) {
    return _state.completeWhenRead(value);
  }

  /// Completes a canonical future copy after a reader observes the value.
  Future<void> completeWhenReadForCopy(T value) {
    return _state.completeWhenReadForCopy(value);
  }

  /// Cancels the future while it is still pending.
  void cancel() {
    _state.cancel();
  }

  /// Cancels an active write delivery copy.
  void cancelWriteDelivery() {
    _state.cancelWriteDelivery();
  }

  /// Drops this endpoint.
  void drop() {
    _state.dropWritable();
  }
}

final class _WASIComponentStreamState<T> {
  _WASIComponentStreamState(this.name, this.onDrop, {int? maxBufferedElements})
    : maxBufferedElements = _validateMaxBufferedElements(maxBufferedElements);

  final String name;
  final void Function()? onDrop;
  final int? maxBufferedElements;
  final Queue<T> queue = ListQueue<T>();
  Queue<_WASIComponentStreamReadWaiter<T>>? readWaiters;
  Queue<_WASIComponentStreamWriteWaiter<T>>? writeWaiters;
  Queue<_WASIComponentStreamCapacityWaiter>? writeCapacityWaiters;

  bool readCancelled = false;
  bool writeCancelled = false;
  bool readDropped = false;
  bool writeDropped = false;
  bool writeClosed = false;
  bool _dropCalled = false;
  bool _pumpingWaiters = false;

  bool get isDropped => readDropped && writeDropped;

  List<T> readQueued(int maxElements) {
    requireReadable();
    RangeError.checkNotNegative(maxElements, 'maxElements');
    if (maxElements == 0 || queue.isEmpty) {
      return <T>[];
    }

    final values = _removeQueued(maxElements);
    if (writeWaiters != null || writeCapacityWaiters != null) {
      _pumpWaiters();
    }
    return values;
  }

  Future<List<T>> readWhenAvailable(int maxElements) {
    requireReadable();
    RangeError.checkNotNegative(maxElements, 'maxElements');
    if (maxElements == 0) {
      return Future<List<T>>.value(<T>[]);
    }
    if (queue.isNotEmpty) {
      final values = _removeQueued(maxElements);
      if (writeWaiters != null || writeCapacityWaiters != null) {
        _pumpWaiters();
      }
      return Future<List<T>>.value(values);
    }
    if (writeClosed) {
      return Future<List<T>>.value(<T>[]);
    }

    final completer = Completer<List<T>>();
    (readWaiters ??= ListQueue<_WASIComponentStreamReadWaiter<T>>()).addLast(
      _WASIComponentStreamReadWaiter<T>(maxElements, completer),
    );
    return completer.future;
  }

  bool canWriteImmediately(int elementCount) {
    RangeError.checkNotNegative(elementCount, 'elementCount');
    final available = _availableWriteCapacity;
    return available == null || elementCount <= available;
  }

  void write(T value) {
    requireWritable();
    if (maxBufferedElements == null &&
        readWaiters == null &&
        writeWaiters == null) {
      queue.addLast(value);
      return;
    }
    writeAll(<T>[value]);
  }

  void writeAll(Iterable<T> values) {
    requireWritable();
    if (maxBufferedElements == null &&
        readWaiters == null &&
        writeWaiters == null) {
      queue.addAll(values);
      return;
    }

    final bufferedValues = _materialize(values);
    if (bufferedValues.isEmpty) {
      return;
    }
    final available = _availableWriteCapacity;
    if (available != null && bufferedValues.length > available) {
      throw StateError(
        'WASI component stream $name writable has insufficient capacity.',
      );
    }

    _appendValues(bufferedValues, bufferedValues.length);
    if (readWaiters != null || writeWaiters != null) {
      _pumpWaiters();
    }
  }

  Future<int> writeWhenAvailable(Iterable<T> values) {
    requireWritable();
    final bufferedValues = _materialize(values);
    if (bufferedValues.isEmpty) {
      return Future<int>.value(0);
    }

    final written = _writeAvailable(bufferedValues);
    if (written != 0 || maxBufferedElements == null) {
      return Future<int>.value(written);
    }

    final completer = Completer<int>();
    (writeWaiters ??= ListQueue<_WASIComponentStreamWriteWaiter<T>>()).addLast(
      _WASIComponentStreamWriteWaiter<T>(bufferedValues, completer),
    );
    return completer.future;
  }

  Future<int> forwardTo(
    _WASIComponentStreamState<T> target,
    int maxElements, {
    required int chunkSize,
  }) async {
    requireReadable();
    target.requireWritable();
    RangeError.checkNotNegative(maxElements, 'maxElements');
    if (chunkSize <= 0) {
      throw RangeError.range(chunkSize, 1, null, 'chunkSize');
    }
    if (identical(this, target)) {
      throw StateError('WASI component stream $name cannot forward to itself.');
    }
    if (maxElements == 0) {
      return 0;
    }

    var forwarded = 0;
    while (forwarded < maxElements) {
      requireReadable();
      target.requireWritable();

      final moved = _moveQueuedValuesTo(target, maxElements - forwarded);
      if (moved != 0) {
        forwarded += moved;
        continue;
      }
      if (writeClosed) {
        return forwarded;
      }

      if (queue.isEmpty) {
        final values = await readWhenAvailable(
          _minInt(chunkSize, maxElements - forwarded),
        );
        if (values.isEmpty) {
          return forwarded;
        }
        forwarded += await target._writeAllWhenAvailable(values);
        continue;
      }

      await target._waitForWriteCapacity();
    }
    return forwarded;
  }

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
    if (writeWaiters != null) {
      _failWriteWaiters(
        StateError('WASI component stream $name writable is closed.'),
      );
    }
    if (writeCapacityWaiters != null) {
      _failWriteCapacityWaiters(
        StateError('WASI component stream $name writable is closed.'),
      );
    }
    if (readWaiters != null) {
      _pumpWaiters();
    }
  }

  void cancelRead() {
    if (readDropped) {
      throw StateError('WASI component stream $name readable was dropped.');
    }
    readCancelled = true;
    writeClosed = true;
    queue.clear();
    if (readWaiters != null) {
      _failReadWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.cancelled,
          'WASI component stream $name reads were cancelled.',
        ),
      );
    }
    if (writeWaiters != null) {
      _failWriteWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.dropped,
          'WASI component stream $name readable is closed.',
        ),
      );
    }
    if (writeCapacityWaiters != null) {
      _failWriteCapacityWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.dropped,
          'WASI component stream $name readable is closed.',
        ),
      );
    }
  }

  void cancelWrite() {
    if (writeDropped) {
      throw StateError('WASI component stream $name writable was dropped.');
    }
    writeCancelled = true;
    writeClosed = true;
    if (writeWaiters != null) {
      _failWriteWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.cancelled,
          'WASI component stream $name writes were cancelled.',
        ),
      );
    }
    if (writeCapacityWaiters != null) {
      _failWriteCapacityWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.cancelled,
          'WASI component stream $name writes were cancelled.',
        ),
      );
    }
    if (readWaiters != null) {
      _pumpWaiters();
    }
  }

  void dropReadable() {
    if (readDropped) {
      return;
    }
    readDropped = true;
    queue.clear();
    if (readWaiters != null) {
      _failReadWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.dropped,
          'WASI component stream $name readable was dropped.',
        ),
      );
    }
    if (writeWaiters != null) {
      _failWriteWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.dropped,
          'WASI component stream $name readable is closed.',
        ),
      );
    }
    if (writeCapacityWaiters != null) {
      _failWriteCapacityWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.dropped,
          'WASI component stream $name readable is closed.',
        ),
      );
    }
    _maybeDrop();
  }

  void dropWritable() {
    if (writeDropped) {
      return;
    }
    writeDropped = true;
    writeClosed = true;
    if (writeWaiters != null) {
      _failWriteWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.dropped,
          'WASI component stream $name writable was dropped.',
        ),
      );
    }
    if (writeCapacityWaiters != null) {
      _failWriteCapacityWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.dropped,
          'WASI component stream $name writable was dropped.',
        ),
      );
    }
    if (readWaiters != null) {
      _pumpWaiters();
    }
    _maybeDrop();
  }

  List<T> _removeQueued(int maxElements) {
    final available = queue.length;
    final count = maxElements < available ? maxElements : available;
    return List<T>.generate(count, (_) => queue.removeFirst());
  }

  List<T> _materialize(Iterable<T> values) {
    return values is List<T> ? values : List<T>.of(values);
  }

  int? get _availableWriteCapacity {
    final maxBufferedElements = this.maxBufferedElements;
    if (maxBufferedElements == null) {
      return null;
    }
    final available = maxBufferedElements - queue.length;
    return available < 0 ? 0 : available;
  }

  int _writeAvailable(List<T> values) {
    if (values.isEmpty) {
      return 0;
    }
    final available = _availableWriteCapacity;
    final count = available == null
        ? values.length
        : values.length < available
        ? values.length
        : available;
    if (count == 0) {
      return 0;
    }

    _appendValues(values, count);
    if (readWaiters != null || writeWaiters != null) {
      _pumpWaiters();
    }
    return count;
  }

  void _appendValues(List<T> values, int count) {
    for (var i = 0; i < count; i++) {
      queue.addLast(values[i]);
    }
  }

  int _moveQueuedValuesTo(
    _WASIComponentStreamState<T> target,
    int maxElements,
  ) {
    if (maxElements == 0 || queue.isEmpty) {
      return 0;
    }
    final targetCapacity = target._availableWriteCapacity;
    if (targetCapacity != null && targetCapacity == 0) {
      return 0;
    }

    final count = _minInt(
      maxElements,
      _minInt(queue.length, targetCapacity ?? maxElements),
    );
    for (var i = 0; i < count; i++) {
      target.queue.addLast(queue.removeFirst());
    }
    if (writeWaiters != null || writeCapacityWaiters != null) {
      _pumpWaiters();
    }
    if (target.readWaiters != null || target.writeWaiters != null) {
      target._pumpWaiters();
    }
    return count;
  }

  Future<int> _writeAllWhenAvailable(List<T> values) async {
    var written = 0;
    while (written < values.length) {
      final count = await writeWhenAvailable(values.sublist(written));
      if (count <= 0) {
        throw StateError(
          'WASI component stream $name writable made no progress.',
        );
      }
      written += count;
    }
    return written;
  }

  Future<void> _waitForWriteCapacity() {
    requireWritable();
    final available = _availableWriteCapacity;
    if (available == null || available > 0) {
      return Future<void>.value();
    }

    final completer = Completer<void>();
    (writeCapacityWaiters ??= ListQueue<_WASIComponentStreamCapacityWaiter>())
        .addLast(_WASIComponentStreamCapacityWaiter(completer));
    return completer.future;
  }

  void _pumpWaiters() {
    if (_pumpingWaiters) {
      return;
    }
    _pumpingWaiters = true;
    try {
      var progressed = true;
      while (progressed) {
        progressed = _completeReadyReadWaiters();
        progressed = _completeReadyWriteWaiters() || progressed;
        progressed = _completeReadyWriteCapacityWaiters() || progressed;
      }
    } finally {
      _pumpingWaiters = false;
    }
  }

  bool _completeReadyReadWaiters() {
    final waiters = readWaiters;
    if (waiters == null || waiters.isEmpty) {
      return false;
    }

    var progressed = false;
    while (waiters.isNotEmpty) {
      final waiter = waiters.first;
      if (queue.isNotEmpty) {
        waiters.removeFirst();
        waiter.complete(_removeQueued(waiter.maxElements));
        progressed = true;
      } else if (writeDropped) {
        waiters.removeFirst();
        waiter.fail(
          WASIComponentAsyncEndpointStateError(
            WASIComponentAsyncEndpointFailure.dropped,
            'WASI component stream $name writable was dropped.',
          ),
        );
        progressed = true;
      } else if (writeClosed) {
        waiters.removeFirst();
        waiter.complete(<T>[]);
        progressed = true;
      } else {
        break;
      }
    }

    if (waiters.isEmpty) {
      readWaiters = null;
    }
    return progressed;
  }

  bool _completeReadyWriteWaiters() {
    final waiters = writeWaiters;
    if (waiters == null || waiters.isEmpty || writeClosed) {
      return false;
    }

    var progressed = false;
    while (waiters.isNotEmpty) {
      final available = _availableWriteCapacity;
      if (available != null && available == 0) {
        break;
      }
      final waiter = waiters.removeFirst();
      final written = _writeAvailable(waiter.values);
      waiter.complete(written);
      progressed = true;
    }

    if (waiters.isEmpty) {
      writeWaiters = null;
    }
    return progressed;
  }

  bool _completeReadyWriteCapacityWaiters() {
    final waiters = writeCapacityWaiters;
    if (waiters == null || waiters.isEmpty || writeClosed) {
      return false;
    }
    final available = _availableWriteCapacity;
    if (available != null && available == 0) {
      return false;
    }

    writeCapacityWaiters = null;
    for (final waiter in waiters) {
      waiter.complete();
    }
    return true;
  }

  void _failReadWaiters(Object error) {
    final waiters = readWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    readWaiters = null;
    for (final waiter in waiters) {
      waiter.fail(error);
    }
  }

  void _failWriteWaiters(Object error) {
    final waiters = writeWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    writeWaiters = null;
    for (final waiter in waiters) {
      waiter.fail(error);
    }
  }

  void _failWriteCapacityWaiters(Object error) {
    final waiters = writeCapacityWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    writeCapacityWaiters = null;
    for (final waiter in waiters) {
      waiter.fail(error);
    }
  }

  void _maybeDrop() {
    if (!_dropCalled && isDropped) {
      _dropCalled = true;
      onDrop?.call();
    }
  }
}

int? _validateMaxBufferedElements(int? maxBufferedElements) {
  if (maxBufferedElements == null || maxBufferedElements > 0) {
    return maxBufferedElements;
  }
  throw RangeError.range(maxBufferedElements, 1, null, 'maxBufferedElements');
}

int _minInt(int left, int right) {
  return left < right ? left : right;
}

final class _WASIComponentStreamReadWaiter<T> {
  const _WASIComponentStreamReadWaiter(this.maxElements, this.completer);

  final int maxElements;
  final Completer<List<T>> completer;

  void complete(List<T> values) {
    if (!completer.isCompleted) {
      completer.complete(values);
    }
  }

  void fail(Object error) {
    if (!completer.isCompleted) {
      completer.completeError(error);
    }
  }
}

final class _WASIComponentStreamWriteWaiter<T> {
  const _WASIComponentStreamWriteWaiter(this.values, this.completer);

  final List<T> values;
  final Completer<int> completer;

  void complete(int count) {
    if (!completer.isCompleted) {
      completer.complete(count);
    }
  }

  void fail(Object error) {
    if (!completer.isCompleted) {
      completer.completeError(error);
    }
  }
}

final class _WASIComponentStreamCapacityWaiter {
  const _WASIComponentStreamCapacityWaiter(this.completer);

  final Completer<void> completer;

  void complete() {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  void fail(Object error) {
    if (!completer.isCompleted) {
      completer.completeError(error);
    }
  }
}

enum _WASIComponentFutureStatus { pending, ready, cancelled }

enum _WASIComponentFutureCopyStatus { idle, copying, done }

final class _WASIComponentFutureState<T> {
  _WASIComponentFutureState(this.name, this.onDrop);

  final String name;
  final void Function()? onDrop;

  _WASIComponentFutureStatus status = _WASIComponentFutureStatus.pending;
  T? value;
  List<Completer<T>>? readWaiters;
  List<Completer<void>>? writeDeliveryWaiters;
  bool readDropped = false;
  bool writeDropped = false;
  bool _dropCalled = false;
  bool _valueObserved = false;
  _WASIComponentFutureCopyStatus _readCopyStatus =
      _WASIComponentFutureCopyStatus.idle;
  _WASIComponentFutureCopyStatus _writeCopyStatus =
      _WASIComponentFutureCopyStatus.idle;

  bool get isReady => status == _WASIComponentFutureStatus.ready;

  bool get isCancelled => status == _WASIComponentFutureStatus.cancelled;

  bool get isDropped => readDropped && writeDropped;

  bool get hasPendingReadWaiters =>
      readWaiters != null && readWaiters!.isNotEmpty;

  bool get hasPendingWriteDelivery =>
      writeDeliveryWaiters != null && writeDeliveryWaiters!.isNotEmpty;

  bool get canComplete =>
      status == _WASIComponentFutureStatus.pending &&
      !readDropped &&
      !writeDropped;

  void requireReadable() {
    if (readDropped) {
      throw StateError('WASI component future $name readable was dropped.');
    }
    if (isCancelled) {
      throw StateError('WASI component future $name was cancelled.');
    }
  }

  Future<T> readWhenReady() {
    requireReadable();
    if (isReady) {
      markValueObserved();
      return Future<T>.value(value as T);
    }

    final completer = Completer<T>();
    (readWaiters ??= <Completer<T>>[]).add(completer);
    return completer.future;
  }

  T readForCopy() {
    _beginReadCopy();
    try {
      requireReadable();
      if (!isReady) {
        throw StateError('WASI component future $name is not ready.');
      }
      markValueObserved();
      _readCopyStatus = _WASIComponentFutureCopyStatus.done;
      return value as T;
    } catch (_) {
      _resetReadCopy();
      rethrow;
    }
  }

  Future<T> readWhenReadyForCopy() {
    _beginReadCopy();
    try {
      return readWhenReady().then(
        (value) {
          _readCopyStatus = _WASIComponentFutureCopyStatus.done;
          return value;
        },
        onError: (Object error, StackTrace stackTrace) {
          _resetReadCopy();
          Error.throwWithStackTrace(error, stackTrace);
        },
      );
    } catch (_) {
      _resetReadCopy();
      rethrow;
    }
  }

  void complete(T completedValue) {
    if (writeDropped) {
      throw StateError('WASI component future $name writable was dropped.');
    }
    if (readDropped) {
      throw WASIComponentAsyncEndpointStateError(
        WASIComponentAsyncEndpointFailure.dropped,
        'WASI component future $name readable was dropped.',
      );
    }
    if (status != _WASIComponentFutureStatus.pending) {
      throw StateError('WASI component future $name is not pending.');
    }
    value = completedValue;
    status = _WASIComponentFutureStatus.ready;
    if (readWaiters != null) {
      _completeReadWaiters(completedValue);
    }
  }

  void completeForCopy(T completedValue) {
    _beginWriteCopy();
    try {
      complete(completedValue);
      _writeCopyStatus = _WASIComponentFutureCopyStatus.done;
    } catch (_) {
      _resetWriteCopy();
      rethrow;
    }
  }

  Future<void> completeWhenRead(T completedValue) {
    complete(completedValue);
    if (_valueObserved) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    (writeDeliveryWaiters ??= <Completer<void>>[]).add(completer);
    return completer.future;
  }

  Future<void> completeWhenReadForCopy(T completedValue) {
    _beginWriteCopy();
    try {
      return completeWhenRead(completedValue).then(
        (_) {
          _writeCopyStatus = _WASIComponentFutureCopyStatus.done;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (error is WASIComponentAsyncEndpointStateError &&
              error.failure == WASIComponentAsyncEndpointFailure.dropped) {
            _writeCopyStatus = _WASIComponentFutureCopyStatus.done;
          } else {
            _resetWriteCopy();
          }
          Error.throwWithStackTrace(error, stackTrace);
        },
      );
    } catch (_) {
      _resetWriteCopy();
      rethrow;
    }
  }

  void cancel() {
    if (status != _WASIComponentFutureStatus.pending) {
      throw StateError('WASI component future $name is not pending.');
    }
    status = _WASIComponentFutureStatus.cancelled;
    if (readWaiters != null) {
      _failReadWaiters(
        StateError('WASI component future $name was cancelled.'),
      );
    }
    if (writeDeliveryWaiters != null) {
      _failWriteDeliveryWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.cancelled,
          'WASI component future $name was cancelled.',
        ),
      );
    }
  }

  void cancelWriteDelivery() {
    if (!hasPendingWriteDelivery) {
      cancel();
      return;
    }
    status = _WASIComponentFutureStatus.cancelled;
    value = null;
    _failWriteDeliveryWaiters(
      WASIComponentAsyncEndpointStateError(
        WASIComponentAsyncEndpointFailure.cancelled,
        'WASI component future $name write was cancelled.',
      ),
    );
  }

  void dropReadable() {
    if (readDropped) {
      return;
    }
    readDropped = true;
    if (readWaiters != null) {
      _failReadWaiters(
        StateError('WASI component future $name readable was dropped.'),
      );
    }
    if (writeDeliveryWaiters != null) {
      _failWriteDeliveryWaiters(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.dropped,
          'WASI component future $name readable was dropped.',
        ),
      );
    }
    _maybeDrop();
  }

  void dropWritable() {
    if (writeDropped) {
      return;
    }
    writeDropped = true;
    if (status == _WASIComponentFutureStatus.pending) {
      status = _WASIComponentFutureStatus.cancelled;
      if (readWaiters != null) {
        _failReadWaiters(
          StateError('WASI component future $name writable was dropped.'),
        );
      }
    }
    _maybeDrop();
  }

  void _completeReadWaiters(T completedValue) {
    final waiters = readWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    readWaiters = null;
    markValueObserved();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(completedValue);
      }
    }
  }

  void markValueObserved() {
    if (_valueObserved) {
      return;
    }
    _valueObserved = true;
    final waiters = writeDeliveryWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    writeDeliveryWaiters = null;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  void _failReadWaiters(Object error) {
    final waiters = readWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    readWaiters = null;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(error);
      }
    }
  }

  void _failWriteDeliveryWaiters(Object error) {
    final waiters = writeDeliveryWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    writeDeliveryWaiters = null;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(error);
      }
    }
  }

  void _maybeDrop() {
    if (!_dropCalled && isDropped) {
      _dropCalled = true;
      onDrop?.call();
    }
  }

  void _beginReadCopy() {
    _requireCopyIdle(_readCopyStatus, 'readable');
    _readCopyStatus = _WASIComponentFutureCopyStatus.copying;
  }

  void _beginWriteCopy() {
    _requireCopyIdle(_writeCopyStatus, 'writable');
    _writeCopyStatus = _WASIComponentFutureCopyStatus.copying;
  }

  void _resetReadCopy() {
    if (_readCopyStatus == _WASIComponentFutureCopyStatus.copying) {
      _readCopyStatus = _WASIComponentFutureCopyStatus.idle;
    }
  }

  void _resetWriteCopy() {
    if (_writeCopyStatus == _WASIComponentFutureCopyStatus.copying) {
      _writeCopyStatus = _WASIComponentFutureCopyStatus.idle;
    }
  }

  void _requireCopyIdle(
    _WASIComponentFutureCopyStatus status,
    String endpoint,
  ) {
    switch (status) {
      case _WASIComponentFutureCopyStatus.idle:
        return;
      case _WASIComponentFutureCopyStatus.copying:
        throw StateError(
          'WASI component future $name $endpoint copy is already active.',
        );
      case _WASIComponentFutureCopyStatus.done:
        throw StateError('WASI component future $name $endpoint copy is done.');
    }
  }
}
