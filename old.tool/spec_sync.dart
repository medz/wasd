import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final coreTestsuiteDir =
      _readArg(args, '--testsuite-dir') ?? '$root/third_party/wasm-spec-tests';
  final componentTestsuiteDir =
      _readArg(args, '--component-testsuite-dir') ??
      '$root/third_party/component-model-tests';
  final outputPath =
      _readArg(args, '--output') ??
      '$root/.dart_tool/spec_runner/wasm_spec_updates.md';

  final now = DateTime.now().toUtc().toIso8601String();
  final coreSummary = await _summarizeGitMirror(coreTestsuiteDir);
  final componentSummary = await _summarizeGitMirror(componentTestsuiteDir);
  final overallStatus =
      coreSummary.status == 'up-to-date' &&
          componentSummary.status == 'up-to-date'
      ? 'up-to-date'
      : 'updates detected';

  final report = StringBuffer()
    ..writeln('# WASM Spec Update Report')
    ..writeln()
    ..writeln('- Generated at (UTC): $now')
    ..writeln('- Overall status: $overallStatus')
    ..writeln()
    ..writeln('## Core Testsuite')
    ..writeln()
    ..writeln('- Dir: `${coreSummary.path}`')
    ..writeln('- Local HEAD: `${coreSummary.localHead}`')
    ..writeln('- Remote HEAD: `${coreSummary.remoteHead}`')
    ..writeln('- Status: ${coreSummary.status}')
    ..writeln()
    ..writeln('## Component Testsuite')
    ..writeln()
    ..writeln('- Dir: `${componentSummary.path}`')
    ..writeln('- Local HEAD: `${componentSummary.localHead}`')
    ..writeln('- Remote HEAD: `${componentSummary.remoteHead}`')
    ..writeln('- Status: ${componentSummary.status}')
    ..writeln()
    ..writeln('## Next Actions')
    ..writeln()
    ..writeln(
      '1. If updates detected, pull latest revisions for both testsuite mirrors.',
    )
    ..writeln(
      '2. Run `dart run tool/spec_runner.dart --target=vm --suite=all` and record deltas.',
    )
    ..writeln(
      '3. Classify deltas by core/proposal/component areas and open implementation tasks.',
    );

  final output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsString(report.toString());

  final jsonOutput = jsonEncode({
    'generated_at_utc': now,
    'status': overallStatus,
    'core_testsuite': coreSummary.toJson(),
    'component_testsuite': componentSummary.toJson(),
    'output': outputPath,
  });
  stdout.writeln(jsonOutput);
}

Future<_GitMirrorSummary> _summarizeGitMirror(String path) async {
  final dir = Directory(path);
  if (!await dir.exists()) {
    return _GitMirrorSummary(
      path: path,
      localHead: 'not-found',
      remoteHead: 'unknown',
      status: 'testsuite directory not available',
    );
  }

  final localHead = await _git(['-C', path, 'rev-parse', 'HEAD']) ?? 'unknown';
  final remoteLine = await _git(['-C', path, 'ls-remote', 'origin', 'HEAD']);
  final remoteHead =
      remoteLine
          ?.split(RegExp(r'\s+'))
          .firstWhere((value) => value.isNotEmpty, orElse: () => 'unknown') ??
      'unknown';
  final status = localHead == remoteHead ? 'up-to-date' : 'updates detected';
  return _GitMirrorSummary(
    path: path,
    localHead: localHead,
    remoteHead: remoteHead,
    status: status,
  );
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

final class _GitMirrorSummary {
  const _GitMirrorSummary({
    required this.path,
    required this.localHead,
    required this.remoteHead,
    required this.status,
  });

  final String path;
  final String localHead;
  final String remoteHead;
  final String status;

  Map<String, String> toJson() => <String, String>{
    'path': path,
    'local_head': localHead,
    'remote_head': remoteHead,
    'status': status,
  };
}
