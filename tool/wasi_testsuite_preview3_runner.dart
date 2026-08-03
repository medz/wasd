import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  late final _Options options;
  try {
    options = _Options.parse(args);
  } on Object catch (error) {
    io.stderr
      ..writeln('wasi-testsuite-preview3: $error')
      ..writeln(_usage);
    io.exitCode = 2;
    return;
  }

  if (options.showHelp) {
    io.stdout.writeln(_usage);
    return;
  }

  final startedAt = DateTime.now().toUtc();
  var suiteDirs = const <String>[];
  var fixtureCount = 0;
  String? testsuiteHead;
  _RunnerResult? result;
  late final _OfficialResult official;
  try {
    suiteDirs = await _findPreview3SuiteDirs(options.testsuiteDir);
    fixtureCount = await _countFixtures(suiteDirs);
    testsuiteHead = await _gitHead(options.testsuiteDir);
    if (fixtureCount == 0) {
      official = const _OfficialResult(
        totals: _Totals(),
        failures: <_Failure>[],
      );
    } else {
      final rawJsonPath = '${options.jsonPath}.raw-official.json';
      await io.File(rawJsonPath).parent.create(recursive: true);
      result = await _runOfficialRunner(
        options: options,
        suiteDirs: suiteDirs,
        rawJsonPath: rawJsonPath,
      );
      official = await _readOfficialResult(rawJsonPath);
    }
  } on Object catch (error) {
    official = _officialRunnerFailure('$error');
  }
  final totals = official.totals;
  final missingTests = fixtureCount == 0 && official.failures.isEmpty;
  final passed =
      !missingTests &&
      result?.exitCode == 0 &&
      totals.total == fixtureCount &&
      totals.failed == 0 &&
      totals.skipped == 0 &&
      totals.xfailed == 0 &&
      totals.xpassed == 0 &&
      totals.passed == fixtureCount;
  final report = _Report(
    status: missingTests
        ? 'missing-tests'
        : passed
        ? 'passed'
        : 'failed',
    startedAt: startedAt,
    endedAt: DateTime.now().toUtc(),
    testsuiteDir: options.testsuiteDir,
    testsuiteHead: testsuiteHead,
    suiteDirs: suiteDirs,
    fixtureCount: fixtureCount,
    official: official,
    runnerExitCode: result?.exitCode,
    message: missingTests
        ? 'Official wasi-testsuite contains no wasm32-wasip3 fixtures.'
        : passed
        ? 'Official wasi-testsuite Preview3 passed 100%.'
        : 'Official wasi-testsuite Preview3 did not pass 100%.',
  );
  await _writeReport(report, options);
  if (result != null) {
    io.stdout.write(result.stdout);
    io.stderr.write(result.stderr);
  }
  io.stdout.writeln('wasi-testsuite-preview3 status: ${report.status}');
  if (missingTests) {
    io.stdout.writeln(report.message);
    io.exitCode = 1;
    return;
  }
  io.stdout.writeln(
    'fixtures=$fixtureCount total=${totals.total} passed=${totals.passed} '
    'failed=${totals.failed} skipped=${totals.skipped} '
    'xfailed=${totals.xfailed} xpassed=${totals.xpassed}',
  );
  io.exitCode = passed ? 0 : 1;
}

Future<List<String>> _findPreview3SuiteDirs(String testsuiteDir) async {
  final root = io.Directory(testsuiteDir);
  if (!await root.exists()) {
    return const <String>[];
  }
  final dirs = <String>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! io.Directory || _basename(entity.path) != 'wasm32-wasip3') {
      continue;
    }
    if (await _hasImmediateWasmFixture(entity)) {
      dirs.add(entity.path);
    }
  }
  dirs.sort();
  return List<String>.unmodifiable(dirs);
}

Future<bool> _hasImmediateWasmFixture(io.Directory directory) async {
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is io.File && entity.path.endsWith('.wasm')) {
      return true;
    }
  }
  return false;
}

Future<int> _countFixtures(List<String> suiteDirs) async {
  var count = 0;
  for (final suiteDir in suiteDirs) {
    await for (final entity in io.Directory(
      suiteDir,
    ).list(followLinks: false)) {
      if (entity is io.File && entity.path.endsWith('.wasm')) {
        count++;
      }
    }
  }
  return count;
}

