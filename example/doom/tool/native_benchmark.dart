import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/vm.dart';
import 'package:wasd_doom_example/src/doom_runtime.dart';
import 'package:wasd_doom_example/src/doom_worker.dart';

const String _defaultWasmPath = 'assets/doom/doom.wasm';
const String _defaultIwadPath = 'assets/doom/doom1.wad';
const int _defaultFrames = 240;
const String _defaultReportPath =
    '.dart_tool/doom_native_benchmark/report.json';

Future<void> main(List<String> args) async {
  final code = await _run(args);
  if (code != 0) {
    exitCode = code;
  }
}

Future<int> _run(List<String> args) async {
  final options = _parseArgs(args);
  if (options.containsKey('help')) {
    _printUsage();
    return 0;
  }

  final wasmPath = options['wasm'] ?? _defaultWasmPath;
  final iwadPath = options['iwad'] ?? _defaultIwadPath;
  final frames = _parsePositiveInt(options['frames'], _defaultFrames);
  final reportPath = options['report'] ?? _defaultReportPath;
  final selectedCases = _parseCases(options['cases']);

  final wasmFile = File(wasmPath);
  final iwadFile = File(iwadPath);
  if (!wasmFile.existsSync()) {
    stderr.writeln('Missing wasm fixture: $wasmPath');
    return 2;
  }
  if (!iwadFile.existsSync()) {
    stderr.writeln('Missing IWAD fixture: $iwadPath');
    return 2;
  }

  final wasmBytes = await wasmFile.readAsBytes();
  final iwadBytes = await iwadFile.readAsBytes();

  final runs = <_BenchmarkSpec>[
    const _BenchmarkSpec(
      'inline-none',
      _BenchmarkMode.inline,
      DoomFrameTransport.none,
    ),
    const _BenchmarkSpec(
      'inline-rgba',
      _BenchmarkMode.inline,
      DoomFrameTransport.rgba,
    ),
    const _BenchmarkSpec(
      'inline-bmp',
      _BenchmarkMode.inline,
      DoomFrameTransport.bmp,
    ),
    const _BenchmarkSpec(
      'worker-none',
      _BenchmarkMode.worker,
      DoomFrameTransport.none,
    ),
    const _BenchmarkSpec(
      'worker-rgba',
      _BenchmarkMode.worker,
      DoomFrameTransport.rgba,
    ),
    const _BenchmarkSpec(
      'worker-bmp',
      _BenchmarkMode.worker,
      DoomFrameTransport.bmp,
    ),
  ];

  final results = <_BenchmarkResult>[];
  for (final spec in runs) {
    if (selectedCases != null && !selectedCases.contains(spec.name)) {
      continue;
    }
    stdout.writeln('== ${spec.name} ==');
    final result = spec.mode == _BenchmarkMode.inline
        ? await _runInlineBenchmark(spec, wasmBytes, iwadBytes, frames)
        : await _runWorkerBenchmark(spec, wasmBytes, iwadBytes, frames);
    results.add(result);
    stdout.writeln(result.describe());
  }

  await _writeReport(reportPath, wasmPath, iwadPath, frames, results);
  stdout.writeln('report=$reportPath');
  return 0;
}

