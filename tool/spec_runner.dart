import 'dart:convert';
import 'dart:io';

enum RunnerTarget { vm, js, wasm }

enum RunnerSuite { core, proposal, all }

enum _SpecSuiteKind { core, proposal }

final class _SpecSuiteArtifacts {
  const _SpecSuiteArtifacts({
    required this.suite,
    required this.stepPrefix,
    required this.manifestPath,
    required this.bundlePath,
    required this.resultJsonPath,
    required this.reportMarkdownPath,
  });

  final _SpecSuiteKind suite;
  final String stepPrefix;
  final String manifestPath;
  final String bundlePath;
  final String resultJsonPath;
  final String reportMarkdownPath;
}

final class StepResult {
  StepResult({
    required this.name,
    required this.command,
    required this.exitCode,
    required this.durationMs,
    required this.stdout,
    required this.stderr,
    this.optional = false,
  });

  final String name;
  final List<String> command;
  final int exitCode;
  final int durationMs;
  final String stdout;
  final String stderr;
  final bool optional;

  bool get success => exitCode == 0;

  Map<String, Object?> toJson() => {
    'name': name,
    'command': command,
    'exit_code': exitCode,
    'duration_ms': durationMs,
    'optional': optional,
    'success': success,
    'stdout': stdout,
    'stderr': stderr,
  };
}

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    return;
  }

  final target = _parseTarget(_argValue(args, '--target') ?? 'vm');
  final suite = _parseSuite(_argValue(args, '--suite') ?? 'all');
  final testsuiteDir = _argValue(args, '--testsuite-dir');
  final strictProposals = args.contains('--strict-proposals');
  final reportPath =
      _argValue(args, '--report') ??
      '.dart_tool/spec_runner/wasm_conformance_matrix.md';
  final jsonPath =
      _argValue(args, '--json') ?? '.dart_tool/spec_runner/latest.json';

  final startedAt = DateTime.now().toUtc();
  final steps = <StepResult>[];

  steps.add(
    await _runStep(
      name: 'toolchain-check',
      command: ['bash', 'tool/ensure_toolchains.sh', '--check'],
      optional: true,
    ),
  );
  steps.add(
    await _runStep(
      name: 'analyze',
      command: ['dart', 'analyze', 'lib', 'test', 'tool', 'example'],
    ),
  );

  switch (target) {
    case RunnerTarget.vm:
      steps.addAll(
        await _runVmSuite(
          suite,
          testsuiteDir: testsuiteDir,
          strictProposals: strictProposals,
        ),
      );
    case RunnerTarget.js:
      steps.addAll(
        await _runJsSuite(
          suite,
          testsuiteDir: testsuiteDir,
          strictProposals: strictProposals,
        ),
      );
    case RunnerTarget.wasm:
      steps.addAll(
        await _runWasmSuite(
          suite,
          testsuiteDir: testsuiteDir,
          strictProposals: strictProposals,
        ),
      );
  }

  final endedAt = DateTime.now().toUtc();
  final failedRequired = steps.where((s) => !s.optional).any((s) => !s.success);
  final status = failedRequired ? 'failed' : 'passed';

  final payload = <String, Object?>{
    'started_at_utc': startedAt.toIso8601String(),
    'ended_at_utc': endedAt.toIso8601String(),
    'target': target.name,
    'suite': suite.name,
    'testsuite_dir': testsuiteDir,
    'strict_proposals': strictProposals,
    'status': status,
    'steps': steps.map((s) => s.toJson()).toList(growable: false),
  };

  final jsonFile = File(jsonPath);
  await jsonFile.parent.create(recursive: true);
  await jsonFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );

  final reportFile = File(reportPath);
  await reportFile.parent.create(recursive: true);
  await reportFile.writeAsString(
    _renderMarkdownReport(payload: payload, steps: steps),
  );

  stdout.writeln('spec-runner status: $status');
  stdout.writeln('json report: ${jsonFile.path}');
  stdout.writeln('markdown report: ${reportFile.path}');

  if (failedRequired) {
    exitCode = 1;
  }
}

Future<List<StepResult>> _runVmSuite(
  RunnerSuite suite, {
  required String? testsuiteDir,
  required bool strictProposals,
}) async {
  final steps = <StepResult>[];
  if (suite != RunnerSuite.proposal) {
    steps.add(await _runStep(name: 'vm-tests', command: ['dart', 'test']));
  }
  for (final specSuite in _specSuitesForRunnerSuite(suite)) {
    final artifacts = _artifactsForSuite(specSuite);
    final optional = specSuite == _SpecSuiteKind.proposal && !strictProposals;
    steps.add(
      await _runStep(
        name: '${artifacts.stepPrefix}-testsuite',
        command: _testsuiteRunnerCommand(artifacts, testsuiteDir),
        optional: optional,
      ),
    );
  }
  if (suite != RunnerSuite.core) {
    steps.add(
      await _runStep(
        name: 'spec-sync-check',
        command: ['dart', 'run', 'tool/spec_sync.dart'],
        optional: true,
      ),
    );
  }
  return steps;
}