Future<_RunnerResult> _runOfficialRunner({
  required _Options options,
  required List<String> suiteDirs,
  required String rawJsonPath,
}) async {
  final runnerDir = io.Directory(options.runnerDir);
  if (!runnerDir.existsSync()) {
    throw StateError('official wasi-testsuite runner not found: $runnerDir');
  }
  final rawJson = io.File(rawJsonPath);
  if (await rawJson.exists()) {
    await rawJson.delete();
  }
  final runnerArgs = <String>[
    for (final suiteDir in suiteDirs) ...<String>['--test-suite', suiteDir],
    '--runtime-adapter',
    options.runtimeAdapter,
    '--json-output-location',
    rawJsonPath,
    '--disable-colors',
  ];
  final process = await io.Process.start(
    options.python,
    io.Platform.isWindows
        ? <String>['-m', 'wasi_test_runner', ...runnerArgs]
        : <String>['-c', _posixRunnerBootstrap, ...runnerArgs],
    environment: <String, String>{'PYTHONPATH': options.runnerDir},
  );
  final stdout = _ProcessOutputCollector(process.stdout);
  final stderr = _ProcessOutputCollector(process.stderr);
  late final int exitCode;
  try {
    exitCode = await process.exitCode.timeout(options.runnerTimeout);
  } on TimeoutException {
    try {
      await _terminateRunnerTree(process);
      await _readRunnerOutput(stdout, stderr);
    } on Object catch (cleanupError) {
      await Future.wait(<Future<void>>[stdout.cancel(), stderr.cancel()]);
      throw TimeoutException(
        'Official wasi-testsuite runner timed out after '
        '${options.runnerTimeout.inSeconds} seconds; cleanup failed: '
        '$cleanupError',
        options.runnerTimeout,
      );
    }
    throw TimeoutException(
      'Official wasi-testsuite runner timed out after '
      '${options.runnerTimeout.inSeconds} seconds.',
      options.runnerTimeout,
    );
  }
  try {
    final output = await _readRunnerOutput(stdout, stderr);
    return _RunnerResult(
      exitCode: exitCode,
      stdout: output.stdout,
      stderr: output.stderr,
    );
  } on TimeoutException {
    final killed = await _signalRunnerTree(process, io.ProcessSignal.sigkill);
    if (!killed) {
      await Future.wait(<Future<void>>[stdout.cancel(), stderr.cancel()]);
      throw StateError(
        'Official runner exited but its output process tree could not be killed.',
      );
    }
    try {
      final output = await _readRunnerOutput(stdout, stderr);
      return _RunnerResult(
        exitCode: exitCode,
        stdout: output.stdout,
        stderr: output.stderr,
      );
    } on Object {
      await Future.wait(<Future<void>>[stdout.cancel(), stderr.cancel()]);
      rethrow;
    }
  } on Object {
    await Future.wait(<Future<void>>[stdout.cancel(), stderr.cancel()]);
    rethrow;
  }
}

Future<void> _terminateRunnerTree(io.Process process) async {
  final termSent = await _signalRunnerTree(process, io.ProcessSignal.sigterm);
  if (!termSent && !process.kill()) {
    try {
      await process.exitCode.timeout(Duration.zero);
    } on TimeoutException {
      throw StateError('Unable to terminate official runner process tree.');
    }
  }
  var exited = false;
  try {
    await process.exitCode.timeout(_runnerTerminationGrace);
    exited = true;
  } on TimeoutException {
    // Escalate below.
  }
  final killSent = await _signalRunnerTree(process, io.ProcessSignal.sigkill);
  if (!exited && !killSent && !process.kill(io.ProcessSignal.sigkill)) {
    throw StateError('Unable to kill official runner process tree.');
  }
  if (!exited) {
    await process.exitCode.timeout(_runnerTerminationGrace);
  }
}

Future<bool> _signalRunnerTree(
  io.Process process,
  io.ProcessSignal signal,
) async {
  if (!io.Platform.isWindows) {
    return io.Process.killPid(-process.pid, signal);
  }
  // `taskkill /T` can walk a live runner tree. If the runner already exited,
  // the caller bounds pipe draining and reports cleanup failure instead.
  try {
    final result = await io.Process.run('taskkill', <String>[
      '/PID',
      '${process.pid}',
      '/T',
      if (signal == io.ProcessSignal.sigkill) '/F',
    ]);
    return result.exitCode == 0;
  } on io.ProcessException {
    return false;
  }
}

