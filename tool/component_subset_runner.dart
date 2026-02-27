import 'dart:convert';
import 'dart:io';

const String _defaultJsonPath =
    '.dart_tool/spec_runner/component_subset_latest.json';
const String _defaultMarkdownPath =
    '.dart_tool/spec_runner/component_subset_failures.md';
const List<String> _defaultTestFiles = <String>[
  'test/component_test.dart',
  'test/component_instance_test.dart',
  'test/component_canonical_abi_test.dart',
];

Future<void> main(List<String> args) async {
  final outputJsonPath = _argValue(args, '--json') ?? _defaultJsonPath;
  final outputMarkdownPath =
      _argValue(args, '--markdown') ?? _defaultMarkdownPath;
  final filesArg = _argValue(args, '--files');
  final testFiles = filesArg == null
      ? _defaultTestFiles
      : filesArg
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false);

  if (testFiles.isEmpty) {
    stderr.writeln('No test files selected for component subset runner.');
    exitCode = 64;
    return;
  }

  final command = <String>['dart', 'test', ...testFiles];
  final startedAt = DateTime.now().toUtc();
  final stopwatch = Stopwatch()..start();
  final result = await Process.run(
    command.first,
    command.sublist(1),
    runInShell: false,
  );
  stopwatch.stop();

  final stdoutText = _asText(result.stdout);
  final stderrText = _asText(result.stderr);
  if (stdoutText.isNotEmpty) {
    stdout.write(stdoutText);
    if (!stdoutText.endsWith('\n')) {
      stdout.writeln();
    }
  }
  if (stderrText.isNotEmpty) {
    stderr.write(stderrText);
    if (!stderrText.endsWith('\n')) {
      stderr.writeln();
    }
  }

  final passed = result.exitCode == 0;
  final summary = _extractTestSummary(stdoutText);
  final payload = <String, Object?>{
    'suite': 'component-subset',
    'status': passed ? 'passed' : 'failed',
    'passed': passed,
    'exit_code': result.exitCode,
    'started_at_utc': startedAt.toIso8601String(),
    'duration_ms': stopwatch.elapsedMilliseconds,
    'command': command,
    'files': testFiles,
    'summary': summary,
    'stdout_tail': _tailLines(stdoutText, 120),
    'stderr_tail': _tailLines(stderrText, 120),
  };

  await _writeFile(
    outputJsonPath,
    '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
  );
  await _writeFile(outputMarkdownPath, _renderMarkdown(payload));

  final statusLine = passed ? 'passed' : 'failed';
  stdout.writeln('component-subset status: $statusLine');
  stdout.writeln('json report: $outputJsonPath');
  stdout.writeln('markdown report: $outputMarkdownPath');

  if (!passed) {
    exitCode = 1;
  }
}

String? _argValue(List<String> args, String key) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == key) {
      if (i + 1 >= args.length) {
        throw ArgumentError('Missing value for argument $key');
      }
      return args[i + 1];
    }
    if (arg.startsWith('$key=')) {
      return arg.substring(key.length + 1);
    }
  }
  return null;
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

String? _extractTestSummary(String stdoutText) {
  final lineMatcher = RegExp(r'^\+(\d+):\s*(.+)$', multiLine: true);
  final matches = lineMatcher.allMatches(stdoutText).toList(growable: false);
  if (matches.isNotEmpty) {
    final last = matches.last;
    return '+${last.group(1)}: ${last.group(2)}';
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
  final command = (payload['command'] as List<Object?>?)?.join(' ') ?? '';
  final files = (payload['files'] as List<Object?>? ?? const <Object?>[])
      .map((value) => value.toString())
      .toList(growable: false);
  final summary = payload['summary'] as String?;
  final stdoutTail =
      (payload['stdout_tail'] as List<Object?>? ?? const <Object?>[])
          .map((value) => value.toString())
          .join('\n');
  final stderrTail =
      (payload['stderr_tail'] as List<Object?>? ?? const <Object?>[])
          .map((value) => value.toString())
          .join('\n');

  final buffer = StringBuffer()
    ..writeln('# Component Conformance Subset')
    ..writeln()
    ..writeln('- Status: `${status.toUpperCase()}`')
    ..writeln('- Started (UTC): `$startedAt`')
    ..writeln('- Duration: `${durationMs ?? 'unknown'} ms`')
    ..writeln('- Command: `$command`')
    ..writeln('- Files:')
    ..writeln(files.map((file) => '  - `$file`').join('\n'));
  if (summary != null && summary.isNotEmpty) {
    buffer.writeln('- Summary: `$summary`');
  }
  if (status != 'passed') {
    if (stdoutTail.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## Stdout Tail')
        ..writeln('```text')
        ..writeln(stdoutTail)
        ..writeln('```');
    }
    if (stderrTail.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## Stderr Tail')
        ..writeln('```text')
        ..writeln(stderrTail)
        ..writeln('```');
    }
  }
  return buffer.toString();
}
