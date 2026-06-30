import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/resource_table.dart';
import '../component/wit_adapter.dart';
import 'poll.dart';

/// Host-owned WASI 0.2 `wasi:io/error.error` value.
final class WASIPreview2IoError {
  /// Creates an I/O error with a human-readable debug string.
  const WASIPreview2IoError(this.debugString);

  /// Human-readable diagnostic text.
  final String debugString;
}

/// WASI 0.2 `wasi:io/error` host imports.
final class WASIPreview2IoErrorHost {
  /// Creates an error host backed by [table] or a new component table.
  WASIPreview2IoErrorHost({WASIComponentResourceTable? table})
    : table = table ?? WASIComponentResourceTable();

  /// Component resource table that owns error handles.
  final WASIComponentResourceTable table;

  late final WASIComponentResourceType<WASIPreview2IoError> _errorType = table
      .defineType<WASIPreview2IoError>('wasi:io/error@0.2.0.error');

  /// Standard `wasi:io/error@0.2.0` import callbacks.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:io/error@0.2.0.error.to-debug-string': (args) =>
            _debugString(_handle(args.single)),
      });

  /// Inserts [error] and returns an owned component handle.
  int insert(WASIPreview2IoError error) {
    return table.insert<WASIPreview2IoError>(_errorType, error);
  }

  String _debugString(int handle) {
    return table.borrow<WASIPreview2IoError, String>(
      _errorType,
      handle,
      (error) => error.debugString,
    );
  }
}

/// Host-owned WASI 0.2 `input-stream`.
final class WASIPreview2InputStream {
  /// Creates an input byte stream.
  WASIPreview2InputStream({
    List<int> bytes = const <int>[],
    bool closed = false,
  }) : _bytes = List<int>.of(bytes),
       _closed = closed;

  final List<int> _bytes;
  final List<Completer<void>> _readableWaiters = <Completer<void>>[];
  bool _closed;
  String? _failed;

  /// Whether this stream is ready for a non-empty read or terminal state.
  bool get isReadable => _bytes.isNotEmpty || _closed || _failed != null;

  /// Appends bytes and wakes pending blocking readers.
  void append(List<int> bytes) {
    if (_closed) {
      throw StateError('Cannot append to a closed WASI input-stream.');
    }
    if (_failed != null) {
      throw StateError('Cannot append to a failed WASI input-stream.');
    }
    _bytes.addAll(bytes);
    _notifyReadable();
  }

  /// Closes this stream.
  void close() {
    _closed = true;
    _notifyReadable();
  }

  /// Fails this stream with [debugString].
  void fail(String debugString) {
    _failed = debugString;
    _notifyReadable();
  }

  Future<void> _waitReadable() {
    if (isReadable) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _readableWaiters.add(completer);
    return completer.future;
  }

  _StreamOutcome<List<int>> _read(BigInt maxLength) {
    final length = _boundedLength(maxLength, _bytes.length);
    if (_failed case final error?) {
      return _StreamOutcome<List<int>>.failed(error);
    }
    if (_bytes.isEmpty && _closed) {
      return _StreamOutcome<List<int>>.closed();
    }
    if (length == 0) {
      return _StreamOutcome<List<int>>.ok(const <int>[]);
    }
    final chunk = _bytes.sublist(0, length);
    _bytes.removeRange(0, length);
    return _StreamOutcome<List<int>>.ok(chunk);
  }

  _StreamOutcome<BigInt> _skip(BigInt maxLength) {
    final readResult = _read(maxLength);
    if (!readResult.isOk) {
      return _StreamOutcome<BigInt>.error(readResult.error!);
    }
    return _StreamOutcome<BigInt>.ok(BigInt.from(readResult.value!.length));
  }

  void _notifyReadable() {
    final waiters = List<Completer<void>>.of(_readableWaiters);
    _readableWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}

/// Host-owned WASI 0.2 `output-stream`.
final class WASIPreview2OutputStream {
  /// Creates an output byte stream.
  WASIPreview2OutputStream({int maxWriteSize = 65536})
    : _maxWriteSize = _validMaxWriteSize(maxWriteSize);