Future<List<StepResult>> _runJsSuite(
  RunnerSuite suite, {
  required String? testsuiteDir,
  required bool strictProposals,
}) async {
  final steps = <StepResult>[];
  final nodeCheck = await _runStep(
    name: 'node-check',
    command: ['node', '--version'],
    optional: true,
  );
  steps.add(nodeCheck);

  if (!nodeCheck.success) {
    steps.add(
      StepResult(
        name: 'js-target-prerequisite',
        command: const ['node', '--version'],
        exitCode: 1,
        durationMs: 0,
        stdout: '',
        stderr: 'Node.js is required for --target=js.',
      ),
    );
    return steps;
  }

  if (suite != RunnerSuite.proposal) {
    steps.add(
      await _runStep(name: 'js-tests', command: ['dart', 'test', '-p', 'node']),
    );
  }
  for (final specSuite in _specSuitesForRunnerSuite(suite)) {
    final artifacts = _artifactsForSuite(specSuite);
    final optional = specSuite == _SpecSuiteKind.proposal && !strictProposals;
    if (specSuite == _SpecSuiteKind.proposal) {
      steps.add(
        await _runStep(
          name: 'js-threads-portable',
          command: [
            'dart',
            'test',
            '-p',
            'node',
            'test/threads_portable_test.dart',
          ],
        ),
      );
    }
    steps.add(
      await _runStep(
        name: '${artifacts.stepPrefix}-prepare-manifest',
        command: _testsuitePrepareManifestCommand(artifacts, testsuiteDir),
        optional: optional,
      ),
    );
    steps.add(
      await _runStep(
        name: '${artifacts.stepPrefix}-player-js-compile',
        command: const [
          'dart',
          'compile',
          'js',
          'tool/spec_testsuite_player.dart',
          '-o',
          '.dart_tool/spec_runner/spec_testsuite_player.js',
        ],
        optional: optional,
      ),
    );
    steps.add(
      await _runStep(
        name: '${artifacts.stepPrefix}-player-js-run',
        command: [
          'node',
          'tool/run_spec_player_js.mjs',
          '.dart_tool/spec_runner/spec_testsuite_player.js',
          artifacts.manifestPath,
          artifacts.resultJsonPath,
        ],
        optional: optional,
      ),
    );
    steps.add(
      await _runStep(
        name: '${artifacts.stepPrefix}-report',
        command: _resultReportCommand(artifacts),
        optional: optional,
      ),
    );
  }
  if (suite != RunnerSuite.core) {
    steps.add(
      await _runStep(
        name: 'spec-sync-check',
        command: ['dart', 'run', 'tool/spec_sync.dart'],
        optional: true,
      ),
    );
  }
  return steps;
}

