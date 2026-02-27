import 'dart:convert';
import 'dart:io';

const String _defaultJsonPath =
    '.dart_tool/spec_runner/component_official_latest.json';
const String _defaultMarkdownPath =
    '.dart_tool/spec_runner/component_official_failures.md';
const String _defaultTestsuiteDir = 'third_party/component-model-tests/test';
const String _testsuiteSubmoduleHint =
    'Initialize testsuite submodule: '
    'git submodule update --init --recursive third_party/component-model-tests';
const List<String> _defaultPortableGroups = <String>[
  'async',
  'names',
  'resources',
  'values',
  'wasm-tools',
];
const Map<String, String> _defaultExpectedFailureReasonPatterns =
    <String, String>{
      // wasm-tools currently rejects `stream<char>` payload typing.
      'async/same-component-stream-future.wast':
          '`stream<char>` is not valid at this time',
      // Parser token coverage gap in current wasm-tools release.
      'async/trap-if-block-and-sync.wast': 'unexpected token, expected one of:',
      // Known wasm-tools/parser drift for package-name parsing assertions.
      'wasm-tools/import.wast': 'should have failed with: expected `/` after',
    };
const Map<String, String>
_allGroupsAdditionalExpectedFailureReasonPatterns = <String, String>{
  // Wasmtime policy assertions do not match raw wasm-tools validation behavior.
  'wasmtime/import.wast':
      'reexport of an imported function which is not implemented',
  'wasmtime/restrictions.wast':
      'root-level component imports are not supported',
  'wasmtime/simple.wast': 'root-level component imports are not supported',
  'wasmtime/types.wast': 'type nesting is too deep',
};