  final int _maxWriteSize;
  final List<int> _bytes = <int>[];
  bool _closed = false;
  String? _failed;
  int _writePermit = 0;

  /// Bytes written to this stream.
  List<int> get bytes => List<int>.unmodifiable(_bytes);

  /// Whether this stream is ready to accept writes or report terminal state.
  bool get isWritable => _failed != null || _closed || _maxWriteSize > 0;

  /// Closes this stream.
  void close() {
    _closed = true;
  }

  /// Fails this stream with [debugString].
  void fail(String debugString) {
    _failed = debugString;
  }

  _StreamOutcome<BigInt> _checkWrite() {
    final failure = _terminalFailure();
    if (failure != null) {
      return _StreamOutcome<BigInt>.error(failure);
    }
    _writePermit = _maxWriteSize;
    return _StreamOutcome<BigInt>.ok(BigInt.from(_writePermit));
  }

  _StreamOutcome<void> _write(List<int> bytes) {
    final failure = _terminalFailure();
    if (failure != null) {
      return _StreamOutcome<void>.error(failure);
    }
    if (bytes.length > _writePermit) {
      throw StateError(
        'WASI output-stream write exceeded the last check-write permit.',
      );
    }
    _bytes.addAll(bytes);
    _writePermit -= bytes.length;
    return _StreamOutcome<void>.ok(null);
  }

  _StreamOutcome<void> _writeZeroes(BigInt length) {
    if (length > BigInt.from(_writePermit)) {
      throw StateError(
        'WASI output-stream write-zeroes exceeded the last check-write permit.',
      );
    }
    return _write(List<int>.filled(length.toInt(), 0));
  }

  _StreamOutcome<void> _flush() {
    final failure = _terminalFailure();
    return failure == null
        ? _StreamOutcome<void>.ok(null)
        : _StreamOutcome<void>.error(failure);
  }

  Future<void> _waitWritable() => Future<void>.value();

  _StreamFailure? _terminalFailure() {
    if (_failed case final error?) {
      return _StreamFailure.lastOperationFailed(error);
    }
    if (_closed) {
      return const _StreamFailure.closed();
    }
    return null;
  }
}

/// WASI 0.2 `wasi:io/streams` host imports.
final class WASIPreview2StreamsHost {
  /// Creates a streams host backed by [table] or shared host tables.
  factory WASIPreview2StreamsHost({
    WASIComponentResourceTable? table,
    WASIPreview2PollHost? pollHost,
    WASIPreview2IoErrorHost? errorHost,
  }) {
    final resolvedTable =
        table ??
        pollHost?.table ??
        errorHost?.table ??
        WASIComponentResourceTable();
    if (pollHost != null && !identical(resolvedTable, pollHost.table)) {
      throw ArgumentError.value(
        pollHost,
        'pollHost',
        'must use the same component resource table as streams',
      );
    }
    if (errorHost != null && !identical(resolvedTable, errorHost.table)) {
      throw ArgumentError.value(
        errorHost,
        'errorHost',
        'must use the same component resource table as streams',
      );
    }
    return WASIPreview2StreamsHost._(
      table: resolvedTable,
      pollHost: pollHost ?? WASIPreview2PollHost(table: resolvedTable),
      errorHost: errorHost ?? WASIPreview2IoErrorHost(table: resolvedTable),
    );
  }

  WASIPreview2StreamsHost._({
    required this.table,
    required this.pollHost,
    required this.errorHost,
  });

  /// Component resource table that owns stream handles.
  final WASIComponentResourceTable table;

  /// Poll host used by stream `subscribe`.
  final WASIPreview2PollHost pollHost;

  /// Error host used by `stream-error.last-operation-failed`.
  final WASIPreview2IoErrorHost errorHost;

  late final WASIComponentResourceType<WASIPreview2InputStream>
  _inputStreamType = table.defineType<WASIPreview2InputStream>(
    'wasi:io/streams@0.2.0.input-stream',
  );

  late final WASIComponentResourceType<WASIPreview2OutputStream>
  _outputStreamType = table.defineType<WASIPreview2OutputStream>(
    'wasi:io/streams@0.2.0.output-stream',
  );

