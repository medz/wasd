import 'dart:convert';
import 'dart:io' as io;

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
  final suiteDirs = await _findPreview3SuiteDirs(options.testsuiteDir);
  final fixtureCount = await _countFixtures(suiteDirs);
  if (fixtureCount == 0) {
    final report = _Report(
      status: 'missing-tests',
      startedAt: startedAt,
      endedAt: DateTime.now().toUtc(),
      testsuiteDir: options.testsuiteDir,
      testsuiteHead: await _gitHead(options.testsuiteDir),
      suiteDirs: suiteDirs,
      fixtureCount: 0,
      official: const _OfficialResult(
        totals: _Totals(),
        failures: <_Failure>[],
      ),
      runnerExitCode: null,
      message: 'Official wasi-testsuite contains no wasm32-wasip3 fixtures.',
    );
    await _writeReport(report, options);
    io.stdout.writeln('wasi-testsuite-preview3 status: missing-tests');
    io.stdout.writeln(report.message);
    io.exitCode = 1;
    return;
  }

  final rawJsonPath = '${options.jsonPath}.raw-official.json';
  final result = await _runOfficialRunner(
    options: options,
    suiteDirs: suiteDirs,
    rawJsonPath: rawJsonPath,
  );
  final official = await _readOfficialResult(rawJsonPath);
  final totals = official.totals;
  final passed =
      result.exitCode == 0 &&
      totals.total == fixtureCount &&
      totals.failed == 0 &&
      totals.skipped == 0 &&
      totals.xfailed == 0 &&
      totals.xpassed == 0 &&
      totals.passed == fixtureCount;
  final report = _Report(
    status: passed ? 'passed' : 'failed',
    startedAt: startedAt,
    endedAt: DateTime.now().toUtc(),
    testsuiteDir: options.testsuiteDir,
    testsuiteHead: await _gitHead(options.testsuiteDir),
    suiteDirs: suiteDirs,
    fixtureCount: fixtureCount,
    official: official,
    runnerExitCode: result.exitCode,
    message: passed
        ? 'Official wasi-testsuite Preview3 passed 100%.'
        : 'Official wasi-testsuite Preview3 did not pass 100%.',
  );
  await _writeReport(report, options);
  io.stdout.write(result.stdout);
  io.stderr.write(result.stderr);
  io.stdout.writeln('wasi-testsuite-preview3 status: ${report.status}');
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

Future<io.ProcessResult> _runOfficialRunner({
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
  return io.Process.run(
    options.python,
    <String>[
      '-m',
      'wasi_test_runner',
      for (final suiteDir in suiteDirs) ...<String>['--test-suite', suiteDir],
      '--runtime-adapter',
      options.runtimeAdapter,
      '--json-output-location',
      rawJsonPath,
      '--disable-colors',
    ],
    environment: <String, String>{'PYTHONPATH': options.runnerDir},
  );
}

Future<_OfficialResult> _readOfficialResult(String rawJsonPath) async {
  final file = io.File(rawJsonPath);
  if (!await file.exists()) {
    return const _OfficialResult(
      totals: _Totals(failed: 1),
      failures: <_Failure>[
        _Failure(
          name: '<official-runner>',
          outcome: 'fail',
          messages: <String>['Official runner did not write its JSON report.'],
        ),
      ],
    );
  }
  final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
  final results = (json['results'] as List<Object?>? ?? const <Object?>[])
      .cast<Map<String, Object?>>();
  var total = 0;
  var passed = 0;
  var failed = 0;
  var skipped = 0;
  var xfailed = 0;
  var xpassed = 0;
  final failures = <_Failure>[];
  for (final suite in results) {
    final tests = (suite['tests'] as List<Object?>? ?? const <Object?>[])
        .cast<Map<String, Object?>>();
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
            messages: (test['failures'] as List<Object?>? ?? const <Object?>[])
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
}

Future<String?> _gitHead(String path) async {
  final result = await io.Process.run('git', <String>[
    '-C',
    path,
    'rev-parse',
    'HEAD',
  ]);
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
    required this.jsonPath,
    required this.markdownPath,
  });

  final bool showHelp;
  final String testsuiteDir;
  final String runnerDir;
  final String python;
  final String runtimeAdapter;
  final String jsonPath;
  final String markdownPath;

  static _Options parse(List<String> args) {
    var showHelp = false;
    var testsuiteDir = '.dart_tool/wasi-testsuite';
    String? runnerDir;
    var python = io.Platform.environment['PYTHON'] ?? 'python3';
    var runtimeAdapter = 'tool/wasi_testsuite_wasd_adapter.py';
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
    } else if (suiteDirs.isEmpty) {
      b.writeln('No official `wasm32-wasip3` test directories were found.');
    } else if (official.failures.isEmpty) {
      b.writeln('The official runner failed without per-fixture details.');
    } else {
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
    }
    return b.toString();
  }
}

const String _usage = '''
Usage: dart run tool/wasi_testsuite_preview3_runner.dart [options]

Options:
  --testsuite-dir DIR     Official wasi-testsuite checkout.
  --runner-dir DIR        Directory containing the wasi_test_runner package.
  --runtime-adapter FILE  Runtime adapter passed to official runner.
  --python FILE           Python 3.10+ executable for the official runner.
  --json FILE             Write machine-readable report.
  --markdown FILE         Write markdown failure report.
  -h, --help              Show this help.
''';
