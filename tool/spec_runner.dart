import 'dart:convert';
import 'dart:io';

enum RunnerTarget { vm, js, wasm, all }

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

final class _SpecFileSummary {
  const _SpecFileSummary({
    required this.passed,
    required this.commandsSeen,
    required this.commandsPassed,
    required this.commandsFailed,
    required this.commandsSkipped,
    required this.firstFailureReason,
    required this.firstFailureLine,
  });

  final bool passed;
  final int commandsSeen;
  final int commandsPassed;
  final int commandsFailed;
  final int commandsSkipped;
  final String? firstFailureReason;
  final int? firstFailureLine;
}

final class _SpecSuiteSummary {
  const _SpecSuiteSummary({
    required this.testsuiteRevision,
    required this.totals,
    required this.reasonCounts,
    required this.files,
  });

  final String? testsuiteRevision;
  final Map<String, Object?> totals;
  final Map<String, int> reasonCounts;
  final Map<String, _SpecFileSummary> files;

  factory _SpecSuiteSummary.fromPayload(
    Map<String, Object?> payload, {
    required RunnerTarget target,
    required _SpecSuiteKind suite,
  }) {
    final totals = _asStringObjectMap(
      payload['totals'],
      context: '${suite.name}/${target.name} totals',
    );
    final reasonCounts = _asStringIntMap(
      payload['reason_counts'],
      context: '${suite.name}/${target.name} reason_counts',
    );

    final rawFiles = payload['files'];
    if (rawFiles is! List) {
      throw FormatException(
        'Expected `${suite.name}/${target.name} files` to be a list.',
      );
    }
    final files = <String, _SpecFileSummary>{};
    for (var i = 0; i < rawFiles.length; i++) {
      final filePayload = _asStringObjectMap(
        rawFiles[i],
        context: '${suite.name}/${target.name} files[$i]',
      );
      final path = filePayload['path'];
      if (path is! String || path.isEmpty) {
        throw FormatException(
          'Expected `${suite.name}/${target.name} files[$i].path` to be a non-empty string.',
        );
      }
      if (files.containsKey(path)) {
        throw FormatException(
          'Duplicate `${suite.name}/${target.name}` file path: $path',
        );
      }
      final firstFailureReasonRaw = filePayload['first_failure_reason'];
      if (firstFailureReasonRaw != null && firstFailureReasonRaw is! String) {
        throw FormatException(
          'Expected `${suite.name}/${target.name} files[$i].first_failure_reason` to be string or null.',
        );
      }
      files[path] = _SpecFileSummary(
        passed: _asBool(
          filePayload['passed'],
          context: '${suite.name}/${target.name} files[$i].passed',
        ),
        commandsSeen: _asInt(
          filePayload['commands_seen'],
          context: '${suite.name}/${target.name} files[$i].commands_seen',
        ),
        commandsPassed: _asInt(
          filePayload['commands_passed'],
          context: '${suite.name}/${target.name} files[$i].commands_passed',
        ),
        commandsFailed: _asInt(
          filePayload['commands_failed'],
          context: '${suite.name}/${target.name} files[$i].commands_failed',
        ),
        commandsSkipped: _asInt(
          filePayload['commands_skipped'] ?? 0,
          context: '${suite.name}/${target.name} files[$i].commands_skipped',
        ),
        firstFailureReason: firstFailureReasonRaw as String?,
        firstFailureLine: _asNullableInt(
          filePayload['first_failure_line'],
          context: '${suite.name}/${target.name} files[$i].first_failure_line',
        ),
      );
    }
    return _SpecSuiteSummary(
      testsuiteRevision: payload['testsuite_revision'] as String?,
      totals: totals,
      reasonCounts: reasonCounts,
      files: files,
    );
  }
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
  final disableComponentSubset = args.contains('--no-component-subset');
  final optionalComponentSubset = args.contains('--component-subset-optional');
  final explicitStrictComponentSubset = args.contains(
    '--strict-component-subset',
  );
  final explicitEnableComponentSubset = args.contains('--component-subset');
  final runComponentSubset =
      explicitStrictComponentSubset ||
      explicitEnableComponentSubset ||
      !disableComponentSubset;
  final strictComponentSubset =
      runComponentSubset &&
      (explicitStrictComponentSubset ||
          (!optionalComponentSubset &&
              !explicitEnableComponentSubset &&
              !disableComponentSubset));
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
  if (runComponentSubset) {
    steps.add(
      await _runStep(
        name: 'component-subset',
        command: const <String>[
          'dart',
          'run',
          'tool/component_subset_runner.dart',
        ],
        optional: !strictComponentSubset,
      ),
    );
  }

