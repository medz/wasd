import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/backpressure.dart';
import 'package:wasd/src/wasi/component/waitable_set.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

const int _defaultIterations = 50000;
const int _defaultBatchSize = 32;
const int _warmupIterations = 1000;

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options.help) {
    _printUsage();
    return;
  }

  await _runWarmup(options);

  final streamRoundTrip = _benchmarkStreamRoundTrip(options);
  final streamCancel = _benchmarkStreamCancel(options);
  final streamPendingReadCompletion =
      await _benchmarkStreamPendingReadCompletion(options);
  final streamPendingWriteCompletion =
      await _benchmarkStreamPendingWriteCompletion(options);
  final streamForwardSandwich = await _benchmarkStreamForwardSandwich(options);
  final futureCompleteReadDrop = _benchmarkFutureCompleteReadDrop(
    options.iterations,
  );
  final futurePendingReadCompletion =
      await _benchmarkFuturePendingReadCompletion(options.iterations);
  final backpressureCounter = _benchmarkBackpressureCounter(options.iterations);
  final waitableSetDelivery = await _benchmarkWaitableSetDelivery(
    options.iterations,
  );
  final programInvoke = _benchmarkProgramInvoke(options);
  final unitProgramInvoke = _benchmarkUnitProgramInvoke(options);
  final handleProgramInvoke = _benchmarkHandleProgramInvoke(options);
  final handleMemoryProgramInvoke = _benchmarkHandleMemoryProgramInvoke(
    options,
  );
  final handleMemoryProgramInvokeAsync =
      await _benchmarkHandleMemoryProgramInvokeAsync(options);
  final handleMemoryProgramInvokeEvent =
      await _benchmarkHandleMemoryProgramInvokeEvent(options);
  final handleMemoryProgramSyncCancel =
      await _benchmarkHandleMemoryProgramSyncCancel(options);
  final streamMemoryCopy = _benchmarkStreamMemoryCopy(options);
  final futureMemoryCopy = _benchmarkFutureMemoryCopy(options.iterations);

  final payload = <String, Object?>{
    'iterations': options.iterations,
    'batch_size': options.batchSize,
    'stream_round_trip': streamRoundTrip.toJson(),
    'stream_cancel': streamCancel.toJson(),
    'stream_pending_read_completion': streamPendingReadCompletion.toJson(),
    'stream_pending_write_completion': streamPendingWriteCompletion.toJson(),
    'stream_forward_sandwich': streamForwardSandwich.toJson(),
    'future_complete_read_drop': futureCompleteReadDrop.toJson(),
    'future_pending_read_completion': futurePendingReadCompletion.toJson(),
    'backpressure_counter': backpressureCounter.toJson(),
    'waitable_set_delivery': waitableSetDelivery.toJson(),
    'program_invoke': programInvoke.toJson(),
    'unit_program_invoke': unitProgramInvoke.toJson(),
    'handle_program_invoke': handleProgramInvoke.toJson(),
    'handle_memory_program_invoke': handleMemoryProgramInvoke.toJson(),
    'handle_memory_program_invoke_async': handleMemoryProgramInvokeAsync
        .toJson(),
    'handle_memory_program_invoke_event': handleMemoryProgramInvokeEvent
        .toJson(),
    'handle_memory_program_sync_cancel': handleMemoryProgramSyncCancel.toJson(),
    'stream_memory_copy': streamMemoryCopy.toJson(),
    'future_memory_copy': futureMemoryCopy.toJson(),
  };

  if (options.json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
  } else {
    _printText(payload);
  }
}

Future<void> _runWarmup(_Options options) async {
  final warmup = options.copyWith(iterations: _warmupIterations);
  _benchmarkStreamRoundTrip(warmup);
  _benchmarkStreamCancel(warmup);
  await _benchmarkStreamPendingReadCompletion(warmup);
  await _benchmarkStreamPendingWriteCompletion(warmup);
  await _benchmarkStreamForwardSandwich(warmup);
  _benchmarkFutureCompleteReadDrop(_warmupIterations);
  await _benchmarkFuturePendingReadCompletion(_warmupIterations);
  _benchmarkBackpressureCounter(_warmupIterations);
  await _benchmarkWaitableSetDelivery(_warmupIterations);
  _benchmarkProgramInvoke(warmup);
  _benchmarkUnitProgramInvoke(warmup);
  _benchmarkHandleProgramInvoke(warmup);
  _benchmarkHandleMemoryProgramInvoke(warmup);
  await _benchmarkHandleMemoryProgramInvokeAsync(warmup);
  await _benchmarkHandleMemoryProgramInvokeEvent(warmup);
  await _benchmarkHandleMemoryProgramSyncCancel(warmup);
  _benchmarkStreamMemoryCopy(warmup);
  _benchmarkFutureMemoryCopy(_warmupIterations);
}

