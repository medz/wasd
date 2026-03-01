// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/src/component.dart';
import '../lib/src/features.dart';

const String _defaultTestsuiteDir = 'third_party/component-model-tests/test';
const String _defaultJsonPath =
    '.dart_tool/spec_runner/component_decode_probe_latest.json';
const String _defaultMarkdownPath =
    '.dart_tool/spec_runner/component_decode_probe_failures.md';
const String _testsuiteSubmoduleHint =
    'Initialize testsuite submodule: '
    'git submodule update --init --recursive third_party/component-model-tests';
const Map<String, String> _defaultExpectedFailureReasonPatterns =
    <String, String>{
      // Parser token coverage gap in current wasm-tools release.
      'async/trap-if-block-and-sync.wast': 'unexpected token, expected one of:',
    };

Future<void> main(List<String> args) async {
  final testsuiteDir =
      _argValue(args, '--testsuite-dir') ?? _defaultTestsuiteDir;
  final outputJsonPath = _argValue(args, '--json') ?? _defaultJsonPath;
  final outputMarkdownPath =
      _argValue(args, '--markdown') ?? _defaultMarkdownPath;
  final wasmToolsBin =
      _argValue(args, '--wasm-tools-bin') ?? '.toolchains/bin/wasm-tools';
  final includePattern = _argValue(args, '--include-pattern');
  final groupsArg = _argValue(args, '--groups');
  final strict = args.contains('--strict');
  final bestEffort = args.contains('--best-effort');
  final requireTestsuiteDir = args.contains('--require-testsuite-dir');
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
  final allGroups = args.contains('--all-groups');
  final selectedGroups = allGroups
      ? const <String>[]
      : (groupsArg == null
            ? const <String>[]
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
    await _writeReport(
      outputJsonPath: outputJsonPath,
      outputMarkdownPath: outputMarkdownPath,
      payload: <String, Object?>{
        'suite': 'component-decode-probe',
        'status': 'skipped',
        'started_at_utc': startedAt.toIso8601String(),
        'duration_ms': 0,
        'testsuite_dir': testsuiteDir,
        'groups': effectiveGroups,
        'expected_failures': expectedFailures.toList()..sort(),
        'expected_failure_rules': expectedFailureRules.map(
          (path, rule) => MapEntry(path, rule.reasonContains),
        ),
        'skip_reason':
            'component-model testsuite directory does not exist: $testsuiteDir',
      },
    );
    stdout.writeln('component-decode-probe status: skipped');
    stdout.writeln('json report: $outputJsonPath');
    stdout.writeln('markdown report: $outputMarkdownPath');
    stdout.writeln(_testsuiteSubmoduleHint);
    if (requireTestsuiteDir) {
      stderr.writeln(
        'component-decode-probe required testsuite directory is missing: '
        '$testsuiteDir',
      );
      stderr.writeln(_testsuiteSubmoduleHint);
      exitCode = 1;
    }
    return;
  }

  final resolvedWasmTools = await _resolveWasmToolsBinary(wasmToolsBin);
  if (resolvedWasmTools == null) {
    await _writeReport(
      outputJsonPath: outputJsonPath,
      outputMarkdownPath: outputMarkdownPath,
      payload: <String, Object?>{
        'suite': 'component-decode-probe',
        'status': 'skipped',
        'started_at_utc': startedAt.toIso8601String(),
        'duration_ms': 0,
        'testsuite_dir': testsuiteDir,
        'groups': effectiveGroups,
        'expected_failures': expectedFailures.toList()..sort(),
        'expected_failure_rules': expectedFailureRules.map(
          (path, rule) => MapEntry(path, rule.reasonContains),
        ),
        'skip_reason': 'Unable to locate usable wasm-tools binary.',
      },
    );
    stdout.writeln('component-decode-probe status: skipped');
    stdout.writeln('json report: $outputJsonPath');
    stdout.writeln('markdown report: $outputMarkdownPath');
    return;
  }

  final regex = includePattern == null ? null : RegExp(includePattern);
  final wastFiles = <_WastFile>[];
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
    wastFiles.add(
      _WastFile(path: entity.path, relativePath: relativePath, group: group),
    );
  }
  wastFiles.sort((a, b) => a.relativePath.compareTo(b.relativePath));

  final failureReasonCounts = <String, int>{};
  final xfailReasonCounts = <String, int>{};
  final fileResults = <_ProbeFileResult>[];
  var convertedWastFiles = 0;
  var convertFailedWastFiles = 0;
  var xfailedWastFiles = 0;
  var xpassedWastFiles = 0;
  var failedWastFiles = 0;
  var componentFilesSeen = 0;
  var componentFilesDecoded = 0;
  var componentFilesFailed = 0;
  var componentFilesFailedNonXfail = 0;
  final stopwatch = Stopwatch()..start();

  for (final wastFile in wastFiles) {
    final expectedFailureRule = expectedFailureRules[wastFile.relativePath];
    final expectedFailure = expectedFailureRule != null;
    final work = await Directory.systemTemp.createTemp('wasd-component-probe-');
    try {
      final scriptJsonPath = '${work.path}/script.json';
      final converterResult = await Process.run(resolvedWasmTools, <String>[
        'json-from-wast',
        wastFile.path,
        '-o',
        scriptJsonPath,
        '--wasm-dir',
        work.path,
      ], runInShell: false);
      if (converterResult.exitCode != 0) {
        convertFailedWastFiles++;
        final reason =
            _firstNonEmptyLine(_asText(converterResult.stderr)) ??
            'wast conversion failed';
        final expectedFailureReasonMatched =
            expectedFailure &&
            _matchesExpectedFailureRule(
              expectedFailureRule,
              failureText: reason,
            );
        if (expectedFailureReasonMatched) {
          xfailedWastFiles++;
          xfailReasonCounts.update(
            reason,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        } else {
          failedWastFiles++;
          failureReasonCounts.update(
            reason,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }
        fileResults.add(
          _ProbeFileResult(
            path: wastFile.relativePath,
            group: wastFile.group,
            converted: false,
            expectedFailure: expectedFailure,
            expectedFailureReasonMatched: expectedFailureReasonMatched,
            failed: true,
            xfailed: expectedFailureReasonMatched,
            xpassed: false,
            componentFilesSeen: 0,
            componentFilesDecoded: 0,
            componentFilesFailed: 0,
            failureReasons: <String>[reason],
          ),
        );
        continue;
      }

      convertedWastFiles++;
      final scriptFile = File(scriptJsonPath);
      if (!scriptFile.existsSync()) {
        const reason = 'json-from-wast produced no script.json output';
        final expectedFailureReasonMatched =
            expectedFailure &&
            _matchesExpectedFailureRule(
              expectedFailureRule,
              failureText: reason,
            );
        if (expectedFailureReasonMatched) {
          xfailedWastFiles++;
          xfailReasonCounts.update(
            reason,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        } else {
          failedWastFiles++;
          failureReasonCounts.update(
            reason,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }
        fileResults.add(
          _ProbeFileResult(
            path: wastFile.relativePath,
            group: wastFile.group,
            converted: false,
            expectedFailure: expectedFailure,
            expectedFailureReasonMatched: expectedFailureReasonMatched,
            failed: true,
            xfailed: expectedFailureReasonMatched,
            xpassed: false,
            componentFilesSeen: 0,
            componentFilesDecoded: 0,
            componentFilesFailed: 0,
            failureReasons: const <String>[reason],
          ),
        );
        convertFailedWastFiles++;
        continue;
      }

      final componentFilenames = _collectComponentBinaryFilenames(
        workDirPath: work.path,
        scriptJsonPayload: jsonDecode(scriptFile.readAsStringSync()),
      );
      var decodedCount = 0;
      final fileFailureReasonCounts = <String, int>{};
      final fileFailureReasons = <String>{};
      for (final filename in componentFilenames) {
        componentFilesSeen++;
        final bytes = File('${work.path}/$filename').readAsBytesSync();
        try {
          if (bestEffort) {
            WasmComponent.decodeBestEffort(
              Uint8List.fromList(bytes),
              features: const WasmFeatureSet(componentModel: true),
            );
          } else {
            WasmComponent.decode(
              Uint8List.fromList(bytes),
              features: const WasmFeatureSet(componentModel: true),
            );
          }
          componentFilesDecoded++;
          decodedCount++;
        } catch (error) {
          componentFilesFailed++;
          final reason = _reasonKey(error);
          fileFailureReasons.add(reason);
          fileFailureReasonCounts.update(
            reason,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }
      }
      final fileFailed = decodedCount != componentFilenames.length;
      final expectedFailureReasonMatched =
          expectedFailure &&
          fileFailed &&
          _matchesExpectedFailureRule(
            expectedFailureRule,
            failureText: fileFailureReasons.join('\n'),
          );
      final xfailed =
          expectedFailure && fileFailed && expectedFailureReasonMatched;
      final xpassed = expectedFailure && !fileFailed;
      if (xfailed) {
        xfailedWastFiles++;
        for (final entry in fileFailureReasonCounts.entries) {
          xfailReasonCounts.update(
            entry.key,
            (count) => count + entry.value,
            ifAbsent: () => entry.value,
          );
        }
      } else if (xpassed) {
        xpassedWastFiles++;
      } else if (fileFailed) {
        failedWastFiles++;
        componentFilesFailedNonXfail +=
            componentFilenames.length - decodedCount;
        for (final entry in fileFailureReasonCounts.entries) {
          failureReasonCounts.update(
            entry.key,
            (count) => count + entry.value,
            ifAbsent: () => entry.value,
          );
        }
      }
      fileResults.add(
        _ProbeFileResult(
          path: wastFile.relativePath,
          group: wastFile.group,
          converted: true,
          expectedFailure: expectedFailure,
          expectedFailureReasonMatched: expectedFailureReasonMatched,
          failed: fileFailed,
          xfailed: xfailed,
          xpassed: xpassed,
          componentFilesSeen: componentFilenames.length,
          componentFilesDecoded: decodedCount,
          componentFilesFailed: componentFilenames.length - decodedCount,
          failureReasons: fileFailureReasons.toList()..sort(),
        ),
      );
    } finally {
      await work.delete(recursive: true);
    }
  }
  stopwatch.stop();

  final status =
      failedWastFiles == 0 &&
          componentFilesFailedNonXfail == 0 &&
          xpassedWastFiles == 0
      ? 'passed'
      : 'failed';
  final payload = <String, Object?>{
    'suite': 'component-decode-probe',
    'status': status,
    'started_at_utc': startedAt.toIso8601String(),
    'duration_ms': stopwatch.elapsedMilliseconds,
    'testsuite_dir': testsuiteDir,
    'groups': effectiveGroups,
    'wasm_tools_binary': resolvedWasmTools,
    'strict': strict,
    'best_effort': bestEffort,
    'expected_failures': expectedFailures.toList()..sort(),
    'expected_failure_rules': expectedFailureRules.map(
      (path, rule) => MapEntry(path, rule.reasonContains),
    ),
    'totals': <String, Object?>{
      'wast_total': wastFiles.length,
      'wast_converted': convertedWastFiles,
      'wast_convert_failed': convertFailedWastFiles,
      'wast_xfailed': xfailedWastFiles,
      'wast_xpassed': xpassedWastFiles,
      'wast_failed': failedWastFiles,
      'component_files_seen': componentFilesSeen,
      'component_files_decoded': componentFilesDecoded,
      'component_files_failed': componentFilesFailed,
      'component_files_failed_non_xfail': componentFilesFailedNonXfail,
    },
    'failure_reason_counts': failureReasonCounts,
    'xfail_reason_counts': xfailReasonCounts,
    'files': fileResults
        .map((result) => result.toJson())
        .toList(growable: false),
  };
  await _writeReport(
    outputJsonPath: outputJsonPath,
    outputMarkdownPath: outputMarkdownPath,
    payload: payload,
  );

  stdout.writeln('component-decode-probe status: $status');
  stdout.writeln('json report: $outputJsonPath');
  stdout.writeln('markdown report: $outputMarkdownPath');
  if (strict && status != 'passed') {
    exitCode = 1;
  }
}

Set<String> _collectComponentBinaryFilenames({
  required String workDirPath,
  required Object? scriptJsonPayload,
}) {
  if (scriptJsonPayload is! Map) {
    return const <String>{};
  }
  final commands = scriptJsonPayload['commands'];
  if (commands is! List) {
    return const <String>{};
  }
  final out = <String>{};
  for (final rawCommand in commands) {
    if (rawCommand is! Map) {
      continue;
    }
    final command = rawCommand.cast<Object?, Object?>();
    final names = <String>{};
    final filename = command['filename'];
    if (filename is String && filename.isNotEmpty) {
      names.add(filename);
    }
    final binaryFilename = command['binary_filename'];
    if (binaryFilename is String && binaryFilename.isNotEmpty) {
      names.add(binaryFilename);
    }
    for (final candidate in names) {
      final file = File('$workDirPath/$candidate');
      if (!file.existsSync()) {
        continue;
      }
      final bytes = file.readAsBytesSync();
      if (_isComponentBinary(bytes)) {
        out.add(candidate);
      }
    }
  }
  return out;
}

bool _isComponentBinary(List<int> bytes) {
  return bytes.length >= 8 &&
      bytes[0] == 0x00 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x73 &&
      bytes[3] == 0x6d &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x00 &&
      bytes[6] == 0x01 &&
      bytes[7] == 0x00;
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

String _reasonKey(Object error) {
  final text = error.toString().replaceAll('\n', ' ').trim();
  if (text.length <= 240) {
    return text;
  }
  return '${text.substring(0, 240)}...';
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

Future<void> _writeReport({
  required String outputJsonPath,
  required String outputMarkdownPath,
  required Map<String, Object?> payload,
}) async {
  await _writeFile(
    outputJsonPath,
    '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
  );
  await _writeFile(outputMarkdownPath, _renderMarkdown(payload));
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
  final bestEffort = payload['best_effort'] == true;
  final expectedFailures =
      (payload['expected_failures'] as List<Object?>? ?? const <Object?>[])
          .map((value) => value.toString())
          .toList(growable: false);
  final expectedFailureRules =
      (payload['expected_failure_rules'] as Map<Object?, Object?>? ??
              const <Object?, Object?>{})
          .map(
            (rawPath, rawReason) =>
                MapEntry(rawPath.toString(), rawReason?.toString()),
          );
  final totals = payload['totals'] as Map<Object?, Object?>?;
  final skipReason = payload['skip_reason'] as String?;
  final failureReasonCounts =
      (payload['failure_reason_counts'] as Map<Object?, Object?>? ??
              const <Object?, Object?>{})
          .entries
          .map((entry) => (entry.key.toString(), (entry.value as num).toInt()))
          .toList(growable: false)
        ..sort((a, b) => b.$2.compareTo(a.$2));
  final xfailReasonCounts =
      (payload['xfail_reason_counts'] as Map<Object?, Object?>? ??
              const <Object?, Object?>{})
          .entries
          .map((entry) => (entry.key.toString(), (entry.value as num).toInt()))
          .toList(growable: false)
        ..sort((a, b) => b.$2.compareTo(a.$2));

  final b = StringBuffer()
    ..writeln('# Component Decode Probe')
    ..writeln()
    ..writeln('- Status: `${status.toUpperCase()}`')
    ..writeln('- Started (UTC): `$startedAt`')
    ..writeln('- Duration: `${durationMs ?? 'unknown'} ms`')
    ..writeln('- Testsuite dir: `$testsuiteDir`')
    ..writeln('- Groups: `${groups.isEmpty ? 'all' : groups.join(', ')}`')
    ..writeln('- Decode mode: `${bestEffort ? 'best-effort' : 'strict'}`')
    ..writeln('- Expected failures: `${expectedFailures.length}`');
  if (expectedFailureRules.isNotEmpty) {
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
  if (totals != null) {
    b
      ..writeln()
      ..writeln('## Totals')
      ..writeln()
      ..writeln('- WAST total: `${totals['wast_total'] ?? 0}`')
      ..writeln('- WAST converted: `${totals['wast_converted'] ?? 0}`')
      ..writeln(
        '- WAST convert failed: `${totals['wast_convert_failed'] ?? 0}`',
      )
      ..writeln('- WAST xfailed: `${totals['wast_xfailed'] ?? 0}`')
      ..writeln('- WAST xpassed: `${totals['wast_xpassed'] ?? 0}`')
      ..writeln('- WAST failed: `${totals['wast_failed'] ?? 0}`')
      ..writeln(
        '- Component files seen: `${totals['component_files_seen'] ?? 0}`',
      )
      ..writeln(
        '- Component files decoded: `${totals['component_files_decoded'] ?? 0}`',
      )
      ..writeln(
        '- Component files failed: `${totals['component_files_failed'] ?? 0}`',
      )
      ..writeln(
        '- Component files failed (non-xfail): `${totals['component_files_failed_non_xfail'] ?? 0}`',
      );
  }

  if (failureReasonCounts.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Failure Reasons')
      ..writeln()
      ..writeln('| Count | Reason |')
      ..writeln('| ---: | --- |');
    for (final (reason, count) in failureReasonCounts.take(40)) {
      b.writeln('| $count | ${reason.replaceAll('|', '\\|')} |');
    }
  }
  if (xfailReasonCounts.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## XFail Reasons')
      ..writeln()
      ..writeln('| Count | Reason |')
      ..writeln('| ---: | --- |');
    for (final (reason, count) in xfailReasonCounts.take(40)) {
      b.writeln('| $count | ${reason.replaceAll('|', '\\|')} |');
    }
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

final class _ProbeFileResult {
  const _ProbeFileResult({
    required this.path,
    required this.group,
    required this.converted,
    required this.expectedFailure,
    required this.expectedFailureReasonMatched,
    required this.failed,
    required this.xfailed,
    required this.xpassed,
    required this.componentFilesSeen,
    required this.componentFilesDecoded,
    required this.componentFilesFailed,
    required this.failureReasons,
  });

  final String path;
  final String group;
  final bool converted;
  final bool expectedFailure;
  final bool expectedFailureReasonMatched;
  final bool failed;
  final bool xfailed;
  final bool xpassed;
  final int componentFilesSeen;
  final int componentFilesDecoded;
  final int componentFilesFailed;
  final List<String> failureReasons;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'group': group,
    'converted': converted,
    'expected_failure': expectedFailure,
    'expected_failure_reason_matched': expectedFailureReasonMatched,
    'failed': failed,
    'xfailed': xfailed,
    'xpassed': xpassed,
    'component_files_seen': componentFilesSeen,
    'component_files_decoded': componentFilesDecoded,
    'component_files_failed': componentFilesFailed,
    'failure_reasons': failureReasons,
  };
}

final class _ExpectedFailureRule {
  const _ExpectedFailureRule({required this.path, this.reasonContains});

  final String path;
  final String? reasonContains;
}
