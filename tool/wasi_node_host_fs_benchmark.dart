import 'dart:io';

const String _outputDir = '.dart_tool/wasi_node_host_fs_benchmark';
const String _compiledJs = '$_outputDir/benchmark.js';
const String _entrypoint = 'tool/wasi_node_host_fs_benchmark_js.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    _printUsage();
    return;
  }

  final nodeCheck = await Process.run('node', const <String>['--version']);
  if (nodeCheck.exitCode != 0) {
    stderr.writeln(
      'Node.js is required to run the WASI Node host FS benchmark.',
    );
    _writeOutput(stderr, nodeCheck.stderr);
    exitCode = 1;
    return;
  }

  await Directory(_outputDir).create(recursive: true);
  final compile = await Process.run(Platform.resolvedExecutable, const <String>[
    'compile',
    'js',
    '-O2',
    _entrypoint,
    '-o',
    _compiledJs,
  ]);
  _writeOutput(stderr, compile.stdout);
  _writeOutput(stderr, compile.stderr);
  if (compile.exitCode != 0) {
    exitCode = compile.exitCode;
    return;
  }

  final run = await Process.run('node', <String>[
    'tool/run_wasi_node_host_fs_benchmark.mjs',
    _compiledJs,
    ...args,
  ]);
  _writeOutput(stdout, run.stdout);
  _writeOutput(stderr, run.stderr);
  exitCode = run.exitCode;
}

void _writeOutput(IOSink sink, Object? output) {
  final text = output?.toString();
  if (text != null && text.isNotEmpty) {
    sink.write(text);
  }
}

void _printUsage() {
  stdout.writeln('''
Usage: dart run tool/wasi_node_host_fs_benchmark.dart [options]

Compiles the benchmark entrypoint with dart2js and runs it under Node.js so the
measured filesystem calls go through wasd's JS Preview1 host.

Options:
  --iterations=<n>       Repetitions for each measured operation. Default: 1000.
  --warmup=<n>           Warmup repetitions before measurement. Default: 50.
  --payload-bytes=<n>    Host/virtual file payload size. Default: 1024.
  --json                 Print machine-readable JSON.
  --help                 Show this help.
''');
}