  /// Standard `wasi:io/streams@0.2.0` import callbacks.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:io/streams@0.2.0.input-stream.read': (args) =>
            _read(_handle(args[0]), _u64(args[1]), blocking: false),
        'wasi:io/streams@0.2.0.input-stream.blocking-read': (args) =>
            _read(_handle(args[0]), _u64(args[1]), blocking: true),
        'wasi:io/streams@0.2.0.input-stream.skip': (args) =>
            _skip(_handle(args[0]), _u64(args[1]), blocking: false),
        'wasi:io/streams@0.2.0.input-stream.blocking-skip': (args) =>
            _skip(_handle(args[0]), _u64(args[1]), blocking: true),
        'wasi:io/streams@0.2.0.input-stream.subscribe': (args) =>
            _subscribeInput(_handle(args.single)),
        'wasi:io/streams@0.2.0.output-stream.check-write': (args) =>
            _checkWrite(_handle(args.single)),
        'wasi:io/streams@0.2.0.output-stream.write': (args) =>
            _write(_handle(args[0]), _u8List(args[1])),
        'wasi:io/streams@0.2.0.output-stream.blocking-write-and-flush':
            (args) =>
                _blockingWriteAndFlush(_handle(args[0]), _u8List(args[1])),
        'wasi:io/streams@0.2.0.output-stream.flush': (args) =>
            _flush(_handle(args.single)),
        'wasi:io/streams@0.2.0.output-stream.blocking-flush': (args) =>
            _flush(_handle(args.single)),
        'wasi:io/streams@0.2.0.output-stream.subscribe': (args) =>
            _subscribeOutput(_handle(args.single)),
        'wasi:io/streams@0.2.0.output-stream.write-zeroes': (args) =>
            _writeZeroes(_handle(args[0]), _u64(args[1])),
        'wasi:io/streams@0.2.0.output-stream.blocking-write-zeroes-and-flush':
            (args) =>
                _blockingWriteZeroesAndFlush(_handle(args[0]), _u64(args[1])),
        'wasi:io/streams@0.2.0.output-stream.splice': (args) =>
            _splice(_handle(args[0]), _handle(args[1]), _u64(args[2])),
        'wasi:io/streams@0.2.0.output-stream.blocking-splice': (args) =>
            _blockingSplice(_handle(args[0]), _handle(args[1]), _u64(args[2])),
      });

  /// Inserts [stream] and returns an owned input-stream handle.
  int insertInputStream(WASIPreview2InputStream stream) {
    return table.insert<WASIPreview2InputStream>(_inputStreamType, stream);
  }

  /// Inserts [stream] and returns an owned output-stream handle.
  int insertOutputStream([WASIPreview2OutputStream? stream]) {
    return table.insert<WASIPreview2OutputStream>(
      _outputStreamType,
      stream ?? WASIPreview2OutputStream(),
    );
  }

  /// Returns the output stream for [handle].
  WASIPreview2OutputStream outputStream(int handle) {
    return table.get<WASIPreview2OutputStream>(_outputStreamType, handle);
  }

  FutureOr<WasmComponentValueData> _read(
    int handle,
    BigInt length, {
    required bool blocking,
  }) {
    final stream = table.get<WASIPreview2InputStream>(_inputStreamType, handle);
    if (!blocking || stream.isReadable) {
      return _readResult(stream._read(length));
    }
    return stream._waitReadable().then(
      (_) => _readResult(stream._read(length)),
    );
  }

  FutureOr<WasmComponentValueData> _skip(
    int handle,
    BigInt length, {
    required bool blocking,
  }) {
    final stream = table.get<WASIPreview2InputStream>(_inputStreamType, handle);
    if (!blocking || stream.isReadable) {
      return _u64Result(stream._skip(length));
    }
    return stream._waitReadable().then((_) => _u64Result(stream._skip(length)));
  }

  int _subscribeInput(int handle) {
    final stream = table.get<WASIPreview2InputStream>(_inputStreamType, handle);
    return pollHost.insert(
      WASIPreview2Pollable(
        isReady: () => stream.isReadable,
        waitReady: stream._waitReadable,
      ),
    );
  }

  WasmComponentValueData _checkWrite(int handle) {
    final stream = table.get<WASIPreview2OutputStream>(
      _outputStreamType,
      handle,
    );
    return _u64Result(stream._checkWrite());
  }

  WasmComponentValueData _write(int handle, List<int> bytes) {
    final stream = table.get<WASIPreview2OutputStream>(
      _outputStreamType,
      handle,
    );
    return _unitResult(stream._write(bytes));
  }

  WasmComponentValueData _blockingWriteAndFlush(int handle, List<int> bytes) {
    final stream = table.get<WASIPreview2OutputStream>(
      _outputStreamType,
      handle,
    );
    var offset = 0;
    while (offset < bytes.length) {
      final permit = stream._checkWrite();
      if (!permit.isOk) {
        return _unitResult(_StreamOutcome<void>.error(permit.error!));
      }
      final count = bytes.length - offset < permit.value!.toInt()
          ? bytes.length - offset
          : permit.value!.toInt();
      final written = stream._write(bytes.sublist(offset, offset + count));
      if (!written.isOk) {
        return _unitResult(written);
      }
      offset += count;
    }
    return _unitResult(stream._flush());
  }

  WasmComponentValueData _flush(int handle) {
    final stream = table.get<WASIPreview2OutputStream>(
      _outputStreamType,
      handle,
    );
    return _unitResult(stream._flush());
  }

  int _subscribeOutput(int handle) {
    final stream = table.get<WASIPreview2OutputStream>(
      _outputStreamType,
      handle,
    );
    return pollHost.insert(
      WASIPreview2Pollable(
        isReady: () => stream.isWritable,
        waitReady: stream._waitWritable,
      ),
    );
  }

  WasmComponentValueData _writeZeroes(int handle, BigInt length) {
    final stream = table.get<WASIPreview2OutputStream>(
      _outputStreamType,
      handle,
    );
    return _unitResult(stream._writeZeroes(length));
  }

  WasmComponentValueData _blockingWriteZeroesAndFlush(
    int handle,
    BigInt length,
  ) {
    final stream = table.get<WASIPreview2OutputStream>(
      _outputStreamType,
      handle,
    );
    var remaining = length;
    while (remaining > BigInt.zero) {
      final permit = stream._checkWrite();
      if (!permit.isOk) {
        return _unitResult(_StreamOutcome<void>.error(permit.error!));
      }
      final count = remaining < permit.value! ? remaining : permit.value!;
      final written = stream._writeZeroes(count);
      if (!written.isOk) {
        return _unitResult(written);
      }
      remaining -= count;
    }
    return _unitResult(stream._flush());
  }

  WasmComponentValueData _splice(
    int outputHandle,
    int inputHandle,
    BigInt len,
  ) {
    final output = table.get<WASIPreview2OutputStream>(
      _outputStreamType,
      outputHandle,
    );
    final input = table.get<WASIPreview2InputStream>(
      _inputStreamType,
      inputHandle,
    );
    final permit = output._checkWrite();
    if (!permit.isOk) {
      return _u64Result(_StreamOutcome<BigInt>.error(permit.error!));
    }
    final maxRead = permit.value! < len ? permit.value! : len;
    final read = input._read(maxRead);
    if (!read.isOk) {
      return _u64Result(_StreamOutcome<BigInt>.error(read.error!));
    }
    final written = output._write(read.value!);
    if (!written.isOk) {
      return _u64Result(_StreamOutcome<BigInt>.error(written.error!));
    }
    return _u64Result(
      _StreamOutcome<BigInt>.ok(BigInt.from(read.value!.length)),
    );
  }

  FutureOr<WasmComponentValueData> _blockingSplice(
    int outputHandle,
    int inputHandle,
    BigInt len,
  ) {
    final input = table.get<WASIPreview2InputStream>(
      _inputStreamType,
      inputHandle,
    );
    if (input.isReadable) {
      return _splice(outputHandle, inputHandle, len);
    }
    return input._waitReadable().then(
      (_) => _splice(outputHandle, inputHandle, len),
    );
  }

  WasmComponentValueData _readResult(_StreamOutcome<List<int>> outcome) {
    if (!outcome.isOk) {
      return _errorResult(outcome.error!);
    }
    return _ok(_u8ListData(outcome.value!));
  }

  WasmComponentValueData _u64Result(_StreamOutcome<BigInt> outcome) {
    if (!outcome.isOk) {
      return _errorResult(outcome.error!);
    }
    return _ok(_integer(outcome.value!));
  }

  WasmComponentValueData _unitResult(_StreamOutcome<void> outcome) {
    return outcome.isOk ? _ok() : _errorResult(outcome.error!);
  }

  WasmComponentValueData _errorResult(_StreamFailure error) {
    return _result(false, _streamError(error));
  }

  WasmComponentValueData _streamError(_StreamFailure error) {
    if (error.isClosed) {
      return _variant('closed', 1);
    }
    final handle = errorHost.insert(WASIPreview2IoError(error.debugString));
    return _variant('last-operation-failed', 0, _integer(handle));
  }
}