_Metric _benchmarkStreamRoundTrip(_Options options) {
  final batch = List<int>.generate(options.batchSize, (index) => index);
  final stream = WASIComponentStream<int>('benchmark-stream');
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    stream.writable.writeAll(batch);
    final values = stream.readable.read(batch.length);
    for (final value in values) {
      checksum += value;
    }
  }
  watch.stop();

  if (stream.queuedLength != 0) {
    throw StateError('stream retained ${stream.queuedLength} values');
  }
  stream.readable.drop();
  stream.writable.drop();

  return _Metric(
    operations: options.iterations * options.batchSize * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkStreamCancel(_Options options) {
  final batch = List<int>.generate(options.batchSize, (index) => index);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final stream = WASIComponentStream<int>('benchmark-stream-cancel');
    stream.writable.writeAll(batch);
    stream.readable.cancel();
    checksum += stream.queuedLength;
    stream.readable.drop();
    stream.writable.drop();
  }
  watch.stop();

  return _Metric(
    operations: options.iterations * (options.batchSize + 3),
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

Future<_Metric> _benchmarkStreamPendingReadCompletion(_Options options) async {
  final batch = List<int>.generate(options.batchSize, (index) => index);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final stream = WASIComponentStream<int>('benchmark-stream-pending');
    final pending = stream.readable.readWhenAvailable(batch.length);
    stream.writable.writeAll(batch);
    final values = await pending;
    for (final value in values) {
      checksum += value;
    }
    stream.readable.drop();
    stream.writable.drop();
  }
  watch.stop();

  return _Metric(
    operations: options.iterations * (options.batchSize * 2 + 4),
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

Future<_Metric> _benchmarkStreamPendingWriteCompletion(_Options options) async {
  final batch = List<int>.generate(options.batchSize, (index) => index);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final stream = WASIComponentStream<int>(
      'benchmark-stream-write-pending',
      maxBufferedElements: options.batchSize,
    );
    stream.writable.writeAll(batch);
    final pending = stream.writable.writeWhenAvailable(batch);
    final values = stream.readable.read(1);
    for (final value in values) {
      checksum += value;
    }
    checksum += await pending;
    stream.readable.drop();
    stream.writable.drop();
  }
  watch.stop();

  return _Metric(
    operations: options.iterations * (options.batchSize + 6),
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

Future<_Metric> _benchmarkStreamForwardSandwich(_Options options) async {
  final batch = List<int>.generate(options.batchSize, (index) => index);
  final input = WASIComponentStream<int>(
    'benchmark-forward-input',
    maxBufferedElements: options.batchSize,
  );
  final middle = WASIComponentStream<int>(
    'benchmark-forward-middle',
    maxBufferedElements: options.batchSize,
  );
  final output = WASIComponentStream<int>(
    'benchmark-forward-output',
    maxBufferedElements: options.batchSize,
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    input.writable.writeAll(batch);
    final firstForward = await input.readable.forwardTo(
      middle.writable,
      options.batchSize,
      chunkSize: options.batchSize,
    );
    final secondForward = await middle.readable.forwardTo(
      output.writable,
      options.batchSize,
      chunkSize: options.batchSize,
    );
    if (firstForward != options.batchSize ||
        secondForward != options.batchSize) {
      throw StateError(
        'stream sandwich forwarded $firstForward/$secondForward values',
      );
    }
    final values = output.readable.read(options.batchSize);
    for (final value in values) {
      checksum += value;
    }
  }
  watch.stop();

  if (input.queuedLength != 0 ||
      middle.queuedLength != 0 ||
      output.queuedLength != 0) {
    throw StateError(
      'stream sandwich retained '
      '${input.queuedLength}/${middle.queuedLength}/${output.queuedLength} values',
    );
  }
  input.readable.drop();
  input.writable.drop();
  middle.readable.drop();
  middle.writable.drop();
  output.readable.drop();
  output.writable.drop();

  return _Metric(
    operations: options.iterations * options.batchSize * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkFutureCompleteReadDrop(int iterations) {
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final future = WASIComponentFuture<int>('benchmark-future');
    future.writable.complete(i);
    checksum += future.readable.read();
    future.readable.drop();
    future.writable.drop();
  }
  watch.stop();

  return _Metric(
    operations: iterations * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

Future<_Metric> _benchmarkFuturePendingReadCompletion(int iterations) async {
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final future = WASIComponentFuture<int>('benchmark-future-pending');
    final pending = future.readable.readWhenReady();
    future.writable.complete(i);
    checksum += await pending;
    future.readable.drop();
    future.writable.drop();
  }
  watch.stop();

  return _Metric(
    operations: iterations * 5,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkBackpressureCounter(int iterations) {
  final backpressure = WASIComponentBackpressure();
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += backpressure.increment();
    checksum += backpressure.decrement();
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

Future<_Metric> _benchmarkWaitableSetDelivery(int iterations) async {
  final host = WASIComponentWaitableHost();
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  const outputPointer = 1024;
  final set = host.waitableSetNew();
  final waitable = WASIComponentWaitable('benchmark-waitable');
  final waitableHandle = host.insertWaitable(waitable);
  host.waitableJoin(waitableHandle, set);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    waitable.setPendingEvent(
      () => WASIComponentWaitableEvent(
        code: WASIComponentWaitableEventCode.streamRead,
        payload1: i,
        payload2: 1 << 4,
      ),
    );
    checksum += host.waitableSetPollToMemory(set, memory, outputPointer);
    checksum += data.getUint32(outputPointer, Endian.little);
    checksum += data.getUint32(outputPointer + 4, Endian.little);

    final pending = host.waitableSetWaitToMemory(set, memory, outputPointer);
    waitable.setPendingEvent(
      () => WASIComponentWaitableEvent(
        code: WASIComponentWaitableEventCode.futureRead,
        payload1: i,
        payload2: 0,
      ),
    );
    checksum += await pending;
    checksum += data.getUint32(outputPointer, Endian.little);
    checksum += data.getUint32(outputPointer + 4, Endian.little);
  }
  watch.stop();

  host.waitableJoin(waitableHandle, 0);
  host.waitableSetDrop(set);
  host.dropWaitable(waitableHandle);
  if (host.table.activeCount != 0) {
    throw StateError('waitable set leaked ${host.table.activeCount} handles');
  }

  return _Metric(
    operations: iterations * 10,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkProgramInvoke(_Options options) {
  final component = WasmComponent.decode(_asyncProgramBytes());
  final host = WASIComponentAsyncHost()
    ..defineStreamType<int>(0, 'benchmark-stream')
    ..defineFutureType<int>(1, 'benchmark-future');
  final program = host.bindCanonicalDefinitions(component);
  final batch = List<int>.generate(options.batchSize, (index) => index);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final stream = program.invoke(0, const <Object?>[]);
    if (stream is! WASIComponentStream<int>) {
      throw StateError('stream.new returned non-stream: $stream');
    }
    final written = program.invoke(2, <Object?>[stream.writable, batch]);
    if (written != batch.length) {
      throw StateError('stream.write wrote $written values');
    }
    final values = program.invoke(1, <Object?>[stream.readable, batch.length]);
    if (values is! List) {
      throw StateError('stream.read returned non-list: $values');
    }
    for (final value in values) {
      if (value is! int) {
        throw StateError('stream.read returned non-int: $value');
      }
      checksum += value;
    }
    stream.readable.drop();
    stream.writable.drop();

    final future = program.invoke(3, const <Object?>[]);
    if (future is! WASIComponentFuture<int>) {
      throw StateError('future.new returned non-future: $future');
    }
    program.invoke(5, <Object?>[future.writable, i]);
    final value = program.invoke(4, <Object?>[future.readable]);
    if (value is! int) {
      throw StateError('future.read returned non-int: $value');
    }
    checksum += value;
    future.readable.drop();
    future.writable.drop();
  }
  watch.stop();

  return _Metric(
    operations: options.iterations * (options.batchSize * 2 + 5),
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkUnitProgramInvoke(_Options options) {
  final component = WasmComponent.decode(_asyncProgramBytes());
  final host = WASIComponentAsyncHost()
    ..defineStreamTypeFromComponent<Object?>(
      component,
      0,
      'benchmark-unit-stream',
    )
    ..defineFutureTypeFromComponent<Object?>(
      component,
      1,
      'benchmark-unit-future',
    );
  final program = host.bindCanonicalDefinitions(component);
  final batch = List<Object?>.filled(options.batchSize, null);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final stream = program.invoke(0, const <Object?>[]);
    if (stream is! WASIComponentStream<Object?>) {
      throw StateError('stream.new returned non-stream: $stream');
    }
    final written = program.invoke(2, <Object?>[stream.writable, batch]);
    if (written != batch.length) {
      throw StateError('stream.write wrote $written unit values');
    }
    final values = program.invoke(1, <Object?>[stream.readable, batch.length]);
    if (values is! List) {
      throw StateError('stream.read returned non-list: $values');
    }
    for (final value in values) {
      if (value != null) {
        throw StateError('stream.read returned non-unit value: $value');
      }
      checksum++;
    }
    stream.readable.drop();
    stream.writable.drop();

    final future = program.invoke(3, const <Object?>[]);
    if (future is! WASIComponentFuture<Object?>) {
      throw StateError('future.new returned non-future: $future');
    }
    program.invoke(5, <Object?>[future.writable, null]);
    final value = program.invoke(4, <Object?>[future.readable]);
    if (value != null) {
      throw StateError('future.read returned non-unit value: $value');
    }
    checksum++;
    future.readable.drop();
    future.writable.drop();
  }
  watch.stop();

  return _Metric(
    operations: options.iterations * (options.batchSize * 2 + 5),
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkHandleProgramInvoke(_Options options) {
  final component = WasmComponent.decode(_asyncHandleProgramBytes());
  final host = WASIComponentAsyncHost()
    ..defineStreamType<int>(0, 'benchmark-stream')
    ..defineFutureType<int>(1, 'benchmark-future');
  final program = host.bindCanonicalDefinitionsToHandles(component);
  final batch = List<int>.generate(options.batchSize, (index) => index);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final packedStreamHandles = program.invoke(0, const <Object?>[]);
    if (packedStreamHandles is! int) {
      throw StateError(
        'stream.new returned non-packed handles: $packedStreamHandles',
      );
    }
    final streamHandles = WASIComponentAsyncEndpointHandles.unpack(
      packedStreamHandles,
    );
    final written = program.invoke(2, <Object?>[streamHandles.writable, batch]);
    if (written != batch.length) {
      throw StateError('stream.write wrote $written values');
    }
    final values = program.invoke(1, <Object?>[
      streamHandles.readable,
      batch.length,
    ]);
    if (values is! List) {
      throw StateError('stream.read returned non-list: $values');
    }
    for (final value in values) {
      if (value is! int) {
        throw StateError('stream.read returned non-int: $value');
      }
      checksum += value;
    }
    program.invoke(3, <Object?>[streamHandles.readable]);
    program.invoke(4, <Object?>[streamHandles.writable]);

    final packedFutureHandles = program.invoke(5, const <Object?>[]);
    if (packedFutureHandles is! int) {
      throw StateError(
        'future.new returned non-packed handles: $packedFutureHandles',
      );
    }
    final futureHandles = WASIComponentAsyncEndpointHandles.unpack(
      packedFutureHandles,
    );
    program.invoke(7, <Object?>[futureHandles.writable, i]);
    final value = program.invoke(6, <Object?>[futureHandles.readable]);
    if (value is! int) {
      throw StateError('future.read returned non-int: $value');
    }
    checksum += value;
    program.invoke(8, <Object?>[futureHandles.readable]);
    program.invoke(9, <Object?>[futureHandles.writable]);
  }
  watch.stop();

  if (host.table.activeCount != 0) {
    throw StateError(
      'async handle program leaked ${host.table.activeCount} endpoints',
    );
  }

  return _Metric(
    operations: options.iterations * (options.batchSize * 2 + 5),
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkHandleMemoryProgramInvoke(_Options options) {
  final programs = _createHandleMemoryPrograms();
  final streamProgram = programs.streamProgram;
  final futureProgram = programs.futureProgram;

  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  const streamInputPointer = 1024;
  const streamOutputPointer = 4096;
  const futureInputPointer = 8192;
  const futureOutputPointer = 12288;
  for (var i = 0; i < options.batchSize; i++) {
    data.setUint32(streamInputPointer + i * 4, i, Endian.little);
  }
  data.setUint32(futureInputPointer, 0x55aa55aa, Endian.little);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final packedStreamHandles = streamProgram.invoke(0, const <Object?>[]);
    if (packedStreamHandles is! int) {
      throw StateError(
        'stream.new returned non-packed handles: $packedStreamHandles',
      );
    }
    final streamHandles = WASIComponentAsyncEndpointHandles.unpack(
      packedStreamHandles,
    );
    final streamWrite = streamProgram.invokeWithMemory(1, memory, <Object?>[
      streamHandles.writable,
      streamInputPointer,
      options.batchSize,
    ]);
    final streamRead = streamProgram.invokeWithMemory(2, memory, <Object?>[
      streamHandles.readable,
      streamOutputPointer,
      options.batchSize,
    ]);
    if (streamWrite is! int || streamRead is! int) {
      throw StateError(
        'stream memory copy returned non-packed results: $streamWrite/$streamRead',
      );
    }
    checksum += streamWrite;
    checksum += streamRead;
    checksum += data.getUint32(streamOutputPointer, Endian.little);
    streamProgram.invoke(3, <Object?>[streamHandles.readable]);
    streamProgram.invoke(4, <Object?>[streamHandles.writable]);

    final packedFutureHandles = futureProgram.invoke(0, const <Object?>[]);
    if (packedFutureHandles is! int) {
      throw StateError(
        'future.new returned non-packed handles: $packedFutureHandles',
      );
    }
    final futureHandles = WASIComponentAsyncEndpointHandles.unpack(
      packedFutureHandles,
    );
    final futureWrite = futureProgram.invokeWithMemory(1, memory, <Object?>[
      futureHandles.writable,
      futureInputPointer,
    ]);
    final futureRead = futureProgram.invokeWithMemory(2, memory, <Object?>[
      futureHandles.readable,
      futureOutputPointer,
    ]);
    if (futureWrite is! int || futureRead is! int) {
      throw StateError(
        'future memory copy returned non-packed results: $futureWrite/$futureRead',
      );
    }
    checksum += futureWrite;
    checksum += futureRead;
    checksum += data.getUint32(futureOutputPointer, Endian.little);
    futureProgram.invoke(3, <Object?>[futureHandles.readable]);
    futureProgram.invoke(4, <Object?>[futureHandles.writable]);
  }
  watch.stop();

  programs.expectNoLeaks();

  return _Metric(
    operations: options.iterations * (options.batchSize * 2 + 12),
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

Future<_Metric> _benchmarkHandleMemoryProgramInvokeAsync(
  _Options options,
) async {
  final programs = _createHandleMemoryPrograms(maxBufferedElements: 1);
  final streamProgram = programs.streamProgram;
  final futureProgram = programs.futureProgram;
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  const streamInputPointer = 1024;
  const streamSecondInputPointer = 2048;
  const streamOutputPointer = 4096;
  const streamSecondOutputPointer = 5120;
  const futureInputPointer = 8192;
  const futureOutputPointer = 12288;
  for (var i = 0; i < options.batchSize; i++) {
    data.setUint32(streamInputPointer + i * 4, i, Endian.little);
  }
  data.setUint32(streamSecondInputPointer, 0x33, Endian.little);
  data.setUint32(futureInputPointer, 0x55aa55aa, Endian.little);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final readHandles = _unpackEndpointHandles(
      streamProgram.invoke(0, const <Object?>[]),
      'stream.new',
    );
    final pendingRead = streamProgram.invokeWithMemoryAsync(
      2,
      memory,
      <Object?>[readHandles.readable, streamOutputPointer, 1],
    );
    final streamWrite = streamProgram.invokeWithMemory(1, memory, <Object?>[
      readHandles.writable,
      streamInputPointer,
      1,
    ]);
    final streamRead = await pendingRead;
    if (streamWrite is! int || streamRead is! int) {
      throw StateError(
        'async stream read returned non-packed results: $streamWrite/$streamRead',
      );
    }
    checksum += streamWrite;
    checksum += streamRead;
    checksum += data.getUint32(streamOutputPointer, Endian.little);
    streamProgram.invoke(3, <Object?>[readHandles.readable]);
    streamProgram.invoke(4, <Object?>[readHandles.writable]);

    final writeHandles = _unpackEndpointHandles(
      streamProgram.invoke(0, const <Object?>[]),
      'stream.new',
    );
    final firstWrite = streamProgram.invokeWithMemory(1, memory, <Object?>[
      writeHandles.writable,
      streamInputPointer,
      1,
    ]);
    final pendingWrite = streamProgram.invokeWithMemoryAsync(
      1,
      memory,
      <Object?>[writeHandles.writable, streamSecondInputPointer, 1],
    );
    final firstRead = streamProgram.invokeWithMemory(2, memory, <Object?>[
      writeHandles.readable,
      streamOutputPointer,
      1,
    ]);
    final secondWrite = await pendingWrite;
    final secondRead = streamProgram.invokeWithMemory(2, memory, <Object?>[
      writeHandles.readable,
      streamSecondOutputPointer,
      1,
    ]);
    if (firstWrite is! int ||
        firstRead is! int ||
        secondWrite is! int ||
        secondRead is! int) {
      throw StateError(
        'async stream write returned non-packed results: '
        '$firstWrite/$firstRead/$secondWrite/$secondRead',
      );
    }
    checksum += firstWrite;
    checksum += firstRead;
    checksum += secondWrite;
    checksum += secondRead;
    checksum += data.getUint32(streamSecondOutputPointer, Endian.little);
    streamProgram.invoke(3, <Object?>[writeHandles.readable]);
    streamProgram.invoke(4, <Object?>[writeHandles.writable]);

    final futureHandles = _unpackEndpointHandles(
      futureProgram.invoke(0, const <Object?>[]),
      'future.new',
    );
    final pendingFutureRead = futureProgram.invokeWithMemoryAsync(
      2,
      memory,
      <Object?>[futureHandles.readable, futureOutputPointer],
    );
    final futureWrite = futureProgram.invokeWithMemory(1, memory, <Object?>[
      futureHandles.writable,
      futureInputPointer,
    ]);
    final futureRead = await pendingFutureRead;
    if (futureWrite is! int || futureRead is! int) {
      throw StateError(
        'async future read returned non-packed results: $futureWrite/$futureRead',
      );
    }
    checksum += futureWrite;
    checksum += futureRead;
    checksum += data.getUint32(futureOutputPointer, Endian.little);
    futureProgram.invoke(3, <Object?>[futureHandles.readable]);
    futureProgram.invoke(4, <Object?>[futureHandles.writable]);
  }
  watch.stop();

  programs.expectNoLeaks();
  return _Metric(
    operations: options.iterations * 17,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

Future<_Metric> _benchmarkHandleMemoryProgramInvokeEvent(
  _Options options,
) async {
  final programs = _createHandleMemoryPrograms(maxBufferedElements: 1);
  final streamProgram = programs.streamProgram;
  final futureProgram = programs.futureProgram;
  final streamWaitables = WASIComponentWaitableHost(
    table: programs.streamHost.table,
    waitableResolvers: [programs.streamHost.waitableForHandle],
  );
  final futureWaitables = WASIComponentWaitableHost(
    table: programs.futureHost.table,
    waitableResolvers: [programs.futureHost.waitableForHandle],
  );
  final streamSet = streamWaitables.waitableSetNew();
  final futureSet = futureWaitables.waitableSetNew();
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  const streamInputPointer = 1024;
  const streamSecondInputPointer = 2048;
  const streamOutputPointer = 4096;
  const streamSecondOutputPointer = 5120;
  const futureInputPointer = 8192;
  const futureOutputPointer = 12288;
  const eventPointer = 16384;
  data.setUint32(streamInputPointer, 0x21, Endian.little);
  data.setUint32(streamSecondInputPointer, 0x33, Endian.little);
  data.setUint32(futureInputPointer, 0x55aa55aa, Endian.little);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final readHandles = _unpackEndpointHandles(
      streamProgram.invoke(0, const <Object?>[]),
      'stream.new',
    );
    streamWaitables.waitableJoin(readHandles.readable, streamSet);
    final blockedRead = streamProgram.invokeWithMemoryEvent(
      2,
      memory,
      <Object?>[readHandles.readable, streamOutputPointer, 1],
    );
    if (blockedRead != wasiComponentAsyncBlocked) {
      throw StateError('stream read event did not block: $blockedRead');
    }
    streamProgram.invokeWithMemory(1, memory, <Object?>[
      readHandles.writable,
      streamInputPointer,
      1,
    ]);
    checksum += await streamWaitables.waitableSetWaitToMemory(
      streamSet,
      memory,
      eventPointer,
    );
    checksum += data.getUint32(eventPointer, Endian.little);
    checksum += data.getUint32(eventPointer + 4, Endian.little);
    streamWaitables.waitableJoin(readHandles.readable, 0);
    streamProgram.invoke(3, <Object?>[readHandles.readable]);
    streamProgram.invoke(4, <Object?>[readHandles.writable]);

    final writeHandles = _unpackEndpointHandles(
      streamProgram.invoke(0, const <Object?>[]),
      'stream.new',
    );
    streamProgram.invokeWithMemory(1, memory, <Object?>[
      writeHandles.writable,
      streamInputPointer,
      1,
    ]);
    streamWaitables.waitableJoin(writeHandles.writable, streamSet);
    final blockedWrite = streamProgram.invokeWithMemoryEvent(
      1,
      memory,
      <Object?>[writeHandles.writable, streamSecondInputPointer, 1],
    );
    if (blockedWrite != wasiComponentAsyncBlocked) {
      throw StateError('stream write event did not block: $blockedWrite');
    }
    streamProgram.invokeWithMemory(2, memory, <Object?>[
      writeHandles.readable,
      streamOutputPointer,
      1,
    ]);
    checksum += await streamWaitables.waitableSetWaitToMemory(
      streamSet,
      memory,
      eventPointer,
    );
    checksum += data.getUint32(eventPointer, Endian.little);
    checksum += data.getUint32(eventPointer + 4, Endian.little);
    streamWaitables.waitableJoin(writeHandles.writable, 0);
    streamProgram.invokeWithMemory(2, memory, <Object?>[
      writeHandles.readable,
      streamSecondOutputPointer,
      1,
    ]);
    streamProgram.invoke(3, <Object?>[writeHandles.readable]);
    streamProgram.invoke(4, <Object?>[writeHandles.writable]);

    final futureHandles = _unpackEndpointHandles(
      futureProgram.invoke(0, const <Object?>[]),
      'future.new',
    );
    futureWaitables.waitableJoin(futureHandles.readable, futureSet);
    final blockedFuture = futureProgram.invokeWithMemoryEvent(
      2,
      memory,
      <Object?>[futureHandles.readable, futureOutputPointer],
    );
    if (blockedFuture != wasiComponentAsyncBlocked) {
      throw StateError('future read event did not block: $blockedFuture');
    }
    futureProgram.invokeWithMemory(1, memory, <Object?>[
      futureHandles.writable,
      futureInputPointer,
    ]);
    checksum += await futureWaitables.waitableSetWaitToMemory(
      futureSet,
      memory,
      eventPointer,
    );
    checksum += data.getUint32(eventPointer, Endian.little);
    checksum += data.getUint32(eventPointer + 4, Endian.little);
    futureWaitables.waitableJoin(futureHandles.readable, 0);
    futureProgram.invoke(3, <Object?>[futureHandles.readable]);
    futureProgram.invoke(4, <Object?>[futureHandles.writable]);

    final futureWriteHandles = _unpackEndpointHandles(
      futureProgram.invoke(0, const <Object?>[]),
      'future.new',
    );
    futureWaitables.waitableJoin(futureWriteHandles.writable, futureSet);
    final blockedFutureWrite = futureProgram.invokeWithMemoryEvent(
      1,
      memory,
      <Object?>[futureWriteHandles.writable, futureInputPointer],
    );
    if (blockedFutureWrite != wasiComponentAsyncBlocked) {
      throw StateError('future write event did not block: $blockedFutureWrite');
    }
    futureProgram.invokeWithMemory(2, memory, <Object?>[
      futureWriteHandles.readable,
      futureOutputPointer,
    ]);
    checksum += await futureWaitables.waitableSetWaitToMemory(
      futureSet,
      memory,
      eventPointer,
    );
    checksum += data.getUint32(eventPointer, Endian.little);
    checksum += data.getUint32(eventPointer + 4, Endian.little);
    futureWaitables.waitableJoin(futureWriteHandles.writable, 0);
    futureProgram.invoke(3, <Object?>[futureWriteHandles.readable]);
    futureProgram.invoke(4, <Object?>[futureWriteHandles.writable]);
  }
  watch.stop();

  streamWaitables.waitableSetDrop(streamSet);
  futureWaitables.waitableSetDrop(futureSet);
  programs.expectNoLeaks();
  return _Metric(
    operations: options.iterations * 34,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

Future<_Metric> _benchmarkHandleMemoryProgramSyncCancel(
  _Options options,
) async {
  final programs = _createHandleMemoryPrograms(
    maxBufferedElements: 1,
    includeCancel: true,
    cancelIsAsync: false,
  );
  final streamProgram = programs.streamProgram;
  final futureProgram = programs.futureProgram;
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  const streamInputPointer = 1024;
  const streamSecondInputPointer = 2048;
  const streamOutputPointer = 4096;
  const futureInputPointer = 8192;
  const futureOutputPointer = 12288;
  data.setUint32(streamInputPointer, 0x21, Endian.little);
  data.setUint32(streamSecondInputPointer, 0x33, Endian.little);
  data.setUint32(futureInputPointer, 0x55aa55aa, Endian.little);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final readHandles = _unpackEndpointHandles(
      streamProgram.invoke(0, const <Object?>[]),
      'stream.new',
    );
    final blockedRead = streamProgram.invokeWithMemoryEvent(
      2,
      memory,
      <Object?>[readHandles.readable, streamOutputPointer, 1],
    );
    if (blockedRead != wasiComponentAsyncBlocked) {
      throw StateError('stream read cancel benchmark did not block.');
    }
    checksum += await _expectPackedResult(
      streamProgram.invokeAsync(3, <Object?>[readHandles.readable]),
      'stream.cancel-read',
    );
    streamProgram.invoke(5, <Object?>[readHandles.readable]);
    streamProgram.invoke(6, <Object?>[readHandles.writable]);

    final writeHandles = _unpackEndpointHandles(
      streamProgram.invoke(0, const <Object?>[]),
      'stream.new',
    );
    checksum += _expectPackedValue(
      streamProgram.invokeWithMemory(1, memory, <Object?>[
        writeHandles.writable,
        streamInputPointer,
        1,
      ]),
      'stream.write',
    );
    final blockedWrite = streamProgram.invokeWithMemoryEvent(
      1,
      memory,
      <Object?>[writeHandles.writable, streamSecondInputPointer, 1],
    );
    if (blockedWrite != wasiComponentAsyncBlocked) {
      throw StateError('stream write cancel benchmark did not block.');
    }
    checksum += await _expectPackedResult(
      streamProgram.invokeAsync(4, <Object?>[writeHandles.writable]),
      'stream.cancel-write',
    );
    streamProgram.invoke(5, <Object?>[writeHandles.readable]);
    streamProgram.invoke(6, <Object?>[writeHandles.writable]);

    final futureReadHandles = _unpackEndpointHandles(
      futureProgram.invoke(0, const <Object?>[]),
      'future.new',
    );
    final blockedFutureRead = futureProgram.invokeWithMemoryEvent(
      2,
      memory,
      <Object?>[futureReadHandles.readable, futureOutputPointer],
    );
    if (blockedFutureRead != wasiComponentAsyncBlocked) {
      throw StateError('future read cancel benchmark did not block.');
    }
    checksum += await _expectPackedResult(
      futureProgram.invokeAsync(3, <Object?>[futureReadHandles.readable]),
      'future.cancel-read',
    );
    futureProgram.invoke(5, <Object?>[futureReadHandles.readable]);
    futureProgram.invoke(6, <Object?>[futureReadHandles.writable]);

    final futureWriteHandles = _unpackEndpointHandles(
      futureProgram.invoke(0, const <Object?>[]),
      'future.new',
    );
    final blockedFutureWrite = futureProgram.invokeWithMemoryEvent(
      1,
      memory,
      <Object?>[futureWriteHandles.writable, futureInputPointer],
    );
    if (blockedFutureWrite != wasiComponentAsyncBlocked) {
      throw StateError('future write cancel benchmark did not block.');
    }
    checksum += await _expectPackedResult(
      futureProgram.invokeAsync(4, <Object?>[futureWriteHandles.writable]),
      'future.cancel-write',
    );
    futureProgram.invoke(5, <Object?>[futureWriteHandles.readable]);
    futureProgram.invoke(6, <Object?>[futureWriteHandles.writable]);
  }
  watch.stop();

  programs.expectNoLeaks();
  return _Metric(
    operations: options.iterations * 21,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

Future<int> _expectPackedResult(
  Future<Object?> result,
  String operation,
) async {
  return _expectPackedValue(await result, operation);
}

int _expectPackedValue(Object? value, String operation) {
  if (value is! int) {
    throw StateError('$operation returned non-packed result: $value');
  }
  return value;
}

_HandleMemoryPrograms _createHandleMemoryPrograms({
  int? maxBufferedElements,
  bool includeCancel = false,
  bool cancelIsAsync = true,
}) {
  final streamComponent = WasmComponent.decode(_streamU32TypeComponentBytes());
  final streamHost = WASIComponentAsyncHost()
    ..defineStreamTypeFromComponent<int>(
      streamComponent,
      0,
      'benchmark-u32-stream',
      maxBufferedElements: maxBufferedElements,
    );
  final streamProgram = WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      streamHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamNew,
          typeIndex: 0,
        ),
      ),
      streamHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamWrite,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      streamHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamRead,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      if (includeCancel) ...[
        streamHost.bindCanonicalDefinition(
          WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamCancelRead,
            typeIndex: 0,
            isAsync: cancelIsAsync,
          ),
        ),
        streamHost.bindCanonicalDefinition(
          WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamCancelWrite,
            typeIndex: 0,
            isAsync: cancelIsAsync,
          ),
        ),
      ],
      streamHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropReadable,
          typeIndex: 0,
        ),
      ),
      streamHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.streamDropWritable,
          typeIndex: 0,
        ),
      ),
    ],
  );

  final futureComponent = WasmComponent.decode(_futureU32TypeComponentBytes());
  final futureHost = WASIComponentAsyncHost()
    ..defineFutureTypeFromComponent<int>(
      futureComponent,
      0,
      'benchmark-u32-future',
    );
  final futureProgram = WASIComponentCanonicalAsyncHandleProgram(
    operations: [
      futureHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureNew,
          typeIndex: 0,
        ),
      ),
      futureHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureWrite,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      futureHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureRead,
          typeIndex: 0,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      ),
      if (includeCancel) ...[
        futureHost.bindCanonicalDefinition(
          WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.futureCancelRead,
            typeIndex: 0,
            isAsync: cancelIsAsync,
          ),
        ),
        futureHost.bindCanonicalDefinition(
          WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.futureCancelWrite,
            typeIndex: 0,
            isAsync: cancelIsAsync,
          ),
        ),
      ],
      futureHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropReadable,
          typeIndex: 0,
        ),
      ),
      futureHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.futureDropWritable,
          typeIndex: 0,
        ),
      ),
    ],
  );

  return _HandleMemoryPrograms(
    streamHost: streamHost,
    streamProgram: streamProgram,
    futureHost: futureHost,
    futureProgram: futureProgram,
  );
}