Future<_BenchmarkResult> _runInlineBenchmark(
  _BenchmarkSpec spec,
  Uint8List wasmBytes,
  Uint8List iwadBytes,
  int frames,
) async {
  final stopwatch = Stopwatch()..start();
  DoomProfileMap? profile;
  WasmVmProfileSnapshot? vmProfile;
  var startUs = 0;
  var firstFrameUs = 0;
  var frameCount = 0;
  var totalBytes = 0;
  final runtime = DoomRuntime(
    emit: (message) {
      if (message['type'] == 'log') {
        final line = message['line'];
        if (line == 'running wasi _start...' && startUs == 0) {
          startUs = stopwatch.elapsedMicroseconds;
        }
      }
      if (message['type'] == doomRunnerMessageProfile) {
        profile = _profileFromMessage(message['imports']);
      }
      if (message['type'] != doomRunnerMessageFrame) {
        return;
      }
      frameCount++;
      firstFrameUs = firstFrameUs == 0
          ? stopwatch.elapsedMicroseconds
          : firstFrameUs;
      final bytes = messageBytesAsUint8List(message['bytes']);
      if (bytes != null) {
        totalBytes += bytes.length;
      }
    },
    frameTransport: spec.transport,
    frameIntervalUs: 0,
    maxFrames: frames,
    enableProfiling: true,
  );
  WasmVmProfiler.start();
  await runtime.run(
    wasmBytes: Uint8List.fromList(wasmBytes),
    iwadBytes: Uint8List.fromList(iwadBytes),
  );
  vmProfile = WasmVmProfiler.stop();
  stopwatch.stop();
  return _BenchmarkResult(
    name: spec.name,
    mode: spec.mode.name,
    format: _transportName(spec.transport),
    frames: frameCount,
    startUs: startUs,
    firstFrameUs: firstFrameUs,
    totalUs: stopwatch.elapsedMicroseconds,
    totalBytes: totalBytes,
    profile: profile,
    vmProfile: vmProfile,
  );
}

Future<_BenchmarkResult> _runWorkerBenchmark(
  _BenchmarkSpec spec,
  Uint8List wasmBytes,
  Uint8List iwadBytes,
  int frames,
) async {
  final stopwatch = Stopwatch()..start();
  DoomProfileMap? profile;
  var startUs = 0;
  var firstFrameUs = 0;
  var frameCount = 0;
  var totalBytes = 0;

  final manager = IsolateManager<Object?, Object?>.createCustom(
    doomRunnerWorker,
    workerName: 'doomRunnerWorker',
  );
  await manager.start();

  final receivePort = ReceivePort();
  final exitCompleter = Completer<void>();
  late final StreamSubscription<Object?> subscription;
  subscription = receivePort.listen((rawMessage) {
    final message = normalizeDoomRunnerMessage(rawMessage);
    final type = message['type'];
    if (type == doomRunnerMessageFrame) {
      frameCount++;
      firstFrameUs = firstFrameUs == 0
          ? stopwatch.elapsedMicroseconds
          : firstFrameUs;
      final bytes = message['bytes'];
      if (bytes is TransferableTypedData) {
        totalBytes += bytes.materialize().lengthInBytes;
      } else {
        final typed = messageBytesAsUint8List(bytes);
        if (typed != null) {
          totalBytes += typed.length;
        }
      }
      return;
    }
    if (type == 'log') {
      final line = message['line'];
      if (line == 'running wasi _start...' && startUs == 0) {
        startUs = stopwatch.elapsedMicroseconds;
      }
      return;
    }
    if (type == doomRunnerMessageProfile) {
      profile = _profileFromMessage(message['imports']);
      return;
    }
    if (type == doomRunnerMessageExit || type == doomRunnerMessageError) {
      if (!exitCompleter.isCompleted) {
        exitCompleter.complete();
      }
    }
  });

  try {
    final run = manager.compute(
      <String, Object?>{
        'type': doomRunnerCommandStart,
        'wasmBytes': Uint8List.fromList(wasmBytes),
        'iwadBytes': Uint8List.fromList(iwadBytes),
        'frameTransport': switch (spec.transport) {
          DoomFrameTransport.none => doomFrameFormatNone,
          DoomFrameTransport.bmp => doomFrameFormatBmp,
          DoomFrameTransport.rgba => doomFrameFormatRgba,
        },
        'frameIntervalUs': 0,
        'maxFrames': frames,
        'uiPort': receivePort.sendPort,
      },
      transferables: <Object>[wasmBytes.buffer, iwadBytes.buffer],
    );
    await exitCompleter.future.timeout(const Duration(seconds: 120));
    stopwatch.stop();
    try {
      await run.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // Native benchmark treats the worker's exit message as the authoritative
      // completion signal; isolate_manager shutdown happens in finally.
    }
  } finally {
    if (stopwatch.isRunning) {
      stopwatch.stop();
    }
    await subscription.cancel();
    receivePort.close();
    await manager.stop();
  }

  return _BenchmarkResult(
    name: spec.name,
    mode: spec.mode.name,
    format: _transportName(spec.transport),
    frames: frameCount,
    startUs: startUs,
    firstFrameUs: firstFrameUs,
    totalUs: stopwatch.elapsedMicroseconds,
    totalBytes: totalBytes,
    profile: profile,
    vmProfile: null,
  );
}

