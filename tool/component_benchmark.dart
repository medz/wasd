import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

const int _defaultIterations = 200;
const int _defaultStreams = 512;
const int _warmupIterations = 10;

void main(List<String> args) {
  final options = _Options.parse(args);
  if (options.help) {
    _printUsage();
    return;
  }

  final bytes = _benchmarkComponentBytes(options.streams);
  final expectedErrors = options.streams;
  for (var i = 0; i < _warmupIterations; i++) {
    final errors = WasmComponent.decode(bytes).validate();
    if (errors.length != expectedErrors) {
      stderr.writeln(
        'Unexpected validation error count: expected=$expectedErrors '
        'actual=${errors.length}',
      );
      exitCode = 2;
      return;
    }
  }

  var decodedTypeCount = 0;
  final decodeWatch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    decodedTypeCount += WasmComponent.decode(bytes).typeDefinitions.length;
  }
  decodeWatch.stop();

  final component = WasmComponent.decode(bytes);
  var validationErrorCount = 0;
  final validateWatch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    validationErrorCount += component.validate().length;
  }
  validateWatch.stop();

  final payload = <String, Object?>{
    'component_bytes': bytes.length,
    'iterations': options.iterations,
    'type_definitions': component.typeDefinitions.length,
    'stream_type_definitions': options.streams,
    'expected_errors_per_validate': expectedErrors,
    'decode': _metricJson(decodeWatch.elapsedMicroseconds, options.iterations),
    'validate': _metricJson(
      validateWatch.elapsedMicroseconds,
      options.iterations,
    ),
    'decoded_type_count': decodedTypeCount,
    'validation_error_count': validationErrorCount,
  };

  if (options.json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
  } else {
    _printText(payload);
  }
}

Map<String, Object?> _metricJson(int totalMicros, int iterations) {
  return <String, Object?>{
    'total_us': totalMicros,
    'per_iteration_us': totalMicros / iterations,
  };
}

void _printText(Map<String, Object?> payload) {
  final decode = payload['decode']! as Map<String, Object?>;
  final validate = payload['validate']! as Map<String, Object?>;
  stdout
    ..writeln('component benchmark')
    ..writeln('  bytes: ${payload['component_bytes']}')
    ..writeln('  iterations: ${payload['iterations']}')
    ..writeln('  type definitions: ${payload['type_definitions']}')
    ..writeln('  stream definitions: ${payload['stream_type_definitions']}')
    ..writeln('  decode total us: ${decode['total_us']}')
    ..writeln('  decode per iteration us: ${decode['per_iteration_us']}')
    ..writeln('  validate total us: ${validate['total_us']}')
    ..writeln('  validate per iteration us: ${validate['per_iteration_us']}');
}

Uint8List _benchmarkComponentBytes(int streamTypes) {
  final typePayload = <int>[];
  _writeVarUint32(typePayload, streamTypes + 3);

  // type[0] = resource rep i32
  typePayload.addAll(const <int>[0x3f, 0x7f, 0x00]);

  // type[1] = borrow type[0]
  typePayload.addAll(const <int>[0x68, 0x00]);

  // type[2] = tuple<type[1]>
  typePayload.addAll(const <int>[0x6f, 0x01, 0x01]);

  // Repeated stream<type[2]> types exercise validation memoization. Without a
  // shared cache, every stream definition would recursively rediscover the same
  // borrow-containing type graph.
  for (var i = 0; i < streamTypes; i++) {
    typePayload.addAll(const <int>[0x66, 0x01, 0x02]);
  }

  final bytes = <int>[0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, 0x07];
  _writeVarUint32(bytes, typePayload.length);
  bytes.addAll(typePayload);
  return Uint8List.fromList(bytes);
}

void _writeVarUint32(List<int> out, int value) {
  var remaining = value;
  do {
    var byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) {
      byte |= 0x80;
    }
    out.add(byte);
  } while (remaining != 0);
}

void _printUsage() {
  stdout.writeln('''
Usage: dart run tool/component_benchmark.dart [options]

Options:
  --iterations=<n>  Decode/validate repetitions. Default: $_defaultIterations.
  --streams=<n>     Number of repeated stream type definitions. Default: $_defaultStreams.
  --json            Print machine-readable JSON.
  --help            Show this help.
''');
}

final class _Options {
  const _Options({
    required this.iterations,
    required this.streams,
    required this.json,
    required this.help,
  });

  final int iterations;
  final int streams;
  final bool json;
  final bool help;

  factory _Options.parse(List<String> args) {
    var iterations = _defaultIterations;
    var streams = _defaultStreams;
    var json = false;
    var help = false;

    for (final arg in args) {
      if (arg == '--json') {
        json = true;
      } else if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg.startsWith('--iterations=')) {
        iterations = _positiveInt(arg, '--iterations');
      } else if (arg.startsWith('--streams=')) {
        streams = _positiveInt(arg, '--streams');
      } else {
        throw ArgumentError('Unsupported argument: $arg');
      }
    }

    return _Options(
      iterations: iterations,
      streams: streams,
      json: json,
      help: help,
    );
  }

  static int _positiveInt(String arg, String name) {
    final value = int.tryParse(arg.substring(name.length + 1));
    if (value == null || value <= 0) {
      throw ArgumentError('$name must be a positive integer.');
    }
    return value;
  }
}