Future<List<StepResult>> _runWasmSuite(
  RunnerSuite suite, {
  required String? testsuiteDir,
  required bool strictProposals,
}) async {
  final steps = <StepResult>[];
  if (suite != RunnerSuite.proposal) {
    steps.add(
      await _runStep(
        name: 'wasm-compile-smoke',
        command: [
          'dart',
          'compile',
          'wasm',
          'example/invoke.dart',
          '-o',
          '.dart_tool/spec_runner/invoke.wasm',
        ],
      ),
    );
    steps.add(
      await _runStep(
        name: 'vm-regression-after-wasm-compile',
        command: ['dart', 'test'],
      ),
    );
  }
  final nodeCheck = await _runStep(
    name: 'node-check',
    command: ['node', '--version'],
    optional: true,
  );
  steps.add(nodeCheck);

  if (!nodeCheck.success) {
    steps.add(
      StepResult(
        name: 'wasm-target-prerequisite',
        command: const ['node', '--version'],
        exitCode: 1,
        durationMs: 0,
        stdout: '',
        stderr: 'Node.js is required to run --target=wasm checks.',
      ),
    );
    return steps;
  }

  for (final specSuite in _specSuitesForRunnerSuite(suite)) {
    final artifacts = _artifactsForSuite(specSuite);
    final optional = specSuite == _SpecSuiteKind.proposal && !strictProposals;
    if (specSuite == _SpecSuiteKind.proposal) {
      steps.add(
        await _runStep(
          name: 'wasm-threads-portable-compile',
          command: [
            'dart',
            'compile',
            'wasm',
            'tool/threads_portable_check.dart',
            '-o',
            '.dart_tool/spec_runner/threads_portable_check.wasm',
          ],
        ),
      );
      steps.add(
        await _runStep(
          name: 'wasm-threads-portable-run',
          command: [
            'node',
            'tool/run_wasm_main.mjs',
            '.dart_tool/spec_runner/threads_portable_check.mjs',
            '.dart_tool/spec_runner/threads_portable_check.wasm',
          ],
        ),
      );
    }
    steps.add(
      await _runStep(
        name: '${artifacts.stepPrefix}-prepare-manifest',
        command: _testsuitePrepareManifestCommand(artifacts, testsuiteDir),
        optional: optional,
      ),
    );
    steps.add(
      await _runStep(
        name: '${artifacts.stepPrefix}-player-wasm-compile',
        command: const [
          'dart',
          'compile',
          'wasm',
          'tool/spec_testsuite_player.dart',
          '-o',
          '.dart_tool/spec_runner/spec_testsuite_player.wasm',
        ],
        optional: optional,
      ),
    );
    steps.add(
      await _runStep(
        name: '${artifacts.stepPrefix}-player-wasm-run',
        command: [
          'node',
          'tool/run_spec_player_wasm.mjs',
          '.dart_tool/spec_runner/spec_testsuite_player.mjs',
          '.dart_tool/spec_runner/spec_testsuite_player.wasm',
          artifacts.manifestPath,
          artifacts.resultJsonPath,
        ],
        optional: optional,
      ),
    );
    steps.add(
      await _runStep(
        name: '${artifacts.stepPrefix}-report',
        command: _resultReportCommand(artifacts),
        optional: optional,
      ),
    );
  }
  steps.add(
    await _runStep(
      name: 'spec-sync-check',
      command: ['dart', 'run', 'tool/spec_sync.dart'],
      optional: true,
    ),
  );
  return steps;
}

RunnerTarget _parseTarget(String raw) {
  final normalized = raw.trim().toLowerCase();
  switch (normalized) {
    case 'vm':
      return RunnerTarget.vm;
    case 'js':
      return RunnerTarget.js;
    case 'wasm':
      return RunnerTarget.wasm;
    default:
      throw ArgumentError('Unsupported --target: $raw');
  }
}

RunnerSuite _parseSuite(String raw) {
  final normalized = raw.trim().toLowerCase();
  switch (normalized) {
    case 'core':
      return RunnerSuite.core;
    case 'proposal':
      return RunnerSuite.proposal;
    case 'all':
      return RunnerSuite.all;
    default:
      throw ArgumentError('Unsupported --suite: $raw');
  }
}

String? _argValue(List<String> args, String key) {
  for (var i = 0; i < args.length; i++) {
    final current = args[i];
    if (current == key && i + 1 < args.length) {
      return args[i + 1];
    }
    if (current.startsWith('$key=')) {
      return current.substring(key.length + 1);
    }
  }
  return null;
}

Future<StepResult> _runStep({
  required String name,
  required List<String> command,
  bool optional = false,
}) async {
  final started = DateTime.now();
  final result = await Process.run(command.first, command.sublist(1));
  final ended = DateTime.now();
  return StepResult(
    name: name,
    command: command,
    exitCode: result.exitCode,
    durationMs: ended.difference(started).inMilliseconds,
    stdout: (result.stdout as String?) ?? '',
    stderr: (result.stderr as String?) ?? '',
    optional: optional,
  );
}

List<_SpecSuiteKind> _specSuitesForRunnerSuite(RunnerSuite suite) {
  switch (suite) {
    case RunnerSuite.core:
      return const <_SpecSuiteKind>[_SpecSuiteKind.core];
    case RunnerSuite.proposal:
      return const <_SpecSuiteKind>[_SpecSuiteKind.proposal];
    case RunnerSuite.all:
      return const <_SpecSuiteKind>[
        _SpecSuiteKind.core,
        _SpecSuiteKind.proposal,
      ];
  }
}