DoomProfileMap? _profileFromMessage(Object? value) {
  if (value is! Map) {
    return null;
  }
  final result = <String, Map<String, int>>{};
  for (final entry in value.entries) {
    final key = entry.key;
    final data = entry.value;
    if (key is! String || data is! Map) {
      continue;
    }
    final count = asIntOrNull(data['count']);
    final totalUs = asIntOrNull(data['totalUs']);
    if (count == null || totalUs == null) {
      continue;
    }
    result[key] = <String, int>{'count': count, 'totalUs': totalUs};
  }
  return result.isEmpty ? null : result;
}

Map<String, String> _parseArgs(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--help' || arg == '-h') {
      result['help'] = 'true';
      continue;
    }
    if (!arg.startsWith('--')) {
      continue;
    }
    final eq = arg.indexOf('=');
    if (eq != -1) {
      result[arg.substring(2, eq)] = arg.substring(eq + 1);
      continue;
    }
    final key = arg.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      result[key] = args[i + 1];
      i++;
      continue;
    }
    result[key] = 'true';
  }
  return result;
}

Set<String>? _parseCases(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }
  final values = raw
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet();
  return values.isEmpty ? null : values;
}

int _parsePositiveInt(String? raw, int fallback) {
  final parsed = raw == null ? fallback : int.tryParse(raw) ?? fallback;
  return parsed <= 0 ? fallback : parsed;
}

String _transportName(DoomFrameTransport transport) => switch (transport) {
  DoomFrameTransport.none => doomFrameFormatNone,
  DoomFrameTransport.bmp => doomFrameFormatBmp,
  DoomFrameTransport.rgba => doomFrameFormatRgba,
};

Future<void> _writeReport(
  String reportPath,
  String wasmPath,
  String iwadPath,
  int frames,
  List<_BenchmarkResult> results,
) async {
  final file = File(reportPath);
  await file.parent.create(recursive: true);
  final payload = <String, Object?>{
    'wasm': wasmPath,
    'iwad': iwadPath,
    'frames': frames,
    'results': results.map((result) => result.toJson()).toList(growable: false),
  };
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
}

void _printUsage() {
  stdout.writeln('Usage: dart run tool/native_benchmark.dart [options]');
  stdout.writeln('Options:');
  stdout.writeln('  --wasm=<path>     Default: $_defaultWasmPath');
  stdout.writeln('  --iwad=<path>     Default: $_defaultIwadPath');
  stdout.writeln('  --frames=<count>  Default: $_defaultFrames');
  stdout.writeln('  --report=<path>   Default: $_defaultReportPath');
}

enum _BenchmarkMode { inline, worker }

final class _BenchmarkSpec {
  const _BenchmarkSpec(this.name, this.mode, this.transport);

  final String name;
  final _BenchmarkMode mode;
  final DoomFrameTransport transport;
}

final class _BenchmarkResult {
  const _BenchmarkResult({
    required this.name,
    required this.mode,
    required this.format,
    required this.frames,
    required this.startUs,
    required this.firstFrameUs,
    required this.totalUs,
    required this.totalBytes,
    required this.profile,
    required this.vmProfile,
  });