final class _StreamOutcome<T> {
  const _StreamOutcome._(this.value, this.error);

  factory _StreamOutcome.ok(T value) => _StreamOutcome<T>._(value, null);

  factory _StreamOutcome.error(_StreamFailure error) =>
      _StreamOutcome<T>._(null, error);

  factory _StreamOutcome.closed() =>
      _StreamOutcome<T>.error(const _StreamFailure.closed());

  factory _StreamOutcome.failed(String debugString) =>
      _StreamOutcome<T>.error(_StreamFailure.lastOperationFailed(debugString));

  final T? value;
  final _StreamFailure? error;

  bool get isOk => error == null;
}

final class _StreamFailure {
  const _StreamFailure.closed()
    : isClosed = true,
      debugString = 'stream closed';

  const _StreamFailure.lastOperationFailed(this.debugString) : isClosed = false;

  final bool isClosed;
  final String debugString;
}

int _boundedLength(BigInt value, int available) {
  if (value <= BigInt.zero || available <= 0) {
    return 0;
  }
  final max = BigInt.from(available);
  return (value < max ? value : max).toInt();
}

int _validMaxWriteSize(int value) {
  if (value <= 0) {
    throw ArgumentError.value(value, 'maxWriteSize', 'must be positive');
  }
  return value;
}

