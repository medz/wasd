import 'dart:convert';
import 'dart:io';

const String _defaultWasmPath = 'test/fixtures/doom/doom.wasm';
const String _defaultIwadPath = 'test/fixtures/doom/doom1.wad';
const String _defaultGuestRoot = '/doom';
const String _defaultTimedemo = 'demo1';
const String _defaultMode = 'instantiate';
const String _defaultNodeFrameDir =
    '.dart_tool/doom_runtime_matrix/node_frames';

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

  final mode = options['mode'] ?? _defaultMode;
  if (mode != 'instantiate' && mode != 'start') {
    stderr.writeln('Invalid --mode value: $mode');
    stderr.writeln('Allowed values: instantiate, start');
    return 2;
  }

  final wasmPath = options['wasm'] ?? _defaultWasmPath;
  final iwadPath = options['iwad'] ?? _defaultIwadPath;
  final guestRoot = options['guest-root'] ?? _defaultGuestRoot;
  final timedemo = options['timedemo'] ?? _defaultTimedemo;
  final nodeFrameDir = options['node-frame-dir'] ?? _defaultNodeFrameDir;

  if (!File(wasmPath).existsSync()) {
    stderr.writeln('Missing wasm fixture: $wasmPath');
    return 2;
  }
  if (!File(iwadPath).existsSync()) {
    stderr.writeln('Missing IWAD fixture: $iwadPath');
    return 2;
  }

  final sharedArgs = <String>[
    '--mode=$mode',
    '--wasm=$wasmPath',
    '--iwad=$iwadPath',
    '--guest-root=$guestRoot',
    '--timedemo=$timedemo',
  ];

  final vmRun = await _runCommand(
    name: 'dart-vm',
    executable: 'dart',
    arguments: <String>['run', 'example/doom_cli.dart', ...sharedArgs],
  );
  _printCommandResult(vmRun);

  final nodeArgs = <String>[
    'tool/doom_node_monitor.mjs',
    ...sharedArgs,
    '--frame-dir=$nodeFrameDir',
  ];
  final nodeRun = await _runCommand(
    name: 'node-js',
    executable: 'node',
    arguments: nodeArgs,
  );
  _printCommandResult(nodeRun);

  final failures = <String>[];
  if (!vmRun.success) {
    failures.add('dart-vm failed with exit=${vmRun.exitCode}');
  }
  if (!nodeRun.success) {
    failures.add('node-js failed with exit=${nodeRun.exitCode}');
  }

  if (vmRun.exitCode != nodeRun.exitCode) {
    failures.add(
      'exit code mismatch: dart-vm=${vmRun.exitCode}, node-js=${nodeRun.exitCode}',
    );
  }

  final reportFile = File('$nodeFrameDir/report.json');
  if (!reportFile.existsSync()) {
    failures.add('node-js missing report: ${reportFile.path}');
  } else {
    final report = jsonDecode(await reportFile.readAsString());
    if (report is! Map<String, dynamic>) {
      failures.add('node-js report is not JSON object.');
    } else {
      final reportMode = '${report['mode'] ?? ''}';
      final health = '${report['health'] ?? ''}';
      if (reportMode != mode) {
        failures.add(
          'node-js report mode mismatch: expected=$mode actual=$reportMode',
        );
      }

      if (mode == 'instantiate') {
        if (health != 'instantiated') {
          failures.add(
            'node-js instantiate health mismatch: expected=instantiated actual=$health',
          );
        }
      } else {
        if (health != 'ok') {
          failures.add(
            'node-js start health mismatch: expected=ok actual=$health',
          );
        }
        final frames =
            (report['writtenFrames'] as List<dynamic>? ?? const <dynamic>[])
                .map((dynamic v) => '$v')
                .toList();
        if (frames.isEmpty) {
          failures.add('node-js start has no frame artifacts.');
        } else if (!File(frames.first).existsSync()) {
          failures.add('node-js first frame missing: ${frames.first}');
        }
      }
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('RUNTIME MATRIX FAIL');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    return 1;
  }

  stdout.writeln('RUNTIME MATRIX PASS');
  stdout.writeln('mode=$mode wasm=$wasmPath iwad=$iwadPath');
  return 0;
}

void _printCommandResult(_CommandResult result) {
  stdout.writeln('== ${result.name} ==');
  stdout.writeln('\$ ${result.command}');
  stdout.writeln('exit=${result.exitCode}');
  if (result.stdout.trim().isNotEmpty) {
    stdout.writeln('[stdout]');
    stdout.write(result.stdout);
    if (!result.stdout.endsWith('\n')) {
      stdout.writeln();
    }
  }
  if (result.stderr.trim().isNotEmpty) {
    stdout.writeln('[stderr]');
    stdout.write(result.stderr);
    if (!result.stderr.endsWith('\n')) {
      stdout.writeln();
    }
  }
}

Future<_CommandResult> _runCommand({
  required String name,
  required String executable,
  required List<String> arguments,
}) async {
  try {
    final result = await Process.run(executable, arguments);
    return _CommandResult(
      name: name,
      command: _commandToString(executable, arguments),
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
    );
  } on ProcessException catch (error) {
    return _CommandResult(
      name: name,
      command: _commandToString(executable, arguments),
      exitCode: 127,
      stdout: '',
      stderr: '${error.message}\n$error',
    );
  }
}

String _commandToString(String executable, List<String> arguments) {
  final escapedArgs = arguments.map(_shellEscape).join(' ');
  return escapedArgs.isEmpty ? executable : '$executable $escapedArgs';
}

String _shellEscape(String value) {
  if (value.isEmpty) {
    return "''";
  }
  if (RegExp(r'^[a-zA-Z0-9_\-./:=]+$').hasMatch(value)) {
    return value;
  }
  return "'${value.replaceAll("'", "'\\''")}'";
}

Map<String, String> _parseArgs(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      continue;
    }
    if (arg == '--help' || arg == '-h') {
      result['help'] = 'true';
      continue;
    }

    final equalIndex = arg.indexOf('=');
    if (equalIndex >= 0) {
      final key = arg.substring(2, equalIndex);
      final value = arg.substring(equalIndex + 1);
      result[key] = value;
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

void _printUsage() {
  stdout.writeln('Usage: dart run tool/doom_runtime_matrix.dart [options]');
  stdout.writeln('Options:');
  stdout.writeln('  --mode=instantiate|start   Default: $_defaultMode');
  stdout.writeln('  --wasm=<path>              Default: $_defaultWasmPath');
  stdout.writeln('  --iwad=<path>              Default: $_defaultIwadPath');
  stdout.writeln('  --guest-root=<path>        Default: $_defaultGuestRoot');
  stdout.writeln('  --timedemo=<name>          Default: $_defaultTimedemo');
  stdout.writeln('  --node-frame-dir=<path>    Default: $_defaultNodeFrameDir');
}

final class _CommandResult {
  _CommandResult({
    required this.name,
    required this.command,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final String name;
  final String command;
  final int exitCode;
  final String stdout;
  final String stderr;

  bool get success => exitCode == 0;
}