WASIComponentAsyncEndpointHandles _unpackEndpointHandles(
  Object? packed,
  String operation,
) {
  if (packed is! int) {
    throw StateError('$operation returned non-packed handles: $packed');
  }
  return WASIComponentAsyncEndpointHandles.unpack(packed);
}

final class _HandleMemoryPrograms {
  const _HandleMemoryPrograms({
    required this.streamHost,
    required this.streamProgram,
    required this.futureHost,
    required this.futureProgram,
  });

  final WASIComponentAsyncHost streamHost;
  final WASIComponentCanonicalAsyncHandleProgram streamProgram;
  final WASIComponentAsyncHost futureHost;
  final WASIComponentCanonicalAsyncHandleProgram futureProgram;

  void expectNoLeaks() {
    if (streamHost.table.activeCount != 0) {
      throw StateError(
        'stream memory program leaked ${streamHost.table.activeCount} endpoints',
      );
    }
    if (futureHost.table.activeCount != 0) {
      throw StateError(
        'future memory program leaked ${futureHost.table.activeCount} endpoints',
      );
    }
  }
}

_Metric _benchmarkStreamMemoryCopy(_Options options) {
  final component = WasmComponent.decode(_streamU32TypeComponentBytes());
  final host = WASIComponentAsyncHost()
    ..defineStreamTypeFromComponent<int>(component, 0, 'benchmark-u32-stream');
  final newOperation = host.bindCanonicalDefinition(
    const WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.streamNew,
      typeIndex: 0,
    ),
  );
  final readOperation = host.bindCanonicalDefinition(
    const WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.streamRead,
      typeIndex: 0,
      options: [
        WasmComponentCanonicalOption(
          kind: WasmComponentCanonicalOptionKind.memory,
          index: 0,
        ),
      ],
    ),
  );
  final writeOperation = host.bindCanonicalDefinition(
    const WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.streamWrite,
      typeIndex: 0,
      options: [
        WasmComponentCanonicalOption(
          kind: WasmComponentCanonicalOptionKind.memory,
          index: 0,
        ),
      ],
    ),
  );
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  final inputPointer = 1024;
  final outputPointer = 4096;
  for (var i = 0; i < options.batchSize; i++) {
    data.setUint32(inputPointer + i * 4, i, Endian.little);
  }
  final stream = newOperation.streamNew() as WASIComponentStream<int>;
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final writeResult = writeOperation.streamWriteFromMemory(
      stream.writable,
      memory,
      inputPointer,
      options.batchSize,
    );
    final readResult = readOperation.streamReadToMemory(
      stream.readable,
      memory,
      outputPointer,
      options.batchSize,
    );
    checksum += writeResult.packedResult;
    checksum += readResult.packedResult;
    checksum += data.getUint32(outputPointer, Endian.little);
  }
  watch.stop();

  stream.readable.drop();
  stream.writable.drop();
  return _Metric(
    operations: options.iterations * options.batchSize * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkFutureMemoryCopy(int iterations) {
  final component = WasmComponent.decode(_futureU32TypeComponentBytes());
  final host = WASIComponentAsyncHost()
    ..defineFutureTypeFromComponent<int>(component, 0, 'benchmark-u32-future');
  final newOperation = host.bindCanonicalDefinition(
    const WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.futureNew,
      typeIndex: 0,
    ),
  );
  final readOperation = host.bindCanonicalDefinition(
    const WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.futureRead,
      typeIndex: 0,
      options: [
        WasmComponentCanonicalOption(
          kind: WasmComponentCanonicalOptionKind.memory,
          index: 0,
        ),
      ],
    ),
  );
  final writeOperation = host.bindCanonicalDefinition(
    const WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.futureWrite,
      typeIndex: 0,
      options: [
        WasmComponentCanonicalOption(
          kind: WasmComponentCanonicalOptionKind.memory,
          index: 0,
        ),
      ],
    ),
  );
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  const inputPointer = 1024;
  const outputPointer = 4096;
  data.setUint32(inputPointer, 0x55aa55aa, Endian.little);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final future = newOperation.futureNew() as WASIComponentFuture<int>;
    final writeResult = writeOperation.futureWriteFromMemory(
      future.writable,
      memory,
      inputPointer,
    );
    final readResult = readOperation.futureReadToMemory(
      future.readable,
      memory,
      outputPointer,
    );
    checksum += writeResult.packedResult;
    checksum += readResult.packedResult;
    checksum += data.getUint32(outputPointer, Endian.little);
    future.readable.drop();
    future.writable.drop();
  }
  watch.stop();

  return _Metric(
    operations: iterations * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

void _printText(Map<String, Object?> payload) {
  stdout
    ..writeln('WASI component async benchmark')
    ..writeln('  iterations: ${payload['iterations']}')
    ..writeln('  batch size: ${payload['batch_size']}');
  for (final name in const <String>[
    'stream_round_trip',
    'stream_cancel',
    'stream_pending_read_completion',
    'stream_pending_write_completion',
    'stream_forward_sandwich',
    'future_complete_read_drop',
    'future_pending_read_completion',
    'backpressure_counter',
    'waitable_set_delivery',
    'program_invoke',
    'unit_program_invoke',
    'handle_program_invoke',
    'handle_memory_program_invoke',
    'handle_memory_program_invoke_async',
    'handle_memory_program_invoke_event',
    'handle_memory_program_sync_cancel',
    'stream_memory_copy',
    'future_memory_copy',
  ]) {
    final metric = payload[name]! as Map<String, Object?>;
    stdout
      ..writeln('  $name operations: ${metric['operations']}')
      ..writeln('  $name total us: ${metric['total_us']}')
      ..writeln('  $name per operation us: ${metric['per_operation_us']}');
  }
}

Uint8List _asyncProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x05,
  0x02,
  0x66,
  0x00,
  0x65,
  0x00,
  0x08,
  0x11,
  0x06,
  0x0e,
  0x00,
  0x0f,
  0x00,
  0x00,
  0x10,
  0x00,
  0x00,
  0x15,
  0x01,
  0x16,
  0x01,
  0x00,
  0x17,
  0x01,
  0x00,
]);