  final String name;
  final String mode;
  final String format;
  final int frames;
  final int startUs;
  final int firstFrameUs;
  final int totalUs;
  final int totalBytes;
  final DoomProfileMap? profile;
  final WasmVmProfileSnapshot? vmProfile;

  double get instantiateMs => startUs / 1000;

  double get firstFrameMs => firstFrameUs / 1000;

  double get totalMs => totalUs / 1000;

  double get fps =>
      frames == 0 || totalUs == 0 ? 0 : frames * 1000000 / totalUs;

  double get avgFrameMs => frames == 0 ? 0 : totalUs / 1000 / frames;

  double get firstFrameAfterStartMs =>
      startUs == 0 || firstFrameUs == 0 ? 0 : (firstFrameUs - startUs) / 1000;

  double get steadyStateAfterFirstMs => frames <= 1 || firstFrameUs == 0
      ? 0
      : (totalUs - firstFrameUs) / 1000 / (frames - 1);

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'mode': mode,
    'format': format,
    'frames': frames,
    'startUs': startUs,
    'firstFrameUs': firstFrameUs,
    'totalUs': totalUs,
    'totalBytes': totalBytes,
    'fps': fps,
    'avgFrameMs': avgFrameMs,
    'instantiateMs': instantiateMs,
    'firstFrameAfterStartMs': firstFrameAfterStartMs,
    'steadyStateAfterFirstMs': steadyStateAfterFirstMs,
    'profile': profile,
    'vmProfile': vmProfile == null
        ? null
        : <String, Object?>{
            'totalCallCount': vmProfile!.totalCallCount,
            'totalInstructionCount': vmProfile!.totalInstructionCount,
            'maxDepth': vmProfile!.maxDepth,
            'functions': vmProfile!.functions
                .take(20)
                .map(
                  (entry) => <String, Object?>{
                    'functionIndex': entry.functionIndex,
                    'callCount': entry.callCount,
                    'instructionCount': entry.instructionCount,
                    'maxDepth': entry.maxDepth,
                  },
                )
                .toList(growable: false),
          },
  };

  String describe() {
    final mib = totalBytes / (1024 * 1024);
    final topProfile = _describeTopProfile(profile);
    final topVm = _describeTopVmProfile(vmProfile);
    return 'frames=$frames instantiate=${instantiateMs.toStringAsFixed(1)}ms '
        'first=${firstFrameMs.toStringAsFixed(1)}ms '
        'firstAfterStart=${firstFrameAfterStartMs.toStringAsFixed(1)}ms '
        'steady=${steadyStateAfterFirstMs.toStringAsFixed(2)}ms '
        'total=${totalMs.toStringAsFixed(1)}ms fps=${fps.toStringAsFixed(1)} '
        'avg=${avgFrameMs.toStringAsFixed(2)}ms bytes=${mib.toStringAsFixed(2)}MiB'
        '${topProfile.isEmpty ? '' : ' top=$topProfile'}'
        '${topVm.isEmpty ? '' : ' vm=$topVm'}';
  }
}

String _describeTopProfile(DoomProfileMap? profile) {
  if (profile == null || profile.isEmpty) {
    return '';
  }
  final entries = profile.entries.toList()
    ..sort(
      (a, b) => (b.value['totalUs'] ?? 0).compareTo(a.value['totalUs'] ?? 0),
    );
  return entries
      .take(5)
      .map((entry) {
        final totalMs = ((entry.value['totalUs'] ?? 0) / 1000).toStringAsFixed(
          1,
        );
        final count = entry.value['count'] ?? 0;
        return '${entry.key}:${totalMs}ms/$count';
      })
      .join(',');
}

String _describeTopVmProfile(WasmVmProfileSnapshot? profile) {
  if (profile == null || profile.functions.isEmpty) {
    return '';
  }
  return profile.functions
      .take(5)
      .map(
        (entry) =>
            'f${entry.functionIndex}:${entry.instructionCount}/${entry.callCount}',
      )
      .join(',');
}
