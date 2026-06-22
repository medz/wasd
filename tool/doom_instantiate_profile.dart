import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/wasd.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/module.dart'
    as native_ir;
import 'package:wasd/src/wasm/backend/native/interpreter/validator.dart'
    as native_validator;

const String _defaultWasmPath = 'test/fixtures/doom/doom.wasm';
const String _defaultIwadPath = 'test/fixtures/doom/doom1.wad';
const String _defaultGuestRoot = '/doom';
const String _defaultTimedemo = 'demo1';

Future<void> main(List<String> args) async {
  final exit = await _run(args);
  if (exit != 0) {
    exitCode = exit;
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
  final guestRoot = options['guest-root'] ?? _defaultGuestRoot;
  final timedemo = options['timedemo'] ?? _defaultTimedemo;
  final jsonOutput = options.containsKey('json');
  final compileBreakdown = options.containsKey('compile-breakdown');

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

  if (compileBreakdown) {
    return _runCompileBreakdown(
      wasmFile: wasmFile,
      wasmPath: wasmPath,
      iwadPath: iwadPath,
      jsonOutput: jsonOutput,
    );
  }

  final profile = _PhaseProfiler()..sample('start');
  final iwadBytes = await profile.measure(
    'read_iwad',
    () => iwadFile.readAsBytes(),
  );

  final iwadName = iwadFile.uri.pathSegments.isEmpty
      ? 'doom1.wad'
      : iwadFile.uri.pathSegments.last;
  final guestIwadPath = '$guestRoot/$iwadName';
  final wasi = await profile.measure(
    'create_wasi',
    () => WASI(
      args: <String>[
        'doom.wasm',
        '-file',
        guestIwadPath,
        '-nosound',
        if (timedemo.trim().isNotEmpty) ...<String>['-timedemo', timedemo],
      ],
      preopens: <String, String>{guestRoot: guestRoot},
      files: <String, Uint8List>{guestIwadPath: iwadBytes},
      env: <String, String>{
        'HOME': guestRoot,
        'TERM': 'xterm',
        'DOOMWADDIR': guestRoot,
        'DOOMWADPATH': guestRoot,
      },
    ),
  );

  final wasmBytes = await profile.measure(
    'read_wasm',
    () => wasmFile.readAsBytes(),
  );
  final module = await profile.measure(
    'compile_module',
    () => WebAssembly.compile(wasmBytes.buffer),
  );
  final instance = await profile.measure(
    'instantiate_module',
    () => WebAssembly.instantiateModule(module, <String, ModuleImports>{
      ...wasi.imports,
      'env': _doomEnvImports(),
    }),
  );
  await profile.measure(
    'finalize_wasi_bindings',
    () => wasi.finalizeBindings(instance),
  );

  final report = <String, Object?>{
    'wasm': wasmPath,
    'iwad': iwadPath,
    'wasm_size_bytes': wasmFile.lengthSync(),
    'iwad_size_bytes': iwadFile.lengthSync(),
    'total_duration_ms': profile.totalDurationMs,
    'baseline_rss_bytes': profile.baselineRssBytes,
    'peak_rss_bytes': profile.peakRssBytes,
    'phases': profile.phases.map((phase) => phase.toJson()).toList(),
  };

  if (jsonOutput) {
    stdout.writeln(jsonEncode(report));
  } else {
    _printTextReport(report);
  }
  return 0;
}

Future<int> _runCompileBreakdown({
  required File wasmFile,
  required String wasmPath,
  required String iwadPath,
  required bool jsonOutput,
}) async {
  final profile = _PhaseProfiler()..sample('start');
  final wasmBytes = await profile.measure(
    'read_wasm',
    () => wasmFile.readAsBytes(),
  );
  final module = await profile.measure(
    'decode_module',
    () => native_ir.WasmModule.decode(wasmBytes),
  );
  await profile.measure(
    'validate_module',
    () => native_validator.WasmValidator.validateModule(module),
  );

  final report = <String, Object?>{
    'mode': 'compile_breakdown',
    'wasm': wasmPath,
    'iwad': iwadPath,
    'wasm_size_bytes': wasmFile.lengthSync(),
    'module_stats': _moduleStats(module),
    'total_duration_ms': profile.totalDurationMs,
    'baseline_rss_bytes': profile.baselineRssBytes,
    'peak_rss_bytes': profile.peakRssBytes,
    'phases': profile.phases.map((phase) => phase.toJson()).toList(),
  };

  if (jsonOutput) {
    stdout.writeln(jsonEncode(report));
  } else {
    _printTextReport(report);
  }
  return 0;
}

Map<String, Object?> _moduleStats(native_ir.WasmModule module) {
  var instructionBytes = 0;
  var localGroups = 0;
  var expandedLocals = 0;
  var dataBytes = 0;
  for (final code in module.codes) {
    instructionBytes += code.instructions.length;
    localGroups += code.locals.length;
    for (final local in code.locals) {
      expandedLocals += local.count;
    }
  }
  for (final segment in module.dataSegments) {
    dataBytes += segment.bytes.length;
  }

  return <String, Object?>{
    'types': module.types.length,
    'imports': module.imports.length,
    'functions': module.functionTypeIndices.length,
    'codes': module.codes.length,
    'instruction_bytes': instructionBytes,
    'local_groups': localGroups,
    'expanded_locals': expandedLocals,
    'data_segments': module.dataSegments.length,
    'data_bytes': dataBytes,
  };
}

ModuleImports _doomEnvImports() {
  Object? ok(List<Object?> _) => 0;

  return <String, ImportValue>{
    'ZwareDoomOpenWindow': ImportExportKind.function(ok),
    'ZwareDoomSetPalette': ImportExportKind.function(ok),
    'ZwareDoomRenderFrame': ImportExportKind.function(ok),
    'ZwareDoomPendingEvent': ImportExportKind.function(ok),
    'ZwareDoomNextEvent': ImportExportKind.function(ok),
  };
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
    final equalIndex = arg.indexOf('=');
    if (equalIndex >= 0) {
      result[arg.substring(2, equalIndex)] = arg.substring(equalIndex + 1);
      continue;
    }
    final key = arg.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      result[key] = args[i + 1];
      i++;
    } else {
      result[key] = 'true';
    }
  }
  return result;
}