_SpecSuiteArtifacts _artifactsForSuite(_SpecSuiteKind suite) {
  switch (suite) {
    case _SpecSuiteKind.core:
      return const _SpecSuiteArtifacts(
        suite: _SpecSuiteKind.core,
        stepPrefix: 'core',
        manifestPath: '.dart_tool/spec_runner/core_manifest.json',
        bundlePath: '.dart_tool/spec_runner/core_bundle',
        resultJsonPath: '.dart_tool/spec_runner/core_latest.json',
        reportMarkdownPath: '.dart_tool/spec_runner/wasm_core_failures.md',
      );
    case _SpecSuiteKind.proposal:
      return const _SpecSuiteArtifacts(
        suite: _SpecSuiteKind.proposal,
        stepPrefix: 'proposal',
        manifestPath: '.dart_tool/spec_runner/proposal_manifest.json',
        bundlePath: '.dart_tool/spec_runner/proposal_bundle',
        resultJsonPath: '.dart_tool/spec_runner/proposal_latest.json',
        reportMarkdownPath: '.dart_tool/spec_runner/wasm_proposal_failures.md',
      );
  }
}

List<String> _testsuiteRunnerCommand(
  _SpecSuiteArtifacts artifacts,
  String? testsuiteDir,
) {
  return <String>[
    'dart',
    'run',
    'tool/spec_testsuite_runner.dart',
    '--suite=${artifacts.suite.name}',
    '--output-json=${artifacts.resultJsonPath}',
    '--output-md=${artifacts.reportMarkdownPath}',
    if (testsuiteDir != null && testsuiteDir.trim().isNotEmpty)
      '--testsuite-dir=${testsuiteDir.trim()}',
  ];
}

List<String> _testsuitePrepareManifestCommand(
  _SpecSuiteArtifacts artifacts,
  String? testsuiteDir,
) {
  return <String>[
    'dart',
    'run',
    'tool/spec_testsuite_runner.dart',
    '--suite=${artifacts.suite.name}',
    '--prepare-manifest=${artifacts.manifestPath}',
    '--prepare-root=${artifacts.bundlePath}',
    if (testsuiteDir != null && testsuiteDir.trim().isNotEmpty)
      '--testsuite-dir=${testsuiteDir.trim()}',
  ];
}

List<String> _resultReportCommand(_SpecSuiteArtifacts artifacts) {
  return <String>[
    'dart',
    'run',
    'tool/spec_result_report.dart',
    '--input-json=${artifacts.resultJsonPath}',
    '--output-md=${artifacts.reportMarkdownPath}',
  ];
}

String _renderMarkdownReport({
  required Map<String, Object?> payload,
  required List<StepResult> steps,
}) {
  final b = StringBuffer()
    ..writeln('# WASM Conformance Matrix')
    ..writeln()
    ..writeln('- Started at (UTC): `${payload['started_at_utc']}`')
    ..writeln('- Ended at (UTC): `${payload['ended_at_utc']}`')
    ..writeln('- Target: `${payload['target']}`')
    ..writeln('- Suite: `${payload['suite']}`')
    ..writeln('- Status: `${payload['status']}`')
    ..writeln()
    ..writeln('## Step Results')
    ..writeln()
    ..writeln('| Step | Status | Duration (ms) | Command |')
    ..writeln('| --- | --- | ---: | --- |');

  for (final step in steps) {
    final status = step.success
        ? 'passed'
        : (step.optional ? 'optional-failed' : 'failed');
    b.writeln(
      '| ${step.name} | $status | ${step.durationMs} | `${step.command.join(' ')}` |',
    );
  }

  b.writeln();
  b.writeln('## Notes');
  b.writeln();
  final suite = payload['suite'] as String? ?? 'all';
  if (suite == RunnerSuite.core.name) {
    b.writeln(
      '- Core testsuite summary is written to `.dart_tool/spec_runner/wasm_core_failures.md`.',
    );
  } else if (suite == RunnerSuite.proposal.name) {
    b.writeln(
      '- Proposal testsuite summary is written to `.dart_tool/spec_runner/wasm_proposal_failures.md`.',
    );
  } else {
    b.writeln(
      '- Core testsuite summary is written to `.dart_tool/spec_runner/wasm_core_failures.md`.',
    );
    b.writeln(
      '- Proposal testsuite summary is written to `.dart_tool/spec_runner/wasm_proposal_failures.md`.',
    );
  }
  if (payload['strict_proposals'] != true && suite != RunnerSuite.core.name) {
    b.writeln(
      '- Proposal failures are non-gating by default; pass `--strict-proposals` to enforce them.',
    );
  }
  b.writeln(
    '- Raw run payload is written to `.dart_tool/spec_runner/latest.json`.',
  );

  return b.toString();
}

void _printUsage() {
  stdout.writeln(
    'Usage: dart run tool/spec_runner.dart --target=<vm|js|wasm> --suite=<core|proposal|all>',
  );
  stdout.writeln(
    'Optional: --report=<path> --json=<path> --testsuite-dir=<path> --strict-proposals',
  );
}
