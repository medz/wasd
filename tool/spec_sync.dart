import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final testsuiteDir =
      _readArg(args, '--testsuite-dir') ?? '$root/third_party/wasm-spec-tests';
  final outputPath =
      _readArg(args, '--output') ?? '$root/doc/wasm_spec_updates.md';

  final dir = Directory(testsuiteDir);
  final now = DateTime.now().toUtc().toIso8601String();

  String localHead = 'not-found';
  String remoteHead = 'unknown';
  String diffSummary = 'testsuite directory not available';

  if (await dir.exists()) {
    localHead =
        await _git(['-C', testsuiteDir, 'rev-parse', 'HEAD']) ?? 'unknown';
    final remoteLine = await _git([
      '-C',
      testsuiteDir,
      'ls-remote',
      'origin',
      'HEAD',
    ]);
    remoteHead =
        remoteLine
            ?.split(RegExp(r'\s+'))
            .firstWhere((v) => v.isNotEmpty, orElse: () => 'unknown') ??
        'unknown';
    if (localHead == remoteHead) {
      diffSummary = 'up-to-date';
    } else {
      diffSummary = 'updates detected';
    }
  }

  final report = StringBuffer()
    ..writeln('# WASM Spec Update Report')
    ..writeln()
    ..writeln('- Generated at (UTC): $now')
    ..writeln('- Testsuite dir: `$testsuiteDir`')
    ..writeln('- Local HEAD: `$localHead`')
    ..writeln('- Remote HEAD: `$remoteHead`')
    ..writeln('- Status: $diffSummary')
    ..writeln()
    ..writeln('## Next Actions')
    ..writeln()
    ..writeln('1. If updates detected, pull latest testsuite revision.')
    ..writeln(
      '2. Run `dart run tool/spec_runner.dart --target=vm --suite=all` and record deltas.',
    )
    ..writeln(
      '3. Classify failures by proposal area and open implementation tasks.',
    );

  final output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsString(report.toString());

  final jsonOutput = jsonEncode({
    'generated_at_utc': now,
    'testsuite_dir': testsuiteDir,
    'local_head': localHead,
    'remote_head': remoteHead,
    'status': diffSummary,
    'output': outputPath,
  });
  stdout.writeln(jsonOutput);
}

String? _readArg(List<String> args, String key) {
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

Future<String?> _git(List<String> args) async {
  final result = await Process.run('git', args);
  if (result.exitCode != 0) {
    return null;
  }
  return (result.stdout as String).trim();
}
