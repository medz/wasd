import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String _defaultJsonPath =
    '.dart_tool/spec_runner/component_official_latest.json';
const String _defaultMarkdownPath =
    '.dart_tool/spec_runner/component_official_failures.md';
const String _defaultTestsuiteDir = 'third_party/component-model-tests/test';
const String _defaultPortableFeatures =
    'component-model,cm-values,cm-async,cm-more-async-builtins,'
    'cm-async-stackful,cm-threading,cm-error-context,cm-map,cm-gc,'
    'cm-fixed-length-lists';
const String _testsuiteSubmoduleHint =
    'Initialize testsuite submodule: '
    'git submodule update --init --recursive third_party/component-model-tests';
const String _defaultWasmToolsBin = '.toolchains/bin/wasm-tools';
const Duration _defaultFileTimeout = Duration(minutes: 2);
const Duration _processTerminationGrace = Duration(seconds: 2);
const List<String> _defaultPortableGroups = <String>[
  'async',
  'names',
  'resources',
  'values',
  'wasm-tools',
];
const Map<String, String>
_allFeaturesAdditionalExpectedFailureReasonPatterns = <String, String>{
  // Known wasm-tools/parser drift for package-name parsing assertions.
  'wasm-tools/import.wast': 'should have failed with: expected `/` after',
  // Known wasm-tools validation drift for canonical ABI rejection tests.
  'wasm-tools/memory64.wast':
      'should have failed with: canonical ABI memory is not a 32-bit linear memory',
  'wasm-tools/resources.wast':
      'should have failed with: resources can only be represented by `i32`',
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
  final allGroups = args.contains('--all-groups');
  final groupsArg = _argValue(args, '--groups');
  final features =
      _argValue(args, '--features') ??
      (allGroups ? 'all' : _defaultPortableFeatures);
  final explicitWasmToolsBin = _argValue(args, '--wasm-tools-bin');
  final wasmtimeBin = _argValue(args, '--wasmtime-bin');
  late final Duration fileTimeout;
  try {
    if (_hasOption(args, '--wasm-tools-bin') &&
        _hasOption(args, '--wasmtime-bin')) {
      throw ArgumentError(
        'Use only one of `--wasm-tools-bin` or `--wasmtime-bin`.',
      );
    }
    if (allGroups && _hasOption(args, '--groups')) {
      throw ArgumentError('Use only one of `--all-groups` or `--groups`.');
    }
    fileTimeout = _parsePositiveSeconds(
      _argValue(args, '--file-timeout-seconds'),
      '--file-timeout-seconds',
      _defaultFileTimeout,
    );
  } on Object catch (error) {
    stderr
      ..writeln('component-official: $error')
      ..writeln(_usage);
    exitCode = 2;
    return;
  }
  final engine = wasmtimeBin == null
      ? _GateEngine.wasmToolsValidation
      : _GateEngine.wasmtimeReference;
  if (engine == _GateEngine.wasmtimeReference) {
    for (final feature in _unknownWasmtimeFeatureTokens(features)) {
      stderr.writeln(
        'component-official: warning: ignoring unknown Wasmtime feature '
        '`$feature`.',
      );
    }
  }
  final allowPathFallback = explicitWasmToolsBin == null && wasmtimeBin == null;
  final requestedEngineBinary =
      wasmtimeBin ?? explicitWasmToolsBin ?? _defaultWasmToolsBin;
  final includePattern = _argValue(args, '--include-pattern');
  final requireTestsuiteDir = args.contains('--require-testsuite-dir');
  final requireEngine = args.contains('--require-engine');
  final ignoreErrorMessages =
      engine == _GateEngine.wasmToolsValidation &&
      !args.contains('--no-ignore-error-messages');
  final disableDefaultExpectedFailures = args.contains(
    '--no-default-expected-failures',
  );
  final expectedFailuresArg = _argValue(args, '--expected-failures');
  final expectedFailureRules = <String, _ExpectedFailureRule>{
    if (!disableDefaultExpectedFailures &&
        engine == _GateEngine.wasmToolsValidation &&
        _featuresIncludeAll(features))
      ..._allFeaturesAdditionalExpectedFailureReasonPatterns.map(
        (path, reasonContains) => MapEntry(
          path,
          _ExpectedFailureRule(path: path, reasonContains: reasonContains),
        ),
      ),
    if (!disableDefaultExpectedFailures &&
        engine == _GateEngine.wasmToolsValidation &&
        allGroups)
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
      engine: engine,
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
      engine: engine,
      reason: 'No .wast files matched current group/filter selection.',
    );
    stdout.writeln('component-official status: skipped');
    stdout.writeln('json report: $outputJsonPath');
    stdout.writeln('markdown report: $outputMarkdownPath');
    return;
  }

  final resolvedEngine = await _resolveEngineBinary(
    engine: engine,
    candidate: requestedEngineBinary,
    allowPathFallback: allowPathFallback,
  );
  if (resolvedEngine == null) {
    await _writeSkippedReport(
      outputJsonPath: outputJsonPath,
      outputMarkdownPath: outputMarkdownPath,
      startedAt: startedAt,
      testsuiteDir: testsuiteDir,
      selectedGroups: effectiveGroups,
      features: features,
      expectedFailureRules: expectedFailureRules,
      engine: engine,
      reason: 'Unable to locate usable ${engine.displayName} binary.',
    );
    stdout.writeln('component-official status: skipped');
    stdout.writeln('json report: $outputJsonPath');
    stdout.writeln('markdown report: $outputMarkdownPath');
    if (requireEngine) {
      stderr.writeln(
        'component-official required ${engine.displayName} binary is missing.',
      );
      exitCode = 1;
    }
    return;
  }

  final fileResults = <_FileResult>[];
  final stopwatch = Stopwatch()..start();
  for (final file in files) {
    final started = DateTime.now();
    final command = _engineCommand(
      engine: engine,
      filePath: file.path,
      features: features,
      ignoreErrorMessages: ignoreErrorMessages,
    );
    late final _EngineProcessResult result;
    try {
      result = await _runEngineProcess(
        resolvedEngine.binary,
        command,
        timeout: fileTimeout,
      );
    } on Object catch (error) {
      result = _EngineProcessResult.failedToStart(error);
    }
    final ended = DateTime.now();
    final stdoutText = result.stdout;
    final stderrText = result.stderr;
    final expectedFailureRule = expectedFailureRules[file.relativePath];
    final expectedFailure = expectedFailureRule != null;
    final failureSummary = result.exitCode == 0
        ? null
        : result.timedOut
        ? 'timed out after ${fileTimeout.inSeconds} seconds'
        : _firstNonEmptyLine(stderrText) ?? 'unknown failure';
    final failureText = '$failureSummary\n$stderrText';
    final expectedFailureReasonMatched =
        expectedFailure &&
        !result.timedOut &&
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
        timedOut: result.timedOut,
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
    'engine': engine.id,
    'engine_mode': engine.mode,
    'engine_binary': resolvedEngine.binary,
    'engine_version': resolvedEngine.version,
    'executes_wasm': engine.executesWasm,
    'executes_wasd': false,
    if (engine == _GateEngine.wasmToolsValidation)
      'wasm_tools_binary': resolvedEngine.binary,
    if (engine == _GateEngine.wasmtimeReference)
      'wasmtime_binary': resolvedEngine.binary,
    'ignore_error_messages': ignoreErrorMessages,
    'file_timeout_seconds': fileTimeout.inSeconds,
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

Future<_EngineProcessResult> _runEngineProcess(
  String binary,
  List<String> arguments, {
  required Duration timeout,
}) async {
  final process = await Process.start(binary, arguments, runInShell: false);
  final stdoutCollector = _ProcessOutputCollector(process.stdout);
  final stderrCollector = _ProcessOutputCollector(process.stderr);
  var timedOut = false;
  var processExitCode = 0;
  try {
    processExitCode = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    await _terminateProcess(process);
    processExitCode = 124;
  }
  final outputs = await Future.wait<String>(<Future<String>>[
    stdoutCollector.read(),
    stderrCollector.read(),
  ]);
  return _EngineProcessResult(
    exitCode: processExitCode,
    stdout: outputs[0],
    stderr: outputs[1],
    timedOut: timedOut,
  );
}

Future<void> _terminateProcess(Process process) async {
  process.kill();
  try {
    await process.exitCode.timeout(_processTerminationGrace);
    return;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
  }
  try {
    await process.exitCode.timeout(_processTerminationGrace);
  } on TimeoutException {
    // Output draining is bounded below even if the engine ignores both signals.
  }
}

Future<_ResolvedEngine?> _resolveEngineBinary({
  required _GateEngine engine,
  required String candidate,
  required bool allowPathFallback,
}) async {
  final fallback = engine == _GateEngine.wasmToolsValidation
      ? 'wasm-tools'
      : 'wasmtime';
  final attempts = <String>{candidate};
  if (allowPathFallback && candidate != fallback) {
    attempts.add(fallback);
  }
  for (final binary in attempts) {
    try {
      final result = await Process.run(binary, const <String>['--version']);
      if (result.exitCode == 0) {
        return _ResolvedEngine(
          binary: binary,
          version:
              _firstNonEmptyLine(_asText(result.stdout)) ??
              _firstNonEmptyLine(_asText(result.stderr)) ??
              'unknown',
        );
      }
    } on ProcessException {
      // Try the next candidate.
    }
  }
  return null;
}

List<String> _engineCommand({
  required _GateEngine engine,
  required String filePath,
  required String features,
  required bool ignoreErrorMessages,
}) {
  switch (engine) {
    case _GateEngine.wasmToolsValidation:
      return <String>[
        'wast',
        filePath,
        '--features',
        features,
        if (ignoreErrorMessages) '--ignore-error-messages',
      ];
    case _GateEngine.wasmtimeReference:
      return <String>['wast', ..._wasmtimeFeatureArgs(features), filePath];
  }
}

List<String> _wasmtimeFeatureArgs(String features) {
  final tokens = features
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet();
  final all = tokens.contains('all');
  final flags = <String>{'-Wcomponent-model=y'};

  void enable(String feature, String flag) {
    if (all || tokens.contains(feature)) {
      flags.add('-W$flag=y');
    }
  }

  enable('cm-async', 'component-model-async');
  enable('cm-more-async-builtins', 'component-model-more-async-builtins');
  enable('cm-async-stackful', 'component-model-async-stackful');
  enable('cm-threading', 'component-model-threading');
  enable('cm-error-context', 'component-model-error-context');
  enable('cm-gc', 'component-model-gc');
  enable('cm-map', 'component-model-map');
  enable('cm-fixed-length-lists', 'component-model-fixed-length-lists');
  if (all) {
    flags
      ..add('-Wcomponent-model-memory64=y')
      ..add('-Wcomponent-model-implements=y');
  }
  return flags.toList(growable: false);
}

Iterable<String> _unknownWasmtimeFeatureTokens(String features) sync* {
  const known = <String>{
    'all',
    'component-model',
    'cm-values',
    'cm-async',
    'cm-more-async-builtins',
    'cm-async-stackful',
    'cm-threading',
    'cm-error-context',
    'cm-gc',
    'cm-map',
    'cm-fixed-length-lists',
  };
  final seen = <String>{};
  for (final rawToken in features.split(',')) {
    final token = rawToken.trim();
    if (token.isNotEmpty && !known.contains(token) && seen.add(token)) {
      yield token;
    }
  }
}

Future<void> _writeSkippedReport({
  required String outputJsonPath,
  required String outputMarkdownPath,
  required DateTime startedAt,
  required String testsuiteDir,
  required List<String> selectedGroups,
  required String features,
  required Map<String, _ExpectedFailureRule> expectedFailureRules,
  required _GateEngine engine,
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
    'engine': engine.id,
    'engine_mode': engine.mode,
    'executes_wasm': engine.executesWasm,
    'executes_wasd': false,
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

bool _featuresIncludeAll(String features) {
  for (final token in features.split(',')) {
    if (token.trim() == 'all') {
      return true;
    }
  }
  return false;
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

bool _hasOption(List<String> args, String key) {
  return args.any(
    (argument) => argument == key || argument.startsWith('$key='),
  );
}

Duration _parsePositiveSeconds(
  String? value,
  String option,
  Duration fallback,
) {
  if (value == null) {
    return fallback;
  }
  final seconds = int.tryParse(value);
  if (seconds == null || seconds <= 0) {
    throw ArgumentError.value(value, option, 'must be a positive integer');
  }
  return Duration(seconds: seconds);
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
  final engine = payload['engine'] as String? ?? 'unknown';
  final engineMode = payload['engine_mode'] as String? ?? 'unknown';
  final engineBinary = payload['engine_binary'] as String?;
  final engineVersion = payload['engine_version'] as String?;
  final executesWasm = payload['executes_wasm'] == true;
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
    ..writeln('- Engine: `$engine` (`$engineMode`)')
    ..writeln(
      '- Executes WebAssembly: `${executesWasm ? 'yes' : 'no'}`; executes wasd: `no`',
    )
    ..writeln(
      engineBinary == null
          ? '- Engine binary: `unresolved`'
          : '- Engine binary: `$engineBinary`',
    )
    ..writeln(
      engineVersion == null
          ? '- Engine version: `unresolved`'
          : '- Engine version: `$engineVersion`',
    )
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

enum _GateEngine {
  wasmToolsValidation(
    id: 'wasm-tools',
    mode: 'validation-only',
    displayName: 'wasm-tools',
    executesWasm: false,
  ),
  wasmtimeReference(
    id: 'wasmtime',
    mode: 'reference-execution',
    displayName: 'Wasmtime',
    executesWasm: true,
  );

  const _GateEngine({
    required this.id,
    required this.mode,
    required this.displayName,
    required this.executesWasm,
  });

  final String id;
  final String mode;
  final String displayName;
  final bool executesWasm;
}

final class _ResolvedEngine {
  const _ResolvedEngine({required this.binary, required this.version});

  final String binary;
  final String version;
}

final class _EngineProcessResult {
  const _EngineProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.timedOut,
  });

  factory _EngineProcessResult.failedToStart(Object error) =>
      _EngineProcessResult(
        exitCode: 127,
        stdout: '',
        stderr: 'Unable to start official component engine: $error',
        timedOut: false,
      );

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
}

final class _ProcessOutputCollector {
  _ProcessOutputCollector(Stream<List<int>> stream) {
    _subscription = stream.listen(
      _bytes.add,
      onError: (Object _, StackTrace _) => _complete(),
      onDone: _complete,
      cancelOnError: true,
    );
  }

  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;

  Future<String> read() async {
    try {
      await _done.future.timeout(_processTerminationGrace);
    } on TimeoutException {
      try {
        await _subscription.cancel().timeout(_processTerminationGrace);
      } on Object {
        // Return the bounded output captured before the pipe stalled.
      }
      _complete();
    }
    return utf8.decode(_bytes.takeBytes(), allowMalformed: true);
  }

  void _complete() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
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
    required this.timedOut,
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
  final bool timedOut;
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
    'timed_out': timedOut,
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

const String _usage = '''
Usage: dart run tool/component_official_runner.dart [options]

  --testsuite-dir DIR
  --groups LIST | --all-groups
  --features LIST
  --wasm-tools-bin FILE | --wasmtime-bin FILE
  --file-timeout-seconds N
  --json FILE
  --markdown FILE
''';