Uint8List _asyncHandleProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x05,
  0x02,
  0x66,
  0x00,
  0x65,
  0x00,
  0x08,
  0x19,
  0x0a,
  0x0e,
  0x00,
  0x0f,
  0x00,
  0x00,
  0x10,
  0x00,
  0x00,
  0x13,
  0x00,
  0x14,
  0x00,
  0x15,
  0x01,
  0x16,
  0x01,
  0x00,
  0x17,
  0x01,
  0x00,
  0x1a,
  0x01,
  0x1b,
  0x01,
]);

Uint8List _streamU32TypeComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x04,
  0x01,
  0x66,
  0x01,
  0x79,
]);

Uint8List _futureU32TypeComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x04,
  0x01,
  0x65,
  0x01,
  0x79,
]);

void _printUsage() {
  stdout.writeln('''
Usage: dart run tool/wasi_component_async_benchmark.dart [options]

Options:
  --iterations=<n>  Operation repetitions. Default: $_defaultIterations.
  --batch-size=<n>  Values per stream write/read batch. Default: $_defaultBatchSize.
  --json            Print machine-readable JSON.
  --help            Print this help.
''');
}

final class _Options {
  const _Options({
    required this.iterations,
    required this.batchSize,
    required this.json,
    required this.help,
  });

