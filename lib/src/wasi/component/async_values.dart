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
    void Function()? onReadableDrop,
    void Function(T value)? onDiscard,
  }) : _state = _WASIComponentStreamState<T>(
         name,
         onDrop,
         onReadableDrop,
         onDiscard,
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

  /// Whether the writable end is closed and no buffered values remain.
  bool get isEndOfStream =>
      _state.writeClosed && !_state.writeCancelled && _state.queue.isEmpty;

  /// Reads up to [maxElements] queued values.
  ///
  /// This is non-blocking: an empty list means no values are currently queued.
  List<T> read(int maxElements) {
    return _state.readQueued(maxElements);
  }

  /// Reads values as one canonical stream copy.
  List<T> readForCopy(int maxElements) {
    return _state.readQueuedForCopy(maxElements);
  }

  /// Returns a Dart future that completes when values or stream closure arrive.
  ///
  /// Completion primitive used by WASI 0.3 async scheduling. The synchronous
  /// [read] API remains useful for polling already queued host-side canonical
  /// operations.
  Future<List<T>> readWhenAvailable(int maxElements) {
    return _state.readWhenAvailable(maxElements);
  }

  /// Waits for one canonical stream copy.
  Future<List<T>> readWhenAvailableForCopy(
    int maxElements, {
    bool asynchronous = true,
    bool deferCompletion = false,
  }) {
    return _state.readWhenAvailableForCopy(
      maxElements,
      asynchronous: asynchronous,
      deferCompletion: deferCompletion,
    );
  }

  /// Cancels the currently pending read copy without closing this endpoint.
  void cancelPendingCopy() {
    _state.cancelPendingReadCopy();
  }

  /// Marks an asynchronous read copy as being cancelled.
  void requestCopyCancellation() {
    _state.requestReadCopyCancellation();
  }

  /// Cancels the underlying pending read after cancellation was requested.
  void cancelRequestedCopy() {
    _state.cancelRequestedReadCopy();
  }

  /// Applies the result when a deferred copy event is delivered.
  void finishDeferredCopy({required bool dropped}) {
    _state.finishReadCopy(dropped: dropped);
  }

  /// Validates that this endpoint may be dropped or transferred.
  void requireDroppable() {
    _state.requireReadCopyDroppable();
  }

  /// Validates that a new canonical copy may start.
  void requireCopyIdle() {
    _state.requireReadCopyIdle();
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

  /// Cancels future reads, discards queued values, and consumes this endpoint.
  void cancel() {
    _state.cancelReadableFromHost();
  }

  /// Drops this endpoint.
  void drop() {
    _state.dropReadable();
  }

  /// Force-releases this host-owned endpoint during resource teardown.
  ///
  /// Canonical guest operations must use [drop] so copy-state checks still run.
  void dispose() {
    _state.disposeReadable();
  }
}

/// Writable endpoint for [WASIComponentStream].
final class WASIComponentWritableStream<T> {
  const WASIComponentWritableStream._(this._state);

  final _WASIComponentStreamState<T> _state;

  /// Whether no more writes are accepted.
  bool get isClosed =>
      _state.writeClosed ||
      _state.writeDropped ||
      _state.writeCancelled ||
      _state.readDropped ||
      _state.readCancelled;

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

  /// Writes values as one canonical stream copy.
  int writeAllForCopy(Iterable<T> values) {
    return _state.writeAllForCopy(values);
  }

  /// Writes values once the stream has capacity.
  ///
  /// For bounded streams this may wait until reads free capacity and then
  /// complete with the number of values written. For unbounded streams it
  /// completes after writing every value.
  Future<int> writeWhenAvailable(Iterable<T> values) {
    return _state.writeWhenAvailable(values);
  }

  /// Waits for one canonical stream write copy.
  Future<int> writeWhenAvailableForCopy(
    Iterable<T> values, {
    bool asynchronous = true,
    bool deferCompletion = false,
  }) {
    return _state.writeWhenAvailableForCopy(
      values,
      asynchronous: asynchronous,
      deferCompletion: deferCompletion,
    );
  }

  /// Cancels the currently pending write copy without closing this endpoint.
  void cancelPendingCopy() {
    _state.cancelPendingWriteCopy();
  }

  /// Marks an asynchronous write copy as being cancelled.
  void requestCopyCancellation() {
    _state.requestWriteCopyCancellation();
  }

  /// Cancels the underlying pending write after cancellation was requested.
  void cancelRequestedCopy() {
    _state.cancelRequestedWriteCopy();
  }

  /// Applies the result when a deferred copy event is delivered.
  void finishDeferredCopy({required bool dropped}) {
    _state.finishWriteCopy(dropped: dropped);
  }

  /// Validates that this endpoint may be dropped or transferred.
  void requireDroppable() {
    _state.requireWriteCopyDroppable();
  }

  /// Validates that a new canonical copy may start.
  void requireCopyIdle() {
    _state.requireWriteCopyIdle();
  }

  /// Gracefully closes and consumes this host-owned producer endpoint.
  void close() {
    _state.closeWritableFromHost();
  }

  /// Cancels future writes and consumes this host-owned producer endpoint.
  void cancel() {
    _state.cancelWritableFromHost();
  }

  /// Drops this endpoint.
  void drop() {
    _state.dropWritable();
  }

  /// Force-releases this host-owned endpoint during resource teardown.
  ///
  /// Canonical guest operations must use [drop] so copy-state checks still run.
  void dispose() {
    _state.disposeWritable();
  }
}

/// In-memory runtime state for a Component Model `future<T>` value.
final class WASIComponentFuture<T> {
  /// Creates a future with a debug [name].
  WASIComponentFuture(
    String name, {
    void Function()? onDrop,
    void Function(T value)? onDiscard,
  }) : _state = _WASIComponentFutureState<T>(name, onDrop, onDiscard) {
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
    return _state.readForCopy();
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
    return _state.readWhenReadyForCopy();
  }

  /// Returns a Dart future copy result when this component future is ready.
  Future<T> readWhenReadyForCopy({
    bool asynchronous = true,
    bool deferCompletion = false,
  }) {
    return _state.readWhenReadyForCopy(
      asynchronous: asynchronous,
      deferCompletion: deferCompletion,
    );
  }

  /// Cancels the currently pending read copy without closing this endpoint.
  void cancelPendingCopy() {
    _state.cancelPendingReadCopy();
  }

  /// Marks an asynchronous read copy as being cancelled.
  void requestCopyCancellation() {
    _state.requestReadCopyCancellation();
  }

  /// Cancels the underlying pending read after cancellation was requested.
  void cancelRequestedCopy() {
    _state.cancelRequestedReadCopy();
  }

  /// Applies the result when a deferred copy event is delivered.
  void finishDeferredCopy({required bool cancelled}) {
    _state.finishReadCopy(cancelled: cancelled);
  }

  /// Validates that this endpoint may be dropped or transferred.
  void requireDroppable() {
    _state.requireReadCopyDroppable();
  }

  /// Validates that a new canonical copy may start.
  void requireCopyIdle() {
    _state.requireReadCopyIdle();
  }

  /// Cancels the future and consumes this host-owned readable endpoint.
  void cancel() {
    _state.cancelReadableFromHost();
  }

  /// Drops this endpoint.
  void drop() {
    _state.dropReadable();
  }

  /// Force-releases this host-owned endpoint during resource teardown.
  ///
  /// Canonical guest operations must use [drop] so copy-state checks still run.
  void dispose() {
    _state.disposeReadable();
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

  /// Completes the future and consumes this host-owned producer endpoint.
  ///
  /// Canonical guest writes use [completeForCopy] and retain the endpoint until
  /// the matching canonical drop operation.
  void complete(T value) {
    _state.completeFromHost(value);
  }

  /// Completes the future for a canonical future copy operation.
  void completeForCopy(T value) {
    _state.completeForCopy(value);
  }

  /// Completes the future, consumes this host-owned producer endpoint, and
  /// waits until a reader observes the value.
  Future<void> completeWhenRead(T value) {
    return _state.completeWhenReadFromHost(value);
  }

  /// Completes a canonical future copy after a reader observes the value.
  Future<void> completeWhenReadForCopy(
    T value, {
    bool asynchronous = true,
    bool deferCompletion = false,
  }) {
    return _state.completeWhenReadForCopy(
      value,
      asynchronous: asynchronous,
      deferCompletion: deferCompletion,
    );
  }

  /// Cancels the currently pending write copy without closing this endpoint.
  void cancelPendingCopy() {
    _state.cancelPendingWriteCopy();
  }

  /// Marks an asynchronous write copy as being cancelled.
  void requestCopyCancellation() {
    _state.requestWriteCopyCancellation();
  }

  /// Cancels the underlying pending write after cancellation was requested.
  void cancelRequestedCopy() {
    _state.cancelRequestedWriteCopy();
  }

  /// Applies the result when a deferred copy event is delivered.
  void finishDeferredCopy({required bool cancelled}) {
    _state.finishWriteCopy(cancelled: cancelled);
  }

  /// Cancels the future and consumes this host-owned producer endpoint.
  void cancel() {
    _state.cancelWritableFromHost();
  }

  /// Cancels an active write delivery copy.
  void cancelWriteDelivery() {
    _state.cancelWriteDelivery();
  }

  /// Drops this endpoint.
  void drop() {
    _state.dropWritable();
  }

  /// Force-releases this host-owned endpoint during resource teardown.
  ///
  /// Canonical guest operations must use [drop] so copy-state checks still run.
  void dispose() {
    _state.disposeWritable();
  }

  /// Validates that this writable future end may be dropped.
  void requireDroppable() {
    _state.requireWritableDroppable();
  }

  /// Validates that a new canonical copy may start.
  void requireCopyIdle() {
    _state.requireWriteCopyIdle();
  }
}

final class _WASIComponentStreamState<T> {
  _WASIComponentStreamState(
    this.name,
    this.onDrop,
    this.onReadableDrop,
    this.onDiscard, {
    int? maxBufferedElements,
  }) : maxBufferedElements = _validateMaxBufferedElements(maxBufferedElements);

  final String name;
  final void Function()? onDrop;
  final void Function()? onReadableDrop;
  final void Function(T value)? onDiscard;
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
  bool writeClosedGracefully = false;
  bool _dropCalled = false;
  bool _readableDropCalled = false;
  bool _pumpingWaiters = false;
  _WASIComponentAsyncCopyStatus _readCopyStatus =
      _WASIComponentAsyncCopyStatus.idle;
  _WASIComponentAsyncCopyStatus _writeCopyStatus =
      _WASIComponentAsyncCopyStatus.idle;
  bool _readCopyIsAsync = false;
  bool _writeCopyIsAsync = false;

  bool get isDropped => readDropped && writeDropped;

  List<T> readQueued(int maxElements) {
    requireReadable();
    RangeError.checkNotNegative(maxElements, 'maxElements');
    if (maxElements == 0) {
      return <T>[];
    }
    if (queue.isEmpty) {
      if (writeCancelled) {
        throw WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.cancelled,
          'WASI component stream $name writes were cancelled.',
        );
      }
      return <T>[];
    }

    final values = _removeQueued(maxElements);
    if (writeWaiters != null || writeCapacityWaiters != null) {
      _pumpWaiters();
    }
    return values;
  }

  List<T> readQueuedForCopy(int maxElements) {
    _beginReadCopy(asynchronous: false);
    try {
      final values = readQueued(maxElements);
      finishReadCopy(dropped: values.isEmpty && _readReachedDroppedEnd);
      return values;
    } catch (error) {
      _finishReadCopyError(error);
      rethrow;
    }
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
    if (writeCancelled) {
      return Future<List<T>>.error(
        WASIComponentAsyncEndpointStateError(
          WASIComponentAsyncEndpointFailure.cancelled,
          'WASI component stream $name writes were cancelled.',
        ),
      );
    }
    if (writeClosed) {
      return Future<List<T>>.value(<T>[]);
    }

    final completer = Completer<List<T>>();
    (readWaiters ??= ListQueue<_WASIComponentStreamReadWaiter<T>>()).addLast(
      _WASIComponentStreamReadWaiter<T>(maxElements, completer),
    );
    if (writeWaiters != null) {
      _pumpWaiters();
    }
    return completer.future;
  }

  Future<List<T>> readWhenAvailableForCopy(
    int maxElements, {
    required bool asynchronous,
    required bool deferCompletion,
  }) {
    _beginReadCopy(asynchronous: asynchronous);
    try {
      return readWhenAvailable(maxElements).then(
        (values) {
          if (!deferCompletion) {
            finishReadCopy(dropped: values.isEmpty && _readReachedDroppedEnd);
          }
          return values;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!deferCompletion) {
            _finishReadCopyError(error);
          }
          Error.throwWithStackTrace(error, stackTrace);
        },
      );
    } catch (error) {
      if (!deferCompletion) {
        _resetReadCopy();
      }
      rethrow;
    }
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

  int writeAllForCopy(Iterable<T> values) {
    final bufferedValues = _materialize(values);
    _beginWriteCopy(asynchronous: false);
    try {
      writeAll(bufferedValues);
      finishWriteCopy(dropped: false);
      return bufferedValues.length;
    } catch (error) {
      _finishWriteCopyError(error);
      rethrow;
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
    if (readWaiters != null) {
      _pumpWaiters();
    }
    return completer.future;
  }

  Future<int> writeWhenAvailableForCopy(
    Iterable<T> values, {
    required bool asynchronous,
    required bool deferCompletion,
  }) {
    final bufferedValues = _materialize(values);
    _beginWriteCopy(asynchronous: asynchronous);
    try {
      return writeWhenAvailable(bufferedValues).then(
        (written) {
          if (!deferCompletion) {
            finishWriteCopy(dropped: false);
          }
          return written;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!deferCompletion) {
            _finishWriteCopyError(error);
          }
          Error.throwWithStackTrace(error, stackTrace);
        },
      );
    } catch (error) {
      if (!deferCompletion) {
        _resetWriteCopy();
      }
      rethrow;
    }
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
    if (readDropped) {
      throw WASIComponentAsyncEndpointStateError(
        WASIComponentAsyncEndpointFailure.dropped,
        'WASI component stream $name readable is closed.',
      );
    }
    if (readCancelled) {
      throw WASIComponentAsyncEndpointStateError(
        WASIComponentAsyncEndpointFailure.cancelled,
        'WASI component stream $name reads were cancelled.',
      );
    }
  }

  void closeWrite() {
    if (writeDropped) {
      throw StateError('WASI component stream $name writable was dropped.');
    }
    writeClosed = true;
    writeClosedGracefully = true;
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

  void closeWritableFromHost() {
    try {
      closeWrite();
    } finally {
      disposeWritable();
    }
  }

  void cancelRead() {
    if (readDropped) {
      throw StateError('WASI component stream $name readable was dropped.');
    }
    readCancelled = true;
    writeClosed = true;
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

  void cancelReadableFromHost() {
    try {
      cancelRead();
    } finally {
      disposeReadable();
    }
  }

  void cancelPendingReadCopy() {
    requireReadable();
    final waiters = readWaiters;
    if (waiters == null || waiters.isEmpty) {
      throw StateError('WASI component stream $name has no pending read copy.');
    }
    requestReadCopyCancellation();
    cancelRequestedReadCopy();
  }

  void requestReadCopyCancellation() {
    _requestCopyCancellation(
      _readCopyStatus,
      _readCopyIsAsync,
      'readable',
      (status) => _readCopyStatus = status,
    );
  }

  void cancelRequestedReadCopy() {
    final waiters = readWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    final waiter = waiters.removeFirst();
    if (waiters.isEmpty) {
      readWaiters = null;
    }
    waiter.fail(
      WASIComponentAsyncEndpointStateError(
        WASIComponentAsyncEndpointFailure.cancelled,
        'WASI component stream $name read copy was cancelled.',
      ),
    );
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

  void cancelWritableFromHost() {
    try {
      cancelWrite();
    } finally {
      disposeWritable();
    }
  }

  void cancelPendingWriteCopy() {
    requireWritable();
    final waiters = writeWaiters;
    if (waiters == null || waiters.isEmpty) {
      throw StateError(
        'WASI component stream $name has no pending write copy.',
      );
    }
    requestWriteCopyCancellation();
    cancelRequestedWriteCopy();
  }

  void requestWriteCopyCancellation() {
    _requestCopyCancellation(
      _writeCopyStatus,
      _writeCopyIsAsync,
      'writable',
      (status) => _writeCopyStatus = status,
    );
  }

  void cancelRequestedWriteCopy() {
    final waiters = writeWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    final waiter = waiters.removeFirst();
    if (waiters.isEmpty) {
      writeWaiters = null;
    }
    waiter.fail(
      WASIComponentAsyncEndpointStateError(
        WASIComponentAsyncEndpointFailure.cancelled,
        'WASI component stream $name write copy was cancelled.',
      ),
    );
  }

  void dropReadable() {
    if (readDropped) {
      return;
    }
    requireReadCopyDroppable();
    disposeReadable();
  }

  void disposeReadable() {
    if (readDropped) {
      return;
    }
    _readCopyStatus = _WASIComponentAsyncCopyStatus.done;
    _readCopyIsAsync = false;
    readDropped = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    void cleanUp(void Function() action) {
      try {
        action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    cleanUp(_discardQueuedValues);
    cleanUp(() {
      if (readWaiters != null) {
        _failReadWaiters(
          WASIComponentAsyncEndpointStateError(
            WASIComponentAsyncEndpointFailure.dropped,
            'WASI component stream $name readable was dropped.',
          ),
        );
      }
    });
    cleanUp(() {
      if (writeWaiters != null) {
        _failWriteWaiters(
          WASIComponentAsyncEndpointStateError(
            WASIComponentAsyncEndpointFailure.dropped,
            'WASI component stream $name readable is closed.',
          ),
        );
      }
    });
    cleanUp(() {
      if (writeCapacityWaiters != null) {
        _failWriteCapacityWaiters(
          WASIComponentAsyncEndpointStateError(
            WASIComponentAsyncEndpointFailure.dropped,
            'WASI component stream $name readable is closed.',
          ),
        );
      }
    });
    cleanUp(() {
      if (!_readableDropCalled) {
        _readableDropCalled = true;
        onReadableDrop?.call();
      }
    });
    cleanUp(_maybeDrop);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  void dropWritable() {
    if (writeDropped) {
      return;
    }
    requireWriteCopyDroppable();
    disposeWritable();
  }

  void disposeWritable() {
    if (writeDropped) {
      return;
    }
    _writeCopyStatus = _WASIComponentAsyncCopyStatus.done;
    _writeCopyIsAsync = false;
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

  void _discardQueuedValues() {
    final discard = onDiscard;
    if (discard == null) {
      queue.clear();
      return;
    }
    Object? firstError;
    StackTrace? firstStackTrace;
    while (queue.isNotEmpty) {
      final value = queue.removeFirst();
      try {
        discard(value);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  bool get _readReachedDroppedEnd =>
      writeClosed && !writeCancelled && queue.isEmpty;

  void _beginReadCopy({required bool asynchronous}) {
    _requireCopyIdle(_readCopyStatus, 'readable');
    _readCopyStatus = _WASIComponentAsyncCopyStatus.copying;
    _readCopyIsAsync = asynchronous;
  }

  void _beginWriteCopy({required bool asynchronous}) {
    _requireCopyIdle(_writeCopyStatus, 'writable');
    _writeCopyStatus = _WASIComponentAsyncCopyStatus.copying;
    _writeCopyIsAsync = asynchronous;
  }

  void finishReadCopy({required bool dropped}) {
    if (readDropped) {
      return;
    }
    _finishCopy(
      _readCopyStatus,
      'readable',
      dropped,
      (status) => _readCopyStatus = status,
    );
    _readCopyIsAsync = false;
  }

  void finishWriteCopy({required bool dropped}) {
    if (writeDropped) {
      return;
    }
    _finishCopy(
      _writeCopyStatus,
      'writable',
      dropped,
      (status) => _writeCopyStatus = status,
    );
    _writeCopyIsAsync = false;
  }

  void _finishReadCopyError(Object error) {
    if (error is WASIComponentAsyncEndpointStateError) {
      finishReadCopy(
        dropped: error.failure == WASIComponentAsyncEndpointFailure.dropped,
      );
      return;
    }
    _resetReadCopy();
  }

  void _finishWriteCopyError(Object error) {
    if (error is WASIComponentAsyncEndpointStateError) {
      finishWriteCopy(
        dropped: error.failure == WASIComponentAsyncEndpointFailure.dropped,
      );
      return;
    }
    _resetWriteCopy();
  }

  void _resetReadCopy() {
    if (_readCopyStatus == _WASIComponentAsyncCopyStatus.copying ||
        _readCopyStatus == _WASIComponentAsyncCopyStatus.cancellingCopy) {
      _readCopyStatus = _WASIComponentAsyncCopyStatus.idle;
      _readCopyIsAsync = false;
    }
  }

  void _resetWriteCopy() {
    if (_writeCopyStatus == _WASIComponentAsyncCopyStatus.copying ||
        _writeCopyStatus == _WASIComponentAsyncCopyStatus.cancellingCopy) {
      _writeCopyStatus = _WASIComponentAsyncCopyStatus.idle;
      _writeCopyIsAsync = false;
    }
  }

  void requireReadCopyDroppable() {
    _requireCopyDroppable(_readCopyStatus, 'readable');
  }

  void requireWriteCopyDroppable() {
    _requireCopyDroppable(_writeCopyStatus, 'writable');
  }

  void requireReadCopyIdle() {
    _requireCopyIdle(_readCopyStatus, 'readable');
  }

  void requireWriteCopyIdle() {
    _requireCopyIdle(_writeCopyStatus, 'writable');
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
        progressed = _completeRendezvousWaiters();
        progressed = _completeReadyReadWaiters() || progressed;
        progressed = _completeReadyWriteWaiters() || progressed;
        progressed = _completeReadyWriteCapacityWaiters() || progressed;
      }
    } finally {
      _pumpingWaiters = false;
    }
  }

  bool _completeRendezvousWaiters() {
    if (maxBufferedElements != 0) {
      return false;
    }
    final readers = readWaiters;
    final writers = writeWaiters;
    if (readers == null ||
        readers.isEmpty ||
        writers == null ||
        writers.isEmpty) {
      return false;
    }

    var progressed = false;
    while (readers.isNotEmpty && writers.isNotEmpty) {
      final reader = readers.removeFirst();
      final writer = writers.removeFirst();
      final count = _minInt(reader.maxElements, writer.values.length);
      reader.complete(List<T>.of(writer.values.take(count), growable: false));
      writer.complete(count);
      progressed = true;
    }
    if (readers.isEmpty) {
      readWaiters = null;
    }
    if (writers.isEmpty) {
      writeWaiters = null;
    }
    return progressed;
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
      } else if (writeCancelled) {
        waiters.removeFirst();
        waiter.fail(
          WASIComponentAsyncEndpointStateError(
            WASIComponentAsyncEndpointFailure.cancelled,
            'WASI component stream $name writes were cancelled.',
          ),
        );
        progressed = true;
      } else if (writeClosedGracefully) {
        waiters.removeFirst();
        waiter.complete(<T>[]);
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

  void _requireCopyIdle(_WASIComponentAsyncCopyStatus status, String endpoint) {
    if (status != _WASIComponentAsyncCopyStatus.idle) {
      throw StateError(
        'WASI component stream $name $endpoint copy is not idle.',
      );
    }
  }

  void _requestCopyCancellation(
    _WASIComponentAsyncCopyStatus status,
    bool asynchronous,
    String endpoint,
    void Function(_WASIComponentAsyncCopyStatus status) setStatus,
  ) {
    if (status != _WASIComponentAsyncCopyStatus.copying || !asynchronous) {
      throw StateError(
        'WASI component stream $name $endpoint has no cancellable async copy.',
      );
    }
    setStatus(_WASIComponentAsyncCopyStatus.cancellingCopy);
  }

  void _finishCopy(
    _WASIComponentAsyncCopyStatus status,
    String endpoint,
    bool dropped,
    void Function(_WASIComponentAsyncCopyStatus status) setStatus,
  ) {
    if (status != _WASIComponentAsyncCopyStatus.copying &&
        status != _WASIComponentAsyncCopyStatus.cancellingCopy) {
      throw StateError(
        'WASI component stream $name $endpoint has no active copy.',
      );
    }
    setStatus(
      dropped
          ? _WASIComponentAsyncCopyStatus.done
          : _WASIComponentAsyncCopyStatus.idle,
    );
  }

  void _requireCopyDroppable(
    _WASIComponentAsyncCopyStatus status,
    String endpoint,
  ) {
    if (status == _WASIComponentAsyncCopyStatus.copying ||
        status == _WASIComponentAsyncCopyStatus.cancellingCopy) {
      throw StateError(
        'WASI component stream $name $endpoint has an active copy.',
      );
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
  if (maxBufferedElements == null || maxBufferedElements >= 0) {
    return maxBufferedElements;
  }
  throw RangeError.range(maxBufferedElements, 0, null, 'maxBufferedElements');
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

enum _WASIComponentAsyncCopyStatus { idle, copying, cancellingCopy, done }

final class _WASIComponentFutureState<T> {
  _WASIComponentFutureState(this.name, this.onDrop, this.onDiscard);

  final String name;
  final void Function()? onDrop;
  final void Function(T value)? onDiscard;

  _WASIComponentFutureStatus status = _WASIComponentFutureStatus.pending;
  T? value;
  List<Completer<T>>? readWaiters;
  List<Completer<void>>? writeDeliveryWaiters;
  bool readDropped = false;
  bool writeDropped = false;
  bool _dropCalled = false;
  bool _valueObserved = false;
  _WASIComponentAsyncCopyStatus _readCopyStatus =
      _WASIComponentAsyncCopyStatus.idle;
  _WASIComponentAsyncCopyStatus _writeCopyStatus =
      _WASIComponentAsyncCopyStatus.idle;
  bool _readCopyIsAsync = false;
  bool _writeCopyIsAsync = false;

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
      final completedValue = value as T;
      markValueObserved();
      return Future<T>.value(completedValue);
    }

    final completer = Completer<T>();
    (readWaiters ??= <Completer<T>>[]).add(completer);
    return completer.future;
  }

  T readForCopy() {
    _beginReadCopy(asynchronous: false);
    try {
      requireReadable();
      if (!isReady) {
        throw StateError('WASI component future $name is not ready.');
      }
      final completedValue = value as T;
      markValueObserved();
      _readCopyStatus = _WASIComponentAsyncCopyStatus.done;
      return completedValue;
    } catch (_) {
      _resetReadCopy();
      rethrow;
    }
  }

  Future<T> readWhenReadyForCopy({
    bool asynchronous = true,
    bool deferCompletion = false,
  }) {
    _beginReadCopy(asynchronous: asynchronous);
    try {
      return readWhenReady().then(
        (value) {
          if (!deferCompletion) {
            finishReadCopy(cancelled: false);
          }
          return value;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!deferCompletion) {
            _finishReadCopyError(error);
          }
          Error.throwWithStackTrace(error, stackTrace);
        },
      );
    } catch (_) {
      if (!deferCompletion) {
        _resetReadCopy();
      }
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
    _beginWriteCopy(asynchronous: false);
    try {
      complete(completedValue);
      _writeCopyStatus = _WASIComponentAsyncCopyStatus.done;
    } on WASIComponentAsyncEndpointStateError catch (error) {
      if (error.failure == WASIComponentAsyncEndpointFailure.dropped) {
        _writeCopyStatus = _WASIComponentAsyncCopyStatus.done;
      } else {
        _resetWriteCopy();
      }
      rethrow;
    } catch (_) {
      _resetWriteCopy();
      rethrow;
    }
  }

  void completeFromHost(T completedValue) {
    try {
      _acceptHostValue(completedValue);
    } finally {
      _dropWritableFromHost();
    }
  }

  Future<void> completeWhenRead(T completedValue) {
    complete(completedValue);
    return _waitForValueObservation();
  }

  Future<void> _waitForValueObservation() {
    if (_valueObserved) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    (writeDeliveryWaiters ??= <Completer<void>>[]).add(completer);
    return completer.future;
  }

  Future<void> completeWhenReadFromHost(T completedValue) {
    try {
      _acceptHostValue(completedValue);
      return _waitForValueObservation();
    } finally {
      _dropWritableFromHost();
    }
  }

  void _acceptHostValue(T completedValue) {
    var accepted = false;
    try {
      complete(completedValue);
      accepted = true;
    } finally {
      if (!accepted) {
        onDiscard?.call(completedValue);
      }
    }
  }

  Future<void> completeWhenReadForCopy(
    T completedValue, {
    bool asynchronous = true,
    bool deferCompletion = false,
  }) {
    _beginWriteCopy(asynchronous: asynchronous);
    try {
      return completeWhenRead(completedValue).then(
        (_) {
          if (!deferCompletion) {
            finishWriteCopy(cancelled: false);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!deferCompletion) {
            _finishWriteCopyError(error);
          }
          Error.throwWithStackTrace(error, stackTrace);
        },
      );
    } catch (_) {
      if (!deferCompletion) {
        _resetWriteCopy();
      }
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

  void cancelReadableFromHost() {
    try {
      if (!isCancelled) {
        cancel();
      }
    } finally {
      disposeReadable();
    }
  }

  void cancelWritableFromHost() {
    try {
      if (!isCancelled) {
        cancel();
      }
    } finally {
      disposeWritable();
    }
  }

  void cancelPendingReadCopy() {
    requireReadable();
    final waiters = readWaiters;
    if (waiters == null || waiters.isEmpty) {
      throw StateError('WASI component future $name has no pending read copy.');
    }
    requestReadCopyCancellation();
    cancelRequestedReadCopy();
  }

  void requestReadCopyCancellation() {
    _requestCopyCancellation(
      _readCopyStatus,
      _readCopyIsAsync,
      'readable',
      (status) => _readCopyStatus = status,
    );
  }

  void cancelRequestedReadCopy() {
    final waiters = readWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    final waiter = waiters.removeAt(0);
    if (waiters.isEmpty) {
      readWaiters = null;
    }
    waiter.completeError(
      WASIComponentAsyncEndpointStateError(
        WASIComponentAsyncEndpointFailure.cancelled,
        'WASI component future $name read copy was cancelled.',
      ),
    );
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

  void cancelPendingWriteCopy() {
    final waiters = writeDeliveryWaiters;
    if (waiters == null || waiters.isEmpty) {
      throw StateError(
        'WASI component future $name has no pending write copy.',
      );
    }
    requestWriteCopyCancellation();
    cancelRequestedWriteCopy();
  }

  void requestWriteCopyCancellation() {
    _requestCopyCancellation(
      _writeCopyStatus,
      _writeCopyIsAsync,
      'writable',
      (status) => _writeCopyStatus = status,
    );
  }

  void cancelRequestedWriteCopy() {
    final waiters = writeDeliveryWaiters;
    if (waiters == null || waiters.isEmpty) {
      return;
    }
    final waiter = waiters.removeAt(0);
    if (waiters.isEmpty) {
      writeDeliveryWaiters = null;
    }
    status = _WASIComponentFutureStatus.pending;
    value = null;
    _valueObserved = false;
    waiter.completeError(
      WASIComponentAsyncEndpointStateError(
        WASIComponentAsyncEndpointFailure.cancelled,
        'WASI component future $name write copy was cancelled.',
      ),
    );
  }

  void dropReadable() {
    if (readDropped) {
      return;
    }
    _requireCopyDroppable(_readCopyStatus, 'readable');
    disposeReadable();
  }

  void disposeReadable() {
    if (readDropped) {
      return;
    }
    _readCopyStatus = _WASIComponentAsyncCopyStatus.done;
    _readCopyIsAsync = false;
    readDropped = true;
    final discardValue = isReady && !_valueObserved;
    if (discardValue || writeDeliveryWaiters != null) {
      status = _WASIComponentFutureStatus.cancelled;
    }
    Object? firstError;
    StackTrace? firstStackTrace;
    void cleanUp(void Function() action) {
      try {
        action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (discardValue) {
      cleanUp(_discardValue);
    }
    cleanUp(() {
      if (readWaiters != null) {
        _failReadWaiters(
          StateError('WASI component future $name readable was dropped.'),
        );
      }
    });
    cleanUp(() {
      if (writeDeliveryWaiters != null) {
        _failWriteDeliveryWaiters(
          WASIComponentAsyncEndpointStateError(
            WASIComponentAsyncEndpointFailure.dropped,
            'WASI component future $name readable was dropped.',
          ),
        );
      }
    });
    cleanUp(_maybeDrop);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  void dropWritable() {
    if (writeDropped) {
      return;
    }
    requireWritableDroppable();
    disposeWritable();
  }

  void disposeWritable() {
    if (writeDropped) {
      return;
    }
    _writeCopyStatus = _WASIComponentAsyncCopyStatus.done;
    _writeCopyIsAsync = false;
    writeDropped = true;
    _maybeDrop();
  }

  void _dropWritableFromHost() => disposeWritable();

  void requireWritableDroppable() {
    if (writeDropped) {
      return;
    }
    if (_writeCopyStatus != _WASIComponentAsyncCopyStatus.done) {
      throw StateError(
        'WASI component future $name writable cannot be dropped before writing a value.',
      );
    }
  }

  void requireReadCopyDroppable() {
    _requireCopyDroppable(_readCopyStatus, 'readable');
  }

  void requireReadCopyIdle() {
    _requireCopyIdle(_readCopyStatus, 'readable');
  }

  void requireWriteCopyIdle() {
    _requireCopyIdle(_writeCopyStatus, 'writable');
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
    value = null;
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

  void _discardValue() {
    final discardedValue = value as T;
    value = null;
    onDiscard?.call(discardedValue);
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

  void _beginReadCopy({required bool asynchronous}) {
    _requireCopyIdle(_readCopyStatus, 'readable');
    _readCopyStatus = _WASIComponentAsyncCopyStatus.copying;
    _readCopyIsAsync = asynchronous;
  }

  void _beginWriteCopy({required bool asynchronous}) {
    _requireCopyIdle(_writeCopyStatus, 'writable');
    _writeCopyStatus = _WASIComponentAsyncCopyStatus.copying;
    _writeCopyIsAsync = asynchronous;
  }

  void finishReadCopy({required bool cancelled}) {
    if (readDropped) {
      return;
    }
    _finishCopy(
      _readCopyStatus,
      'readable',
      cancelled,
      (status) => _readCopyStatus = status,
    );
    _readCopyIsAsync = false;
  }

  void finishWriteCopy({required bool cancelled}) {
    if (writeDropped) {
      return;
    }
    _finishCopy(
      _writeCopyStatus,
      'writable',
      cancelled,
      (status) => _writeCopyStatus = status,
    );
    _writeCopyIsAsync = false;
  }

  void _finishReadCopyError(Object error) {
    if (error is WASIComponentAsyncEndpointStateError) {
      finishReadCopy(
        cancelled: error.failure == WASIComponentAsyncEndpointFailure.cancelled,
      );
      return;
    }
    _resetReadCopy();
  }

  void _finishWriteCopyError(Object error) {
    if (error is WASIComponentAsyncEndpointStateError) {
      finishWriteCopy(
        cancelled: error.failure == WASIComponentAsyncEndpointFailure.cancelled,
      );
      return;
    }
    _resetWriteCopy();
  }

  void _resetReadCopy() {
    if (_readCopyStatus == _WASIComponentAsyncCopyStatus.copying ||
        _readCopyStatus == _WASIComponentAsyncCopyStatus.cancellingCopy) {
      _readCopyStatus = _WASIComponentAsyncCopyStatus.idle;
      _readCopyIsAsync = false;
    }
  }

  void _resetWriteCopy() {
    if (_writeCopyStatus == _WASIComponentAsyncCopyStatus.copying ||
        _writeCopyStatus == _WASIComponentAsyncCopyStatus.cancellingCopy) {
      _writeCopyStatus = _WASIComponentAsyncCopyStatus.idle;
      _writeCopyIsAsync = false;
    }
  }

  void _requireCopyIdle(_WASIComponentAsyncCopyStatus status, String endpoint) {
    switch (status) {
      case _WASIComponentAsyncCopyStatus.idle:
        return;
      case _WASIComponentAsyncCopyStatus.copying:
        throw StateError(
          'WASI component future $name $endpoint copy is already active.',
        );
      case _WASIComponentAsyncCopyStatus.cancellingCopy:
        throw StateError(
          'WASI component future $name $endpoint copy is being cancelled.',
        );
      case _WASIComponentAsyncCopyStatus.done:
        throw StateError('WASI component future $name $endpoint copy is done.');
    }
  }

  void _requestCopyCancellation(
    _WASIComponentAsyncCopyStatus status,
    bool asynchronous,
    String endpoint,
    void Function(_WASIComponentAsyncCopyStatus status) setStatus,
  ) {
    if (status != _WASIComponentAsyncCopyStatus.copying || !asynchronous) {
      throw StateError(
        'WASI component future $name $endpoint has no cancellable async copy.',
      );
    }
    setStatus(_WASIComponentAsyncCopyStatus.cancellingCopy);
  }

  void _finishCopy(
    _WASIComponentAsyncCopyStatus status,
    String endpoint,
    bool cancelled,
    void Function(_WASIComponentAsyncCopyStatus status) setStatus,
  ) {
    if (status != _WASIComponentAsyncCopyStatus.copying &&
        status != _WASIComponentAsyncCopyStatus.cancellingCopy) {
      throw StateError(
        'WASI component future $name $endpoint has no active copy.',
      );
    }
    setStatus(
      cancelled
          ? _WASIComponentAsyncCopyStatus.idle
          : _WASIComponentAsyncCopyStatus.done,
    );
  }

  void _requireCopyDroppable(
    _WASIComponentAsyncCopyStatus status,
    String endpoint,
  ) {
    if (status == _WASIComponentAsyncCopyStatus.copying ||
        status == _WASIComponentAsyncCopyStatus.cancellingCopy) {
      throw StateError(
        'WASI component future $name $endpoint has an active copy.',
      );
    }
  }
}
