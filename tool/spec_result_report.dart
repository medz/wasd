import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final inputJson =
      _argValue(args, '--input-json') ??
      '.dart_tool/spec_runner/proposal_latest.json';
  final outputMarkdown =
      _argValue(args, '--output-md') ?? 'doc/wasm_proposal_failures.md';

  final inputFile = File(inputJson);
  if (!inputFile.existsSync()) {
    stderr.writeln('input json does not exist: ${inputFile.path}');
    exitCode = 2;
    return;
  }

  final decoded = json.decode(await inputFile.readAsString());
  if (decoded is! Map) {
    stderr.writeln('input json root is not object: ${inputFile.path}');
    exitCode = 2;
    return;
  }
  final payload = decoded.cast<String, Object?>();
  final filesRaw = payload['files'];
  if (filesRaw is! List) {
    stderr.writeln('input json missing files list: ${inputFile.path}');
    exitCode = 2;
    return;
  }

  final results = <_FileResult>[];
  for (final raw in filesRaw) {
    if (raw is! Map) {
      continue;
    }
    final file = raw.cast<String, Object?>();
    results.add(
      _FileResult(
        path: (file['path'] as String?) ?? '',
        group: (file['group'] as String?) ?? 'unknown',
        passed: (file['passed'] as bool?) ?? false,
        firstFailureLine: file['first_failure_line'] as int?,
        firstFailureReason: file['first_failure_reason'] as String?,
        firstFailureDetails: file['first_failure_details'] as String?,
      ),
    );
  }

  final groupStats = <String, Map<String, int>>{};
  final groupStatsRaw = payload['group_stats'];
  if (groupStatsRaw is Map) {
    for (final entry in groupStatsRaw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! Map) {
        continue;
      }
      groupStats[key] = <String, int>{
        'total': (value['total'] as int?) ?? 0,
        'passed': (value['passed'] as int?) ?? 0,
        'failed': (value['failed'] as int?) ?? 0,
      };
    }
  }
  if (groupStats.isEmpty) {
    for (final result in results) {
      final stats = groupStats.putIfAbsent(
        result.group,
        () => <String, int>{'total': 0, 'passed': 0, 'failed': 0},
      );
      stats['total'] = (stats['total'] ?? 0) + 1;
      if (result.passed) {
        stats['passed'] = (stats['passed'] ?? 0) + 1;
      } else {
        stats['failed'] = (stats['failed'] ?? 0) + 1;
      }
    }
  }

  final markdown = _renderMarkdown(
    payload: payload,
    results: results,
    groupStats: groupStats,
  );
  final outputFile = File(outputMarkdown);
  await outputFile.parent.create(recursive: true);
  await outputFile.writeAsString(markdown);
  stdout.writeln('markdown report: ${outputFile.path}');
}

final class _FileResult {
  const _FileResult({
    required this.path,
    required this.group,
    required this.passed,
    this.firstFailureLine,
    this.firstFailureReason,
    this.firstFailureDetails,
  });

  final String path;
  final String group;
  final bool passed;
  final int? firstFailureLine;
  final String? firstFailureReason;
  final String? firstFailureDetails;
}

String _renderMarkdown({
  required Map<String, Object?> payload,
  required List<_FileResult> results,
  required Map<String, Map<String, int>> groupStats,
}) {
  final totals = (payload['totals'] as Map?)?.cast<String, Object?>() ??
      <String, Object?>{};
  final reasonCounts =
      (payload['reason_counts'] as Map?)?.cast<String, Object?>() ??
      <String, Object?>{};

  final b = StringBuffer()
    ..writeln('# WASM Proposal Failure Board')
    ..writeln()
    ..writeln('- Started at (UTC): `${payload['started_at_utc']}`')
    ..writeln('- Ended at (UTC): `${payload['ended_at_utc']}`')
    ..writeln('- Suite: `${payload['suite']}`')
    ..writeln('- Testsuite dir: `${payload['testsuite_dir']}`')
    ..writeln(
      '- Testsuite revision: `${payload['testsuite_revision'] ?? 'unknown'}`',
    )
    ..writeln(
      '- Wast converter: `${payload['wast_converter']}` (`${payload['wast_converter_binary']}`)',
    )
    ..writeln()
    ..writeln('## Totals')
    ..writeln()
    ..writeln('- Files: ${totals['files_total']}')
    ..writeln('- Passed files: ${totals['files_passed']}')
    ..writeln('- Failed files: ${totals['files_failed']}')
    ..writeln('- Commands seen: ${totals['commands_seen']}')
    ..writeln('- Commands passed: ${totals['commands_passed']}')
    ..writeln('- Commands failed: ${totals['commands_failed']}')
    ..writeln('- Commands skipped: ${totals['commands_skipped']}')
    ..writeln()
    ..writeln('## Groups')
    ..writeln()
    ..writeln('| Group | Files | Passed | Failed |')
    ..writeln('| --- | ---: | ---: | ---: |');

  final sortedGroups = groupStats.keys.toList()..sort();
  for (final group in sortedGroups) {
    final stats = groupStats[group]!;
    b.writeln(
      '| $group | ${stats['total'] ?? 0} | ${stats['passed'] ?? 0} | ${stats['failed'] ?? 0} |',
    );
  }

  if (reasonCounts.isNotEmpty) {
    b.writeln();
    b.writeln('## Top Failure Reasons');
    b.writeln();
    b.writeln('| Reason | Count |');
    b.writeln('| --- | ---: |');
    final sorted = reasonCounts.entries.toList()
      ..sort((a, b) => (b.value as int).compareTo(a.value as int));
    for (final entry in sorted) {
      b.writeln('| ${entry.key} | ${entry.value} |');
    }
  }

  final failed = results.where((r) => !r.passed).toList(growable: false);
  if (failed.isNotEmpty) {
    b.writeln();
    b.writeln('## Failed Files');
    b.writeln();
    b.writeln('| Group | File | Line | Reason | Details |');
    b.writeln('| --- | --- | ---: | --- | --- |');
    for (final file in failed) {
      final details = _markdownEscape(_shorten(file.firstFailureDetails ?? ''));
      b.writeln(
        '| ${file.group} | `${_markdownEscape(file.path)}` | ${file.firstFailureLine ?? 0} | ${file.firstFailureReason ?? 'unknown'} | $details |',
      );
    }
  }

  return b.toString();
}

String _markdownEscape(String input) {
  return input.replaceAll('|', '\\|').replaceAll('\n', '<br>');
}

String _shorten(String input, {int max = 240}) {
  if (input.length <= max) {
    return input;
  }
  return '${input.substring(0, max - 3)}...';
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