Future<void> main(List<String> args) async {
  final testsuiteDir =
      _argValue(args, '--testsuite-dir') ?? _defaultTestsuiteDir;
  final outputJsonPath = _argValue(args, '--json') ?? _defaultJsonPath;
  final outputMarkdownPath =
      _argValue(args, '--markdown') ?? _defaultMarkdownPath;
  final features = _argValue(args, '--features') ?? 'all';
  final wasmToolsBin =
      _argValue(args, '--wasm-tools-bin') ?? '.toolchains/bin/wasm-tools';
  final includePattern = _argValue(args, '--include-pattern');
  final allGroups = args.contains('--all-groups');
  final requireTestsuiteDir = args.contains('--require-testsuite-dir');
  final ignoreErrorMessages = !args.contains('--no-ignore-error-messages');
  final disableDefaultExpectedFailures = args.contains(
    '--no-default-expected-failures',
  );
  final expectedFailuresArg = _argValue(args, '--expected-failures');
  final expectedFailureRules = <String, _ExpectedFailureRule>{
    if (!disableDefaultExpectedFailures)
      ..._defaultExpectedFailureReasonPatterns.map(
        (path, reasonContains) => MapEntry(
          path,
          _ExpectedFailureRule(path: path, reasonContains: reasonContains),
        ),
      ),
    if (!disableDefaultExpectedFailures && allGroups)
      ..._allGroupsAdditionalExpectedFailureReasonPatterns.map(
        (path, reasonContains) => MapEntry(
          path,
          _ExpectedFailureRule(path: path, reasonContains: reasonContains),
        ),
      ),
  };
  if (expectedFailuresArg != null) {
    for (final path
        in expectedFailuresArg
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)) {
      expectedFailureRules[path] = _ExpectedFailureRule(path: path);
    }
  }
  final expectedFailures = expectedFailureRules.keys.toSet();
  final groupsArg = _argValue(args, '--groups');
  final selectedGroups = allGroups
      ? const <String>[]
      : (groupsArg == null
            ? _defaultPortableGroups
            : groupsArg
                  .split(',')
                  .map((value) => value.trim())
                  .where((value) => value.isNotEmpty)
                  .toList(growable: false));
  final filterByGroup = selectedGroups.isNotEmpty;
  final effectiveGroups = filterByGroup
      ? selectedGroups
      : const <String>['all'];

  final startedAt = DateTime.now().toUtc();
  final testsuite = Directory(testsuiteDir);
  if (!testsuite.existsSync()) {
    await _writeSkippedReport(
      outputJsonPath: outputJsonPath,
      outputMarkdownPath: outputMarkdownPath,
      startedAt: startedAt,
      testsuiteDir: testsuiteDir,
      selectedGroups: effectiveGroups,
      features: features,
      expectedFailureRules: expectedFailureRules,
      reason:
          'component-model testsuite directory does not exist: $testsuiteDir',
    );
    stdout.writeln('component-official status: skipped');
    stdout.writeln('json report: $outputJsonPath');
    stdout.writeln('markdown report: $outputMarkdownPath');
    stdout.writeln(_testsuiteSubmoduleHint);
    if (requireTestsuiteDir) {
      stderr.writeln(
        'component-official required testsuite directory is missing: '
        '$testsuiteDir',
      );
      stderr.writeln(_testsuiteSubmoduleHint);
      exitCode = 1;
    }
    return;
  }

  final regex = includePattern == null ? null : RegExp(includePattern);
  final files = <_WastFile>[];
  for (final entity in testsuite.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.wast')) {
      continue;
    }
    final relativePath = _relativePath(entity.path, from: testsuite.path);
    final group = _groupForPath(relativePath);
    if (filterByGroup && !selectedGroups.contains(group)) {
      continue;
    }
    if (regex != null && !regex.hasMatch(relativePath)) {
      continue;
    }
    files.add(
      _WastFile(path: entity.path, relativePath: relativePath, group: group),
    );
  }
  files.sort((a, b) => a.relativePath.compareTo(b.relativePath));

  if (files.isEmpty) {
    await _writeSkippedReport(
      outputJsonPath: outputJsonPath,
      outputMarkdownPath: outputMarkdownPath,
      startedAt: startedAt,
      testsuiteDir: testsuiteDir,
      selectedGroups: effectiveGroups,
      features: features,
      expectedFailureRules: expectedFailureRules,
      reason: 'No .wast files matched current group/filter selection.',
    );
    stdout.writeln('component-official status: skipped');
    stdout.writeln('json report: $outputJsonPath');
    stdout.writeln('markdown report: $outputMarkdownPath');
    return;
  }

  final resolvedWasmTools = await _resolveWasmToolsBinary(wasmToolsBin);
  if (resolvedWasmTools == null) {
    await _writeSkippedReport(
      outputJsonPath: outputJsonPath,
      outputMarkdownPath: outputMarkdownPath,
      startedAt: startedAt,
      testsuiteDir: testsuiteDir,
      selectedGroups: effectiveGroups,
      features: features,
      expectedFailureRules: expectedFailureRules,
      reason: 'Unable to locate usable wasm-tools binary.',
    );
    stdout.writeln('component-official status: skipped');
    stdout.writeln('json report: $outputJsonPath');
    stdout.writeln('markdown report: $outputMarkdownPath');
    return;
  }

  final fileResults = <_FileResult>[];
  final stopwatch = Stopwatch()..start();
  for (final file in files) {
    final started = DateTime.now();
    final command = <String>[
      'wast',
      file.path,
      '--features',
      features,
      if (ignoreErrorMessages) '--ignore-error-messages',
    ];
    final result = await Process.run(
      resolvedWasmTools,
      command,
      runInShell: false,
    );
    final ended = DateTime.now();
    final stdoutText = _asText(result.stdout);
    final stderrText = _asText(result.stderr);
    final expectedFailureRule = expectedFailureRules[file.relativePath];
    final expectedFailure = expectedFailureRule != null;
    final failureSummary = result.exitCode == 0
        ? null
        : _firstNonEmptyLine(stderrText) ?? 'unknown failure';
    final failureText = '$failureSummary\n$stderrText';
    final expectedFailureReasonMatched =
        expectedFailure &&
        result.exitCode != 0 &&
        _matchesExpectedFailureRule(
          expectedFailureRule,
          failureText: failureText,
        );
    fileResults.add(
      _FileResult(
        path: file.relativePath,
        group: file.group,
        passed: result.exitCode == 0,
        expectedFailure: expectedFailure,
        expectedFailureReasonMatched: expectedFailureReasonMatched,
        xfailed:
            expectedFailure &&
            result.exitCode != 0 &&
            expectedFailureReasonMatched,
        xpassed: expectedFailure && result.exitCode == 0,
        exitCode: result.exitCode,
        durationMs: ended.difference(started).inMilliseconds,
        failureSummary: failureSummary,
        stdoutTail: _tailLines(stdoutText, 60),
        stderrTail: _tailLines(stderrText, 60),
      ),
    );
  }
  stopwatch.stop();

  final filesPassed = fileResults.where((result) => result.passed).length;
  final xfailedFiles = fileResults.where((result) => result.xfailed).length;
  final xpassedFiles = fileResults.where((result) => result.xpassed).length;
  final filesFailed = fileResults
      .where((result) => !result.passed && !result.xfailed)
      .length;
  final status = (filesFailed == 0 && xpassedFiles == 0) ? 'passed' : 'failed';
  final failuresByGroup = <String, int>{};
  for (final result in fileResults) {
    if (result.passed || result.xfailed) {
      continue;
    }
    failuresByGroup.update(
      result.group,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  final payload = <String, Object?>{
    'suite': 'component-official',
    'status': status,
    'passed': status == 'passed',
    'started_at_utc': startedAt.toIso8601String(),
    'duration_ms': stopwatch.elapsedMilliseconds,
    'testsuite_dir': testsuiteDir,
    'groups': effectiveGroups,
    'features': features,
    'wasm_tools_binary': resolvedWasmTools,
    'ignore_error_messages': ignoreErrorMessages,
    'expected_failures': expectedFailures.toList()..sort(),
    'expected_failure_rules': expectedFailureRules.map(
      (path, rule) => MapEntry(path, rule.reasonContains),
    ),
    'totals': <String, Object?>{
      'files_total': fileResults.length,
      'files_passed': filesPassed,
      'files_failed': filesFailed,
      'files_xfailed': xfailedFiles,
      'files_xpassed': xpassedFiles,
    },
    'failures_by_group': failuresByGroup,
    'files': fileResults
        .map((result) => result.toJson())
        .toList(growable: false),
  };

  await _writeFile(
    outputJsonPath,
    '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
  );
  await _writeFile(outputMarkdownPath, _renderMarkdown(payload));

  stdout.writeln('component-official status: $status');
  stdout.writeln('json report: $outputJsonPath');
  stdout.writeln('markdown report: $outputMarkdownPath');

  if (status != 'passed') {
    exitCode = 1;
  }
}

Future<String?> _resolveWasmToolsBinary(String candidate) async {
  final attempts = <String>{candidate};
  if (candidate != 'wasm-tools') {
    attempts.add('wasm-tools');
  }
  for (final binary in attempts) {
    try {
      final result = await Process.run(binary, const <String>['--version']);
      if (result.exitCode == 0) {
        return binary;
      }
    } on ProcessException {
      // Try the next candidate.
    }
  }
  return null;
}

Future<void> _writeSkippedReport({
  required String outputJsonPath,
  required String outputMarkdownPath,
  required DateTime startedAt,
  required String testsuiteDir,
  required List<String> selectedGroups,
  required String features,
  required Map<String, _ExpectedFailureRule> expectedFailureRules,
  required String reason,
}) async {
  final expectedFailures = expectedFailureRules.keys.toList()..sort();
  final payload = <String, Object?>{
    'suite': 'component-official',
    'status': 'skipped',
    'passed': true,
    'started_at_utc': startedAt.toIso8601String(),
    'duration_ms': 0,
    'testsuite_dir': testsuiteDir,
    'groups': selectedGroups,
    'features': features,
    'expected_failures': expectedFailures,
    'expected_failure_rules': expectedFailureRules.map(
      (path, rule) => MapEntry(path, rule.reasonContains),
    ),
    'skip_reason': reason,
    'totals': const <String, Object?>{
      'files_total': 0,
      'files_passed': 0,
      'files_failed': 0,
      'files_xfailed': 0,
      'files_xpassed': 0,
    },
    'failures_by_group': const <String, int>{},
    'files': const <Object?>[],
  };
  await _writeFile(
    outputJsonPath,
    '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
  );
  await _writeFile(outputMarkdownPath, _renderMarkdown(payload));
}

bool _matchesExpectedFailureRule(
  _ExpectedFailureRule? rule, {
  required String failureText,
}) {
  if (rule == null) {
    return false;
  }
  final expectedReason = rule.reasonContains;
  if (expectedReason == null || expectedReason.isEmpty) {
    return true;
  }
  return failureText.contains(expectedReason);
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

String _relativePath(String fullPath, {required String from}) {
  final normalizedPath = fullPath.replaceAll('\\', '/');
  final normalizedRoot = from.replaceAll('\\', '/');
  if (normalizedPath == normalizedRoot) {
    return '.';
  }
  if (!normalizedPath.startsWith('$normalizedRoot/')) {
    return normalizedPath;
  }
  return normalizedPath.substring(normalizedRoot.length + 1);
}

String _groupForPath(String relativePath) {
  final normalized = relativePath.replaceAll('\\', '/');
  final firstSlash = normalized.indexOf('/');
  if (firstSlash <= 0) {
    return 'root';
  }
  return normalized.substring(0, firstSlash);
}

String _asText(Object? raw) {
  if (raw == null) {
    return '';
  }
  if (raw is String) {
    return raw;
  }
  return raw.toString();
}

String? _firstNonEmptyLine(String text) {
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
}

List<String> _tailLines(String text, int limit) {
  if (text.isEmpty) {
    return const <String>[];
  }
  final lines = const LineSplitter().convert(text);
  if (lines.length <= limit) {
    return lines;
  }
  return lines.sublist(lines.length - limit);
}

Future<void> _writeFile(String path, String content) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

String _renderMarkdown(Map<String, Object?> payload) {
  final status = payload['status'] as String? ?? 'unknown';
  final startedAt = payload['started_at_utc'] as String? ?? 'unknown';
  final durationMs = payload['duration_ms'];
  final testsuiteDir = payload['testsuite_dir'] as String? ?? '';
  final groups = (payload['groups'] as List<Object?>? ?? const <Object?>[])
      .map((value) => value.toString())
      .toList(growable: false);
  final features = payload['features'] as String? ?? 'all';
  final totals =
      (payload['totals'] as Map<Object?, Object?>? ??
      const <Object?, Object?>{});
  final filesTotal = totals['files_total'] ?? 0;
  final filesPassed = totals['files_passed'] ?? 0;
  final filesFailed = totals['files_failed'] ?? 0;
  final filesXfailed = totals['files_xfailed'] ?? 0;
  final filesXpassed = totals['files_xpassed'] ?? 0;
  final expectedFailures =
      (payload['expected_failures'] as List<Object?>? ?? const <Object?>[])
          .map((value) => value.toString())
          .toSet();
  final expectedFailureRules =
      (payload['expected_failure_rules'] as Map<Object?, Object?>? ??
              const <Object?, Object?>{})
          .map(
            (rawPath, rawReason) =>
                MapEntry(rawPath.toString(), rawReason?.toString()),
          );
  final skipReason = payload['skip_reason'] as String?;
  final files = (payload['files'] as List<Object?>? ?? const <Object?>[])
      .whereType<Map>()
      .map((entry) => entry.cast<Object?, Object?>())
      .toList(growable: false);

  final b = StringBuffer()
    ..writeln('# Component Official Testsuite Report')
    ..writeln()
    ..writeln('- Status: `${status.toUpperCase()}`')
    ..writeln('- Started (UTC): `$startedAt`')
    ..writeln('- Duration: `${durationMs ?? 'unknown'} ms`')
    ..writeln('- Testsuite dir: `$testsuiteDir`')
    ..writeln('- Groups: `${groups.isEmpty ? 'all' : groups.join(', ')}`')
    ..writeln('- Features: `$features`')
    ..writeln(
      '- Totals: `total=$filesTotal passed=$filesPassed failed=$filesFailed xfailed=$filesXfailed xpassed=$filesXpassed`',
    );
  if (expectedFailures.isNotEmpty) {
    b.writeln('- Expected failures: `${expectedFailures.toList()..sort()}`');
    final withReasons =
        expectedFailureRules.entries
            .where(
              (entry) =>
                  entry.key.trim().isNotEmpty &&
                  entry.value != null &&
                  entry.value!.trim().isNotEmpty,
            )
            .toList(growable: false)
          ..sort((a, b) => a.key.compareTo(b.key));
    if (withReasons.isNotEmpty) {
      b.writeln('- Expected failure reason matchers:');
      for (final entry in withReasons) {
        b.writeln('  - `${entry.key}` contains `${entry.value}`');
      }
    }
  }
  if (skipReason != null && skipReason.isNotEmpty) {
    b.writeln('- Skip reason: `$skipReason`');
    return b.toString();
  }

  final failedFiles = files
      .where((entry) => entry['passed'] != true && entry['xfailed'] != true)
      .toList(growable: false);
  if (failedFiles.isEmpty) {
    return b.toString();
  }

  b
    ..writeln()
    ..writeln('## Failures')
    ..writeln()
    ..writeln('| File | Group | Exit | Reason |')
    ..writeln('| --- | --- | ---: | --- |');
  for (final entry in failedFiles.take(80)) {
    final path = entry['path']?.toString() ?? 'unknown';
    final group = entry['group']?.toString() ?? 'unknown';
    final exitCode = entry['exit_code']?.toString() ?? '1';
    final reason = (entry['failure_summary']?.toString() ?? 'unknown')
        .replaceAll('|', '\\|');
    b.writeln('| `$path` | `$group` | $exitCode | $reason |');
  }
  if (failedFiles.length > 80) {
    b.writeln();
    b.writeln(
      '- ... ${failedFiles.length - 80} more failures not shown in table.',
    );
  }
  return b.toString();
}

final class _WastFile {
  const _WastFile({
    required this.path,
    required this.relativePath,
    required this.group,
  });

  final String path;
  final String relativePath;
  final String group;
}

final class _FileResult {
  const _FileResult({
    required this.path,
    required this.group,
    required this.passed,
    required this.expectedFailure,
    required this.expectedFailureReasonMatched,
    required this.xfailed,
    required this.xpassed,
    required this.exitCode,
    required this.durationMs,
    required this.failureSummary,
    required this.stdoutTail,
    required this.stderrTail,
  });

  final String path;
  final String group;
  final bool passed;
  final bool expectedFailure;
  final bool expectedFailureReasonMatched;
  final bool xfailed;
  final bool xpassed;
  final int exitCode;
  final int durationMs;
  final String? failureSummary;
  final List<String> stdoutTail;
  final List<String> stderrTail;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'group': group,
    'passed': passed,
    'expected_failure': expectedFailure,
    'expected_failure_reason_matched': expectedFailureReasonMatched,
    'xfailed': xfailed,
    'xpassed': xpassed,
    'exit_code': exitCode,
    'duration_ms': durationMs,
    'failure_summary': failureSummary,
    'stdout_tail': stdoutTail,
    'stderr_tail': stderrTail,
  };
}

final class _ExpectedFailureRule {
  const _ExpectedFailureRule({required this.path, this.reasonContains});

  final String path;
  final String? reasonContains;
}
