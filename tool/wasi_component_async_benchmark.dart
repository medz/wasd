import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

const int _defaultIterations = 50000;
const int _defaultBatchSize = 32;
const int _warmupIterations = 1000;

void main(List<String> args) {
  final options = _Options.parse(args);
  if (options.help) {
    _printUsage();
    return;
  }

  _runWarmup(options);

  final streamRoundTrip = _benchmarkStreamRoundTrip(options);
  final streamCancel = _benchmarkStreamCancel(options);
  final futureCompleteReadDrop = _benchmarkFutureCompleteReadDrop(
    options.iterations,
  );
  final programInvoke = _benchmarkProgramInvoke(options);

  final payload = <String, Object?>{
    'iterations': options.iterations,
    'batch_size': options.batchSize,
    'stream_round_trip': streamRoundTrip.toJson(),
    'stream_cancel': streamCancel.toJson(),
    'future_complete_read_drop': futureCompleteReadDrop.toJson(),
    'program_invoke': programInvoke.toJson(),
  };

  if (options.json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
  } else {
    _printText(payload);
  }
}

void _runWarmup(_Options options) {
  final warmup = options.copyWith(iterations: _warmupIterations);
  _benchmarkStreamRoundTrip(warmup);
  _benchmarkStreamCancel(warmup);
  _benchmarkFutureCompleteReadDrop(_warmupIterations);
  _benchmarkProgramInvoke(warmup);
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

_Metric _benchmarkProgramInvoke(_Options options) {
  final component = WasmComponent.decode(_asyncProgramBytes());
  final host = WASIComponentAsyncHost()
    ..defineStreamTypeFromComponent<int>(component, 0, 'benchmark-stream')
    ..defineFutureTypeFromComponent<int>(component, 1, 'benchmark-future');
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

void _printText(Map<String, Object?> payload) {
  stdout
    ..writeln('WASI component async benchmark')
    ..writeln('  iterations: ${payload['iterations']}')
    ..writeln('  batch size: ${payload['batch_size']}');
  for (final name in const <String>[
    'stream_round_trip',
    'stream_cancel',
    'future_complete_read_drop',
    'program_invoke',
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