Future<({String stdout, String stderr})> _readRunnerOutput(
  _ProcessOutputCollector stdout,
  _ProcessOutputCollector stderr,
) async {
  final values = await Future.wait<String>(<Future<String>>[
    stdout.done,
    stderr.done,
  ]).timeout(_runnerOutputDrainTimeout);
  return (stdout: values[0], stderr: values[1]);
}

Future<_OfficialResult> _readOfficialResult(String rawJsonPath) async {
  final file = io.File(rawJsonPath);
  if (!await file.exists()) {
    return const _OfficialResult(
      totals: _Totals(total: 1, failed: 1),
      failures: <_Failure>[
        _Failure(
          name: '<official-runner>',
          outcome: 'fail',
          messages: <String>['Official runner did not write its JSON report.'],
        ),
      ],
    );
  }
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('report root must be a JSON object');
    }
    final resultValues = decoded['results'];
    if (resultValues is! List<Object?>) {
      throw const FormatException('report results must be a JSON array');
    }
    final results = resultValues.cast<Map<String, Object?>>();
    var total = 0;
    var passed = 0;
    var failed = 0;
    var skipped = 0;
    var xfailed = 0;
    var xpassed = 0;
    final failures = <_Failure>[];
    for (final suite in results) {
      final testValues = suite['tests'];
      if (testValues is! List<Object?>) {
        throw const FormatException('suite tests must be a JSON array');
      }
      final tests = testValues.cast<Map<String, Object?>>();
      for (final test in tests) {
        total++;
        final outcome = test['outcome'] as String? ?? 'unknown';
        switch (outcome) {
          case 'pass':
            passed++;
          case 'fail':
            failed++;
          case 'skip':
            skipped++;
          case 'xfail':
            xfailed++;
          case 'xpass':
            xpassed++;
          default:
            failed++;
        }
        if (outcome != 'pass') {
          failures.add(
            _Failure(
              name: test['name'] as String? ?? '<unnamed>',
              outcome: outcome,
              messages:
                  (test['failures'] as List<Object?>? ?? const <Object?>[])
                      .map((message) => message.toString())
                      .toList(growable: false),
            ),
          );
        }
      }
    }
    return _OfficialResult(
      totals: _Totals(
        total: total,
        passed: passed,
        failed: failed,
        skipped: skipped,
        xfailed: xfailed,
        xpassed: xpassed,
      ),
      failures: List<_Failure>.unmodifiable(failures),
    );
  } on Object catch (error) {
    return _officialRunnerFailure(
      'Official runner report is not valid JSON: $error',
    );
  }
}

_OfficialResult _officialRunnerFailure(String message) {
  return _OfficialResult(
    totals: const _Totals(total: 1, failed: 1),
    failures: <_Failure>[
      _Failure(
        name: '<official-runner>',
        outcome: 'fail',
        messages: <String>[message],
      ),
    ],
  );
}

Future<String?> _gitHead(String path) async {
  late final io.ProcessResult result;
  try {
    result = await io.Process.run('git', <String>[
      '-C',
      path,
      'rev-parse',
      'HEAD',
    ]);
  } on io.ProcessException {
    return null;
  }
  if (result.exitCode != 0) {
    return null;
  }
  return (result.stdout as String).trim();
}

Future<void> _writeReport(_Report report, _Options options) async {
  await io.File(options.jsonPath).parent.create(recursive: true);
  await io.File(
    options.jsonPath,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report.toJson()));
  await io.File(options.markdownPath).parent.create(recursive: true);
  await io.File(options.markdownPath).writeAsString(report.toMarkdown());
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

final class _Options {
  const _Options({
    required this.showHelp,
    required this.testsuiteDir,
    required this.runnerDir,
    required this.python,
    required this.runtimeAdapter,
    required this.runnerTimeout,
    required this.jsonPath,
    required this.markdownPath,
  });

  final bool showHelp;
  final String testsuiteDir;
  final String runnerDir;
  final String python;
  final String runtimeAdapter;
  final Duration runnerTimeout;
  final String jsonPath;
  final String markdownPath;