  final int iterations;
  final int batchSize;
  final bool json;
  final bool help;

  _Options copyWith({int? iterations, int? batchSize}) {
    return _Options(
      iterations: iterations ?? this.iterations,
      batchSize: batchSize ?? this.batchSize,
      json: json,
      help: help,
    );
  }

  static _Options parse(List<String> args) {
    var iterations = _defaultIterations;
    var batchSize = _defaultBatchSize;
    var json = false;
    var help = false;

    for (final arg in args) {
      if (arg == '--json') {
        json = true;
      } else if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg.startsWith('--iterations=')) {
        iterations = _parsePositiveInt(
          arg.substring('--iterations='.length),
          '--iterations',
        );
      } else if (arg.startsWith('--batch-size=')) {
        batchSize = _parsePositiveInt(
          arg.substring('--batch-size='.length),
          '--batch-size',
        );
      } else {
        throw ArgumentError('Unknown option: $arg');
      }
    }

    return _Options(
      iterations: iterations,
      batchSize: batchSize,
      json: json,
      help: help,
    );
  }
}

int _parsePositiveInt(String value, String option) {
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0) {
    throw ArgumentError('$option must be a positive integer.');
  }
  return parsed;
}

final class _Metric {
  const _Metric({
    required this.operations,
    required this.totalMicros,
    required this.checksum,
  });

  final int operations;
  final int totalMicros;
  final int checksum;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'operations': operations,
      'total_us': totalMicros,
      'per_operation_us': totalMicros / operations,
      'checksum': checksum,
    };
  }
}
