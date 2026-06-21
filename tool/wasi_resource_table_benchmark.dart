import 'dart:convert';
import 'dart:io';

import 'package:wasd/src/wasi/component/resource_table.dart';

const int _defaultIterations = 100000;
const int _defaultResources = 1024;
const int _warmupIterations = 1000;

void main(List<String> args) {
  final options = _Options.parse(args);
  if (options.help) {
    _printUsage();
    return;
  }

  _runWarmup(options);

  final insertGetDrop = _benchmarkInsertGetDrop(options.iterations);
  final borrow = _benchmarkBorrow(options);
  final dropCallbacks = _benchmarkDropCallbacks(options.iterations);

  final payload = <String, Object?>{
    'iterations': options.iterations,
    'resources': options.resources,
    'insert_get_drop': insertGetDrop.toJson(),
    'borrow': borrow.toJson(),
    'drop_callbacks': dropCallbacks.toJson(),
  };

  if (options.json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
  } else {
    _printText(payload);
  }
}

void _runWarmup(_Options options) {
  _benchmarkInsertGetDrop(_warmupIterations);
  _benchmarkBorrow(options.copyWith(iterations: _warmupIterations));
  _benchmarkDropCallbacks(_warmupIterations);
}

_Metric _benchmarkInsertGetDrop(int iterations) {
  final table = WASIComponentResourceTable();
  final resourceType = table.defineType<int>('resource');
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final handle = table.resourceNew<int>(resourceType, i);
    checksum += table.resourceRep<int>(resourceType, handle);
    table.resourceDrop<int>(resourceType, handle);
    if (table.contains(handle)) {
      throw StateError('stale handle remained live: $handle');
    }
  }
  watch.stop();

  if (table.activeCount != 0) {
    throw StateError('resource table leaked ${table.activeCount} resources');
  }
  return _Metric(
    operations: iterations * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkBorrow(_Options options) {
  final table = WASIComponentResourceTable();
  final resourceType = table.defineType<int>('resource');
  final handles = <int>[];
  for (var i = 0; i < options.resources; i++) {
    handles.add(table.insert<int>(resourceType, i));
  }

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final handle = handles[i % handles.length];
    table.borrow<int, void>(resourceType, handle, (resource) {
      checksum += resource;
    });
  }
  watch.stop();

  for (final handle in handles) {
    table.drop<int>(resourceType, handle);
  }
  if (table.activeCount != 0) {
    throw StateError('resource table leaked ${table.activeCount} resources');
  }
  return _Metric(
    operations: options.iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkDropCallbacks(int iterations) {
  final table = WASIComponentResourceTable();
  var checksum = 0;
  final resourceType = table.defineType<int>(
    'resource',
    onDrop: (resource) {
      checksum += resource;
    },
  );

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final handle = table.resourceNew<int>(resourceType, i);
    table.resourceDrop<int>(resourceType, handle);
  }
  watch.stop();

  if (table.activeCount != 0) {
    throw StateError('resource table leaked ${table.activeCount} resources');
  }
  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

void _printText(Map<String, Object?> payload) {
  stdout
    ..writeln('WASI component resource table benchmark')
    ..writeln('  iterations: ${payload['iterations']}')
    ..writeln('  resources: ${payload['resources']}');
  for (final name in const <String>[
    'insert_get_drop',
    'borrow',
    'drop_callbacks',
  ]) {
    final metric = payload[name]! as Map<String, Object?>;
    stdout
      ..writeln('  $name operations: ${metric['operations']}')
      ..writeln('  $name total us: ${metric['total_us']}')
      ..writeln('  $name per operation us: ${metric['per_operation_us']}');
  }
}

void _printUsage() {
  stdout.writeln('''
Usage: dart run tool/wasi_resource_table_benchmark.dart [options]

Options:
  --iterations=<n>  Operation repetitions. Default: $_defaultIterations.
  --resources=<n>   Live resources for borrow lookup. Default: $_defaultResources.
  --json            Print machine-readable JSON.
  --help            Show this help.
''');
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

final class _Options {
  const _Options({
    required this.iterations,
    required this.resources,
    required this.json,
    required this.help,
  });

  final int iterations;
  final int resources;
  final bool json;
  final bool help;

  _Options copyWith({int? iterations, int? resources}) {
    return _Options(
      iterations: iterations ?? this.iterations,
      resources: resources ?? this.resources,
      json: json,
      help: help,
    );
  }

  factory _Options.parse(List<String> args) {
    var iterations = _defaultIterations;
    var resources = _defaultResources;
    var json = false;
    var help = false;

    for (final arg in args) {
      if (arg == '--json') {
        json = true;
      } else if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg.startsWith('--iterations=')) {
        iterations = _positiveInt(arg, '--iterations');
      } else if (arg.startsWith('--resources=')) {
        resources = _positiveInt(arg, '--resources');
      } else {
        throw ArgumentError('Unsupported argument: $arg');
      }
    }

    return _Options(
      iterations: iterations,
      resources: resources,
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