  static _Options parse(List<String> args) {
    var showHelp = false;
    var testsuiteDir = '.dart_tool/wasi-testsuite';
    String? runnerDir;
    var python = io.Platform.environment['PYTHON'] ?? 'python3';
    var runtimeAdapter = 'tool/wasi_testsuite_wasd_adapter.py';
    var runnerTimeout = const Duration(minutes: 10);
    var jsonPath = '.dart_tool/spec_runner/wasi_testsuite_preview3_latest.json';
    var markdownPath =
        '.dart_tool/spec_runner/wasi_testsuite_preview3_failures.md';

    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      switch (arg) {
        case '-h':
        case '--help':
          showHelp = true;
        case '--testsuite-dir':
          testsuiteDir = _readValue(args, ++index, arg);
        case '--runner-dir':
          runnerDir = _readValue(args, ++index, arg);
        case '--runtime-adapter':
          runtimeAdapter = _readValue(args, ++index, arg);
        case '--python':
          python = _readValue(args, ++index, arg);
        case '--runner-timeout-seconds':
          runnerTimeout = _parseTimeout(_readValue(args, ++index, arg), arg);
        case '--json':
          jsonPath = _readValue(args, ++index, arg);
        case '--markdown':
          markdownPath = _readValue(args, ++index, arg);
        default:
          if (arg.startsWith('--testsuite-dir=')) {
            testsuiteDir = arg.substring('--testsuite-dir='.length);
          } else if (arg.startsWith('--runner-dir=')) {
            runnerDir = arg.substring('--runner-dir='.length);
          } else if (arg.startsWith('--runtime-adapter=')) {
            runtimeAdapter = arg.substring('--runtime-adapter='.length);
          } else if (arg.startsWith('--python=')) {
            python = arg.substring('--python='.length);
          } else if (arg.startsWith('--runner-timeout-seconds=')) {
            runnerTimeout = _parseTimeout(
              arg.substring('--runner-timeout-seconds='.length),
              '--runner-timeout-seconds',
            );
          } else if (arg.startsWith('--json=')) {
            jsonPath = arg.substring('--json='.length);
          } else if (arg.startsWith('--markdown=')) {
            markdownPath = arg.substring('--markdown='.length);
          } else {
            throw ArgumentError('unknown option: $arg');
          }
      }
    }

    return _Options(
      showHelp: showHelp,
      testsuiteDir: testsuiteDir,
      runnerDir: runnerDir ?? '$testsuiteDir/test-runner',
      python: python,
      runtimeAdapter: runtimeAdapter,
      runnerTimeout: runnerTimeout,
      jsonPath: jsonPath,
      markdownPath: markdownPath,
    );
  }

  static String _readValue(List<String> args, int index, String option) {
    if (index >= args.length) {
      throw ArgumentError('$option requires a value');
    }
    return args[index];
  }

  static Duration _parseTimeout(String value, String option) {
    final seconds = int.tryParse(value);
    if (seconds == null || seconds <= 0) {
      throw ArgumentError.value(value, option, 'must be a positive integer');
    }
    return Duration(seconds: seconds);
  }
}

final class _RunnerResult {
  const _RunnerResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

final class _ProcessOutputCollector {
  _ProcessOutputCollector(Stream<List<int>> stream) {
    _subscription = stream.listen(
      _bytes.add,
      onError: _completeError,
      onDone: _complete,
      cancelOnError: true,
    );
  }

  final _bytes = BytesBuilder(copy: false);
  final _completer = Completer<String>();
  late final StreamSubscription<List<int>> _subscription;

  Future<String> get done => _completer.future;

  Future<void> cancel() async {
    await _subscription.cancel();
    _complete();
  }

  void _complete() {
    if (!_completer.isCompleted) {
      _completer.complete(
        utf8.decode(_bytes.takeBytes(), allowMalformed: true),
      );
    }
  }

  void _completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) {
      _completer.completeError(error, stackTrace);
    }
  }
}

final class _Totals {
  const _Totals({
    this.total = 0,
    this.passed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.xfailed = 0,
    this.xpassed = 0,
  });

  final int total;
  final int passed;
  final int failed;
  final int skipped;
  final int xfailed;
  final int xpassed;

  Map<String, Object?> toJson() => <String, Object?>{
    'total': total,
    'passed': passed,
    'failed': failed,
    'skipped': skipped,
    'xfailed': xfailed,
    'xpassed': xpassed,
  };
}

