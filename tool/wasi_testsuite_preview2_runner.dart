import 'dart:convert';
import 'dart:io' as io;

Future<void> main(List<String> args) async {
  late final _Options options;
  try {
    options = _Options.parse(args);
  } on Object catch (error) {
    io.stderr
      ..writeln('wasi-testsuite-preview2: $error')
      ..writeln(_usage);
    io.exitCode = 2;
    return;
  }

  if (options.showHelp) {
    io.stdout.writeln(_usage);
    return;
  }

  final startedAt = DateTime.now().toUtc();
  final suiteDirs = await _findPreview2SuiteDirs(options.testsuiteDir);
  if (suiteDirs.isEmpty) {
    final report = _Report(
      status: 'missing-tests',
      startedAt: startedAt,
      endedAt: DateTime.now().toUtc(),
      testsuiteDir: options.testsuiteDir,
      testsuiteHead: await _gitHead(options.testsuiteDir),
      suiteDirs: const <String>[],
      totals: const _Totals(),
      runnerExitCode: null,
      message: 'Official wasi-testsuite contains no wasm32-wasip2 test cases.',
    );
    await _writeReport(report, options);
    io.stdout.writeln('wasi-testsuite-preview2 status: missing-tests');
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
  final totals = await _readOfficialTotals(rawJsonPath);
  final passed =
      result.exitCode == 0 &&
      totals.total > 0 &&
      totals.failed == 0 &&
      totals.skipped == 0 &&
      totals.xfailed == 0 &&
      totals.xpassed == 0 &&
      totals.passed == totals.total;
  final report = _Report(
    status: passed ? 'passed' : 'failed',
    startedAt: startedAt,
    endedAt: DateTime.now().toUtc(),
    testsuiteDir: options.testsuiteDir,
    testsuiteHead: await _gitHead(options.testsuiteDir),
    suiteDirs: suiteDirs,
    totals: totals,
    runnerExitCode: result.exitCode,
    message: passed
        ? 'Official wasi-testsuite Preview2 passed 100%.'
        : 'Official wasi-testsuite Preview2 did not pass 100%.',
  );
  await _writeReport(report, options);
  io.stdout.write(result.stdout);
  io.stderr.write(result.stderr);
  io.stdout.writeln('wasi-testsuite-preview2 status: ${report.status}');
  io.stdout.writeln(
    'totals: total=${totals.total} passed=${totals.passed} '
    'failed=${totals.failed} skipped=${totals.skipped} '
    'xfailed=${totals.xfailed} xpassed=${totals.xpassed}',
  );
  io.exitCode = passed ? 0 : 1;
}

Future<List<String>> _findPreview2SuiteDirs(String testsuiteDir) async {
  final root = io.Directory(testsuiteDir);
  if (!await root.exists()) {
    return const <String>[];
  }
  final dirs = <String>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! io.Directory || _basename(entity.path) != 'wasm32-wasip2') {
      continue;
    }
    if (await _hasImmediateWasmTest(entity)) {
      dirs.add(entity.path);
    }
  }
  dirs.sort();
  return List<String>.unmodifiable(dirs);
}

Future<bool> _hasImmediateWasmTest(io.Directory directory) async {
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is io.File && entity.path.endsWith('.wasm')) {
      return true;
    }
  }
  return false;
}

Future<io.ProcessResult> _runOfficialRunner({
  required _Options options,
  required List<String> suiteDirs,
  required String rawJsonPath,
}) {
  final runnerDir = io.Directory(options.runnerDir);
  if (!runnerDir.existsSync()) {
    throw StateError('official wasi-testsuite runner not found: $runnerDir');
  }
  return io.Process.run(
    'python3',
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

Future<_Totals> _readOfficialTotals(String rawJsonPath) async {
  final file = io.File(rawJsonPath);
  if (!await file.exists()) {
    return const _Totals(failed: 1);
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
  for (final suite in results) {
    final tests = (suite['tests'] as List<Object?>? ?? const <Object?>[])
        .cast<Map<String, Object?>>();
    for (final test in tests) {
      total++;
      switch (test['outcome']) {
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
    }
  }
  return _Totals(
    total: total,
    passed: passed,
    failed: failed,
    skipped: skipped,
    xfailed: xfailed,
    xpassed: xpassed,
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
    required this.runtimeAdapter,
    required this.jsonPath,
    required this.markdownPath,
  });

  final bool showHelp;
  final String testsuiteDir;
  final String runnerDir;
  final String runtimeAdapter;
  final String jsonPath;
  final String markdownPath;

  static _Options parse(List<String> args) {
    var showHelp = false;
    var testsuiteDir = '.dart_tool/wasi-testsuite';
    String? runnerDir;
    var runtimeAdapter = 'tool/wasi_testsuite_wasd_adapter.py';
    var jsonPath = '.dart_tool/spec_runner/wasi_testsuite_preview2_latest.json';
    var markdownPath =
        '.dart_tool/spec_runner/wasi_testsuite_preview2_failures.md';

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

final class _Report {
  const _Report({
    required this.status,
    required this.startedAt,
    required this.endedAt,
    required this.testsuiteDir,
    required this.testsuiteHead,
    required this.suiteDirs,
    required this.totals,
    required this.runnerExitCode,
    required this.message,
  });

  final String status;
  final DateTime startedAt;
  final DateTime endedAt;
  final String testsuiteDir;
  final String? testsuiteHead;
  final List<String> suiteDirs;
  final _Totals totals;
  final int? runnerExitCode;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'suite': 'official-wasi-testsuite-preview2',
    'status': status,
    'started_at_utc': startedAt.toIso8601String(),
    'ended_at_utc': endedAt.toIso8601String(),
    'testsuite_dir': testsuiteDir,
    'testsuite_head': testsuiteHead,
    'suite_dirs': suiteDirs,
    'totals': totals.toJson(),
    'runner_exit_code': runnerExitCode,
    'message': message,
  };

  String toMarkdown() {
    final b = StringBuffer()
      ..writeln('# Official WASI Testsuite Preview2 Report')
      ..writeln()
      ..writeln('- Status: `$status`')
      ..writeln('- Started (UTC): `${startedAt.toIso8601String()}`')
      ..writeln('- Ended (UTC): `${endedAt.toIso8601String()}`')
      ..writeln('- Testsuite dir: `$testsuiteDir`')
      ..writeln('- Testsuite HEAD: `${testsuiteHead ?? 'unknown'}`')
      ..writeln('- Message: $message')
      ..writeln(
        '- Totals: `total=${totals.total} passed=${totals.passed} '
        'failed=${totals.failed} skipped=${totals.skipped} '
        'xfailed=${totals.xfailed} xpassed=${totals.xpassed}`',
      )
      ..writeln();
    if (suiteDirs.isEmpty) {
      b.writeln('No official `wasm32-wasip2` test directories were found.');
    } else {
      b.writeln('## Suite Dirs');
      for (final suiteDir in suiteDirs) {
        b.writeln('- `$suiteDir`');
      }
    }
    return b.toString();
  }
}

const String _usage = '''
Usage: dart run tool/wasi_testsuite_preview2_runner.dart [options]

Options:
  --testsuite-dir DIR     Official wasi-testsuite checkout.
  --runner-dir DIR        Directory containing the wasi_test_runner package.
  --runtime-adapter FILE  Runtime adapter passed to official runner.
  --json FILE             Write machine-readable report.
  --markdown FILE         Write markdown report.
  -h, --help              Show this help.
''';