void _printTextReport(Map<String, Object?> report) {
  stdout.writeln('DOOM instantiate profile');
  stdout.writeln('wasm=${report['wasm']}');
  stdout.writeln('iwad=${report['iwad']}');
  stdout.writeln('wasm_size_bytes=${report['wasm_size_bytes']}');
  stdout.writeln('iwad_size_bytes=${report['iwad_size_bytes']}');
  stdout.writeln('total_duration_ms=${report['total_duration_ms']}');
  stdout.writeln('baseline_rss_bytes=${report['baseline_rss_bytes']}');
  stdout.writeln('peak_rss_bytes=${report['peak_rss_bytes']}');
  stdout.writeln();
  stdout.writeln('| Phase | Duration ms | RSS bytes | Delta bytes |');
  stdout.writeln('| --- | ---: | ---: | ---: |');
  for (final phase in report['phases']! as List<Object?>) {
    final entry = phase! as Map<String, Object?>;
    stdout.writeln(
      '| ${entry['name']} | ${entry['duration_ms']} | '
      '${entry['rss_bytes']} | ${entry['rss_delta_bytes']} |',
    );
  }
}

void _printUsage() {
  stdout.writeln(
    'Usage: dart run tool/doom_instantiate_profile.dart [options]',
  );
  stdout.writeln('Options:');
  stdout.writeln('  --wasm=<path>        Default: $_defaultWasmPath');
  stdout.writeln('  --iwad=<path>        Default: $_defaultIwadPath');
  stdout.writeln('  --guest-root=<path>  Default: $_defaultGuestRoot');
  stdout.writeln('  --timedemo=<name>    Default: $_defaultTimedemo');
  stdout.writeln(
    '  --compile-breakdown  Profile internal decode/validate only.',
  );
  stdout.writeln('  --json               Print machine-readable JSON.');
}

final class _PhaseProfiler {
  _PhaseProfiler() : _total = (Stopwatch()..start());

  final Stopwatch _total;
  final List<_PhaseSample> phases = <_PhaseSample>[];

  int? get baselineRssBytes => phases.isEmpty ? null : phases.first.rssBytes;

  int? get peakRssBytes {
    int? peak;
    for (final phase in phases) {
      final rss = phase.rssBytes;
      if (rss == null) {
        continue;
      }
      peak = peak == null || rss > peak ? rss : peak;
    }
    return peak;
  }

  int get totalDurationMs => _total.elapsedMilliseconds;

  void sample(String name) {
    phases.add(
      _PhaseSample(
        name: name,
        durationMs: 0,
        rssBytes: _currentRssBytes(),
        rssDeltaBytes: 0,
      ),
    );
  }

  Future<T> measure<T>(String name, FutureOr<T> Function() action) async {
    final before = _currentRssBytes();
    final watch = Stopwatch()..start();
    final result = await Future<T>.sync(action);
    watch.stop();
    final after = _currentRssBytes();
    phases.add(
      _PhaseSample(
        name: name,
        durationMs: watch.elapsedMilliseconds,
        rssBytes: after,
        rssDeltaBytes: before == null || after == null ? null : after - before,
      ),
    );
    return result;
  }
}

final class _PhaseSample {
  const _PhaseSample({
    required this.name,
    required this.durationMs,
    required this.rssBytes,
    required this.rssDeltaBytes,
  });

  final String name;
  final int durationMs;
  final int? rssBytes;
  final int? rssDeltaBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'duration_ms': durationMs,
    'rss_bytes': rssBytes,
    'rss_delta_bytes': rssDeltaBytes,
  };
}

int? _currentRssBytes() {
  try {
    final result = Process.runSync('ps', <String>['-o', 'rss=', '-p', '$pid']);
    if (result.exitCode != 0) {
      return null;
    }
    final text = result.stdout.toString().trim();
    if (text.isEmpty) {
      return null;
    }
    final kibibytes = int.tryParse(text.split(RegExp(r'\s+')).first);
    return kibibytes == null ? null : kibibytes * 1024;
  } catch (_) {
    return null;
  }
}