final class _Failure {
  const _Failure({
    required this.name,
    required this.outcome,
    required this.messages,
  });

  final String name;
  final String outcome;
  final List<String> messages;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'outcome': outcome,
    'messages': messages,
  };
}

final class _OfficialResult {
  const _OfficialResult({required this.totals, required this.failures});

  final _Totals totals;
  final List<_Failure> failures;
}

final class _Report {
  const _Report({
    required this.status,
    required this.startedAt,
    required this.endedAt,
    required this.testsuiteDir,
    required this.testsuiteHead,
    required this.suiteDirs,
    required this.fixtureCount,
    required this.official,
    required this.runnerExitCode,
    required this.message,
  });

  final String status;
  final DateTime startedAt;
  final DateTime endedAt;
  final String testsuiteDir;
  final String? testsuiteHead;
  final List<String> suiteDirs;
  final int fixtureCount;
  final _OfficialResult official;
  final int? runnerExitCode;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'suite': 'official-wasi-testsuite-preview3',
    'status': status,
    'started_at_utc': startedAt.toIso8601String(),
    'ended_at_utc': endedAt.toIso8601String(),
    'testsuite_dir': testsuiteDir,
    'testsuite_head': testsuiteHead,
    'suite_dirs': suiteDirs,
    'fixture_count': fixtureCount,
    'totals': official.totals.toJson(),
    'runner_exit_code': runnerExitCode,
    'failures': [for (final failure in official.failures) failure.toJson()],
    'message': message,
  };

  String toMarkdown() {
    final totals = official.totals;
    final b = StringBuffer()
      ..writeln('# Official WASI Testsuite Preview3 Report')
      ..writeln()
      ..writeln('- Status: `$status`')
      ..writeln('- Started (UTC): `${startedAt.toIso8601String()}`')
      ..writeln('- Ended (UTC): `${endedAt.toIso8601String()}`')
      ..writeln('- Testsuite dir: `$testsuiteDir`')
      ..writeln('- Testsuite HEAD: `${testsuiteHead ?? 'unknown'}`')
      ..writeln('- Fixtures discovered: `$fixtureCount`')
      ..writeln('- Message: $message')
      ..writeln(
        '- Totals: `total=${totals.total} passed=${totals.passed} '
        'failed=${totals.failed} skipped=${totals.skipped} '
        'xfailed=${totals.xfailed} xpassed=${totals.xpassed}`',
      )
      ..writeln();
    if (status == 'passed') {
      b.writeln('All discovered Preview3 fixtures passed (100%).');
    } else if (official.failures.isNotEmpty) {
      b
        ..writeln('## Non-passing fixtures')
        ..writeln();
      for (final failure in official.failures) {
        b.writeln('### `${failure.name}` — `${failure.outcome}`');
        if (failure.messages.isEmpty) {
          b.writeln('- No failure message was reported.');
        } else {
          for (final message in failure.messages) {
            b
              ..writeln('```text')
              ..writeln(message.trimRight())
              ..writeln('```');
          }
        }
        b.writeln();
      }
    } else if (suiteDirs.isEmpty) {
      b.writeln('No official `wasm32-wasip3` test directories were found.');
    } else {
      b.writeln('The official runner failed without per-fixture details.');
    }
    return b.toString();
  }
}

const Duration _runnerTerminationGrace = Duration(seconds: 2);
const Duration _runnerOutputDrainTimeout = Duration(seconds: 2);

const String _posixRunnerBootstrap = r'''
import os
import runpy
import sys

os.setsid()
sys.argv = ["wasi_test_runner", *sys.argv[1:]]
runpy.run_module("wasi_test_runner", run_name="__main__")
''';

const String _usage = '''
Usage: dart run tool/wasi_testsuite_preview3_runner.dart [options]

Options:
  --testsuite-dir DIR     Official wasi-testsuite checkout.
  --runner-dir DIR        Directory containing the wasi_test_runner package.
  --runtime-adapter FILE  Runtime adapter passed to official runner.
  --python FILE           Python 3.10+ executable for the official runner.
  --runner-timeout-seconds N
                          Stop a hung official runner after N seconds.
  --json FILE             Write machine-readable report.
  --markdown FILE         Write markdown failure report.
  -h, --help              Show this help.
''';