  switch (target) {
    case RunnerTarget.vm:
      steps.addAll(
        await _runVmSuite(
          suite,
          target: target,
          testsuiteDir: testsuiteDir,
          strictProposals: strictProposals,
        ),
      );
    case RunnerTarget.js:
      steps.addAll(
        await _runJsSuite(
          suite,
          target: target,
          testsuiteDir: testsuiteDir,
          strictProposals: strictProposals,
        ),
      );
    case RunnerTarget.wasm:
      steps.addAll(
        await _runWasmSuite(
          suite,
          target: target,
          testsuiteDir: testsuiteDir,
          strictProposals: strictProposals,
        ),
      );
    case RunnerTarget.all:
      steps.addAll(
        await _runAllTargetsSuite(
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
    'component_subset': runComponentSubset,
    'strict_component_subset': strictComponentSubset,
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
  required RunnerTarget target,
  required String? testsuiteDir,
  required bool strictProposals,
}) async {
  final steps = <StepResult>[];
  if (suite != RunnerSuite.proposal) {
    steps.add(await _runStep(name: 'vm-tests', command: ['dart', 'test']));
  }
  for (final specSuite in _specSuitesForRunnerSuite(suite)) {
    final artifacts = _artifactsForSuite(specSuite, target: target);
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
  required RunnerTarget target,
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
    final artifacts = _artifactsForSuite(specSuite, target: target);
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
  required RunnerTarget target,
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
    final artifacts = _artifactsForSuite(specSuite, target: target);
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

Future<List<StepResult>> _runAllTargetsSuite(
  RunnerSuite suite, {
  required String? testsuiteDir,
  required bool strictProposals,
}) async {
  final steps = <StepResult>[];
  steps.addAll(
    _prefixTargetSteps(
      RunnerTarget.vm,
      await _runVmSuite(
        suite,
        target: RunnerTarget.vm,
        testsuiteDir: testsuiteDir,
        strictProposals: strictProposals,
      ),
    ),
  );
  steps.addAll(
    _prefixTargetSteps(
      RunnerTarget.js,
      await _runJsSuite(
        suite,
        target: RunnerTarget.js,
        testsuiteDir: testsuiteDir,
        strictProposals: strictProposals,
      ),
    ),
  );
  steps.addAll(
    _prefixTargetSteps(
      RunnerTarget.wasm,
      await _runWasmSuite(
        suite,
        target: RunnerTarget.wasm,
        testsuiteDir: testsuiteDir,
        strictProposals: strictProposals,
      ),
    ),
  );
  steps.add(await _runCrossTargetConsistencyStep(suite));
  return steps;
}

List<StepResult> _prefixTargetSteps(
  RunnerTarget target,
  List<StepResult> steps,
) {
  return steps
      .map(
        (step) => StepResult(
          name: '${target.name}:${step.name}',
          command: step.command,
          exitCode: step.exitCode,
          durationMs: step.durationMs,
          stdout: step.stdout,
          stderr: step.stderr,
          optional: step.optional,
        ),
      )
      .toList(growable: false);
}

Future<StepResult> _runCrossTargetConsistencyStep(RunnerSuite suite) async {
  final started = DateTime.now();
  try {
    final mismatches = <String>[];
    for (final specSuite in _specSuitesForRunnerSuite(suite)) {
      final summariesByTarget = <RunnerTarget, _SpecSuiteSummary>{};
      for (final target in const <RunnerTarget>[
        RunnerTarget.vm,
        RunnerTarget.js,
        RunnerTarget.wasm,
      ]) {
        final artifacts = _artifactsForSuite(specSuite, target: target);
        final file = File(artifacts.resultJsonPath);
        if (!file.existsSync()) {
          mismatches.add(
            '${specSuite.name}: missing ${target.name} result '
            '${artifacts.resultJsonPath}',
          );
          continue;
        }
        final payload = jsonDecode(await file.readAsString());
        if (payload is! Map) {
          mismatches.add('${specSuite.name}: invalid ${target.name} json');
          continue;
        }
        try {
          summariesByTarget[target] = _SpecSuiteSummary.fromPayload(
            payload.cast<String, Object?>(),
            target: target,
            suite: specSuite,
          );
        } on FormatException catch (error) {
          mismatches.add(
            '${specSuite.name}: malformed ${target.name} payload ($error)',
          );
        }
      }
      final vmSummary = summariesByTarget[RunnerTarget.vm];
      final jsSummary = summariesByTarget[RunnerTarget.js];
      final wasmSummary = summariesByTarget[RunnerTarget.wasm];
      if (vmSummary == null || jsSummary == null || wasmSummary == null) {
        continue;
      }
      _compareTargetSummaries(
        specSuite: specSuite,
        baselineTarget: RunnerTarget.vm,
        baseline: vmSummary,
        target: RunnerTarget.js,
        candidate: jsSummary,
        mismatches: mismatches,
      );
      _compareTargetSummaries(
        specSuite: specSuite,
        baselineTarget: RunnerTarget.vm,
        baseline: vmSummary,
        target: RunnerTarget.wasm,
        candidate: wasmSummary,
        mismatches: mismatches,
      );
    }
    final ended = DateTime.now();
    if (mismatches.isNotEmpty) {
      return StepResult(
        name: 'cross-target-consistency',
        command: const <String>['internal', 'cross-target-consistency'],
        exitCode: 1,
        durationMs: ended.difference(started).inMilliseconds,
        stdout: '',
        stderr: mismatches.join('\n'),
      );
    }
    return StepResult(
      name: 'cross-target-consistency',
      command: const <String>['internal', 'cross-target-consistency'],
      exitCode: 0,
      durationMs: ended.difference(started).inMilliseconds,
      stdout: 'VM/JS/Wasm totals match for requested suites.',
      stderr: '',
    );
  } catch (error, stackTrace) {
    final ended = DateTime.now();
    return StepResult(
      name: 'cross-target-consistency',
      command: const <String>['internal', 'cross-target-consistency'],
      exitCode: 1,
      durationMs: ended.difference(started).inMilliseconds,
      stdout: '',
      stderr: '$error\n$stackTrace',
    );
  }
}

void _compareTargetSummaries({
  required _SpecSuiteKind specSuite,
  required RunnerTarget baselineTarget,
  required _SpecSuiteSummary baseline,
  required RunnerTarget target,
  required _SpecSuiteSummary candidate,
  required List<String> mismatches,
}) {
  for (final key in const <String>[
    'files_total',
    'files_passed',
    'files_failed',
    'commands_seen',
    'commands_passed',
    'commands_failed',
    'commands_skipped',
  ]) {
    final baselineValue = baseline.totals[key];
    final candidateValue = candidate.totals[key];
    if (baselineValue != candidateValue) {
      mismatches.add(
        '${specSuite.name}: totals `$key` mismatch '
        '(${baselineTarget.name}=$baselineValue ${target.name}=$candidateValue)',
      );
    }
  }

  if (baseline.testsuiteRevision != candidate.testsuiteRevision) {
    mismatches.add(
      '${specSuite.name}: testsuite revision mismatch '
      '(${baselineTarget.name}=${baseline.testsuiteRevision} '
      '${target.name}=${candidate.testsuiteRevision})',
    );
  }

  if (!_intMapEquals(baseline.reasonCounts, candidate.reasonCounts)) {
    mismatches.add(
      '${specSuite.name}: reason_counts mismatch '
      '(${baselineTarget.name}=${baseline.reasonCounts} '
      '${target.name}=${candidate.reasonCounts})',
    );
  }

  final baselinePaths = baseline.files.keys.toSet();
  final candidatePaths = candidate.files.keys.toSet();
  final missing = baselinePaths.difference(candidatePaths);
  final extra = candidatePaths.difference(baselinePaths);
  if (missing.isNotEmpty) {
    mismatches.add(
      '${specSuite.name}: ${target.name} missing files '
      '${missing.take(5).join(', ')}${missing.length > 5 ? ' ...' : ''}',
    );
  }
  if (extra.isNotEmpty) {
    mismatches.add(
      '${specSuite.name}: ${target.name} extra files '
      '${extra.take(5).join(', ')}${extra.length > 5 ? ' ...' : ''}',
    );
  }

  final shared = baselinePaths.intersection(candidatePaths).toList()
    ..sort((a, b) => a.compareTo(b));
  for (final path in shared) {
    final baselineFile = baseline.files[path]!;
    final candidateFile = candidate.files[path]!;
    if (baselineFile.passed != candidateFile.passed) {
      mismatches.add(
        '${specSuite.name}: file pass mismatch `$path` '
        '(${baselineTarget.name}=${baselineFile.passed} '
        '${target.name}=${candidateFile.passed})',
      );
    }

    if (baselineFile.commandsSeen != candidateFile.commandsSeen) {
      mismatches.add(
        '${specSuite.name}: commands_seen mismatch `$path` '
        '(${baselineTarget.name}=${baselineFile.commandsSeen} '
        '${target.name}=${candidateFile.commandsSeen})',
      );
    }
    if (baselineFile.commandsPassed != candidateFile.commandsPassed) {
      mismatches.add(
        '${specSuite.name}: commands_passed mismatch `$path` '
        '(${baselineTarget.name}=${baselineFile.commandsPassed} '
        '${target.name}=${candidateFile.commandsPassed})',
      );
    }
    if (baselineFile.commandsFailed != candidateFile.commandsFailed) {
      mismatches.add(
        '${specSuite.name}: commands_failed mismatch `$path` '
        '(${baselineTarget.name}=${baselineFile.commandsFailed} '
        '${target.name}=${candidateFile.commandsFailed})',
      );
    }
    if (baselineFile.commandsSkipped != candidateFile.commandsSkipped) {
      mismatches.add(
        '${specSuite.name}: commands_skipped mismatch `$path` '
        '(${baselineTarget.name}=${baselineFile.commandsSkipped} '
        '${target.name}=${candidateFile.commandsSkipped})',
      );
    }

    if (!baselineFile.passed || !candidateFile.passed) {
      if (baselineFile.firstFailureReason != candidateFile.firstFailureReason) {
        mismatches.add(
          '${specSuite.name}: first_failure_reason mismatch `$path` '
          '(${baselineTarget.name}=${baselineFile.firstFailureReason} '
          '${target.name}=${candidateFile.firstFailureReason})',
        );
      }
      if (baselineFile.firstFailureLine != candidateFile.firstFailureLine) {
        mismatches.add(
          '${specSuite.name}: first_failure_line mismatch `$path` '
          '(${baselineTarget.name}=${baselineFile.firstFailureLine} '
          '${target.name}=${candidateFile.firstFailureLine})',
        );
      }
    }
  }
}

bool _intMapEquals(Map<String, int> left, Map<String, int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

Map<String, Object?> _asStringObjectMap(
  Object? value, {
  required String context,
}) {
  if (value is! Map) {
    throw FormatException('Expected `$context` map.');
  }
  final out = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw FormatException('Expected `$context` string keys.');
    }
    out[key] = entry.value;
  }
  return out;
}

Map<String, int> _asStringIntMap(Object? value, {required String context}) {
  if (value == null) {
    return const <String, int>{};
  }
  final map = _asStringObjectMap(value, context: context);
  final out = <String, int>{};
  for (final entry in map.entries) {
    out[entry.key] = _asInt(entry.value, context: '$context.${entry.key}');
  }
  return out;
}

int _asInt(Object? value, {required String context}) {
  if (value is! num) {
    throw FormatException('Expected `$context` numeric value.');
  }
  return value.toInt();
}

int? _asNullableInt(Object? value, {required String context}) {
  if (value == null) {
    return null;
  }
  return _asInt(value, context: context);
}

bool _asBool(Object? value, {required String context}) {
  if (value is! bool) {
    throw FormatException('Expected `$context` boolean value.');
  }
  return value;
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
    case 'all':
      return RunnerTarget.all;
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

_SpecSuiteArtifacts _artifactsForSuite(
  _SpecSuiteKind suite, {
  required RunnerTarget target,
}) {
  final targetPrefix = target.name;
  switch (suite) {
    case _SpecSuiteKind.core:
      return _SpecSuiteArtifacts(
        suite: _SpecSuiteKind.core,
        stepPrefix: 'core',
        manifestPath:
            '.dart_tool/spec_runner/${targetPrefix}_core_manifest.json',
        bundlePath: '.dart_tool/spec_runner/${targetPrefix}_core_bundle',
        resultJsonPath:
            '.dart_tool/spec_runner/${targetPrefix}_core_latest.json',
        reportMarkdownPath:
            '.dart_tool/spec_runner/${targetPrefix}_wasm_core_failures.md',
      );
    case _SpecSuiteKind.proposal:
      return _SpecSuiteArtifacts(
        suite: _SpecSuiteKind.proposal,
        stepPrefix: 'proposal',
        manifestPath:
            '.dart_tool/spec_runner/${targetPrefix}_proposal_manifest.json',
        bundlePath: '.dart_tool/spec_runner/${targetPrefix}_proposal_bundle',
        resultJsonPath:
            '.dart_tool/spec_runner/${targetPrefix}_proposal_latest.json',
        reportMarkdownPath:
            '.dart_tool/spec_runner/${targetPrefix}_wasm_proposal_failures.md',
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
  final target = payload['target'] as String? ?? 'vm';
  String corePath() => '.dart_tool/spec_runner/${target}_wasm_core_failures.md';
  String proposalPath() =>
      '.dart_tool/spec_runner/${target}_wasm_proposal_failures.md';
  if (suite == RunnerSuite.core.name) {
    b.writeln('- Core testsuite summary is written to `${corePath()}`.');
  } else if (suite == RunnerSuite.proposal.name) {
    b.writeln(
      '- Proposal testsuite summary is written to `${proposalPath()}`.',
    );
  } else {
    b.writeln('- Core testsuite summary is written to `${corePath()}`.');
    b.writeln(
      '- Proposal testsuite summary is written to `${proposalPath()}`.',
    );
  }
  if (payload['strict_proposals'] != true && suite != RunnerSuite.core.name) {
    b.writeln(
      '- Proposal failures are non-gating by default; pass `--strict-proposals` to enforce them.',
    );
  }
  if (payload['component_subset'] == true) {
    if (payload['strict_component_subset'] == true) {
      b.writeln('- Component subset conformance is gating.');
    } else {
      b.writeln(
        '- Component subset conformance is non-gating (`--component-subset-optional`).',
      );
    }
    b.writeln(
      '- Component subset reports are written to `.dart_tool/spec_runner/component_subset_latest.json` and `.dart_tool/spec_runner/component_subset_failures.md`.',
    );
  } else {
    b.writeln(
      '- Component subset conformance is disabled (`--no-component-subset`).',
    );
  }
  if (target == RunnerTarget.all.name) {
    b.writeln(
      '- Cross-target totals consistency is enforced by the `cross-target-consistency` step.',
    );
  }
  b.writeln(
    '- Raw run payload is written to `.dart_tool/spec_runner/latest.json`.',
  );

  return b.toString();
}

void _printUsage() {
  stdout.writeln(
    'Usage: dart run tool/spec_runner.dart --target=<vm|js|wasm|all> --suite=<core|proposal|all>',
  );
  stdout.writeln(
    'Optional: --report=<path> --json=<path> --testsuite-dir=<path> --strict-proposals --no-component-subset --component-subset-optional --component-subset --strict-component-subset',
  );
}
