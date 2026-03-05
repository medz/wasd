import 'dart:io';

const String _defaultWasmPath = 'test/fixtures/doom/doom.wasm';
const String _defaultIwadPath = 'test/fixtures/doom/doom1.wad';
const String _defaultGuestRoot = '/doom';
const String _defaultTimedemo = 'demo1';
const String _defaultMode = 'instantiate';
const String _compiledJsPath = '.dart_tool/doom_runtime_matrix/doom_cli.js';

Future<int> main(List<String> args) async {
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

  if (!File(wasmPath).existsSync()) {
    stderr.writeln('Missing wasm fixture: $wasmPath');
    return 2;
  }
  if (!File(iwadPath).existsSync()) {
    stderr.writeln('Missing IWAD fixture: $iwadPath');
    return 2;
  }

  final cliArgs = <String>[
    '--mode=$mode',
    '--wasm=$wasmPath',
    '--iwad=$iwadPath',
    '--guest-root=$guestRoot',
    '--timedemo=$timedemo',
  ];

  final vmRun = await _runCommand(
    name: 'dart-vm',
    executable: 'dart',
    arguments: ['run', 'example/doom_cli.dart', ...cliArgs],
  );
  _printCommandResult(vmRun);
  if (!vmRun.success) {
    stderr.writeln('RUNTIME MATRIX FAIL: dart-vm failed.');
    return vmRun.exitCode == 0 ? 1 : vmRun.exitCode;
  }

  await Directory('.dart_tool/doom_runtime_matrix').create(recursive: true);
  final jsCompile = await _runCommand(
    name: 'dart2js',
    executable: 'dart',
    arguments: [
      'compile',
      'js',
      '-O1',
      '-o',
      _compiledJsPath,
      'example/doom_cli.dart',
    ],
  );
  _printCommandResult(jsCompile);
  if (!jsCompile.success) {
    stderr.writeln('RUNTIME MATRIX FAIL: dart2js compile failed.');
    return jsCompile.exitCode == 0 ? 1 : jsCompile.exitCode;
  }

  final nodeRun = await _runCommand(
    name: 'node-js',
    executable: 'node',
    arguments: <String>[_compiledJsPath, ...cliArgs],
  );
  _printCommandResult(nodeRun);
  if (!nodeRun.success) {
    stderr.writeln('RUNTIME MATRIX FAIL: node runtime failed.');
    return nodeRun.exitCode == 0 ? 1 : nodeRun.exitCode;
  }

  final mismatches = <String>[];
  if (vmRun.exitCode != nodeRun.exitCode) {
    mismatches.add(
      'exit code mismatch: dart-vm=${vmRun.exitCode}, node-js=${nodeRun.exitCode}',
    );
  }

  final vmReportedExit = _extractReportedExitCode(vmRun.stdout);
  final nodeReportedExit = _extractReportedExitCode(nodeRun.stdout);
  if (vmReportedExit != null &&
      nodeReportedExit != null &&
      vmReportedExit != nodeReportedExit) {
    mismatches.add(
      'reported DOOM exit mismatch: dart-vm=$vmReportedExit, node-js=$nodeReportedExit',
    );
  }

  if (mismatches.isNotEmpty) {
    stderr.writeln('RUNTIME MATRIX FAIL');
    for (final mismatch in mismatches) {
      stderr.writeln('- $mismatch');
    }
    return 1;
  }

  stdout.writeln('RUNTIME MATRIX PASS');
  stdout.writeln('mode=$mode wasm=$wasmPath iwad=$iwadPath');
  return 0;
}

int? _extractReportedExitCode(String stdoutText) {
  final match = RegExp(r'DOOM exited with code (\d+)').firstMatch(stdoutText);
  if (match == null) {
    return null;
  }
  return int.tryParse(match.group(1)!);
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
  stdout.writeln('  --mode=instantiate|start   Default: instantiate');
  stdout.writeln('  --wasm=<path>              Default: $_defaultWasmPath');
  stdout.writeln('  --iwad=<path>              Default: $_defaultIwadPath');
  stdout.writeln('  --guest-root=<path>        Default: $_defaultGuestRoot');
  stdout.writeln('  --timedemo=<name>          Default: $_defaultTimedemo');
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