BigInt _u64(Object? value) {
  return switch (value) {
    int() when value >= 0 => BigInt.from(value),
    BigInt() when value >= BigInt.zero => value,
    _ => throw StateError('Expected u64 value, got $value.'),
  };
}

int _handle(Object? value) {
  return switch (value) {
    int() when value >= 0 && value <= _maxU32 => value,
    BigInt() when value >= BigInt.zero && value <= BigInt.from(_maxU32) =>
      value.toInt(),
    _ => throw StateError('Expected WASI resource handle, got $value.'),
  };
}

List<int> _u8List(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.list) {
    throw StateError('Expected list<u8>.');
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.integer)
        _u8(item.integer)
      else
        throw StateError('Expected u8 list item.'),
  ];
}

int _u8(Object? value) {
  return switch (value) {
    int() when value >= 0 && value <= 0xff => value,
    BigInt() when value >= BigInt.zero && value <= BigInt.from(0xff) =>
      value.toInt(),
    _ => throw StateError('Expected u8 value, got $value.'),
  };
}

WasmComponentValueData _u8ListData(List<int> bytes) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [for (final byte in bytes) _integer(byte)],
  );
}

WasmComponentValueData _integer(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}

WasmComponentValueData _variant(
  String label,
  int index, [
  WasmComponentValueData? associatedValue,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: index,
    label: label,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _ok([WasmComponentValueData? value]) {
  return _result(true, value);
}

WasmComponentValueData _result(bool isOk, WasmComponentValueData? value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: isOk ? 0 : 1,
    label: isOk ? 'ok' : 'error',
    isOk: isOk,
    associatedValue: value,
  );
}

const int _maxU32 = 0xffffffff;
