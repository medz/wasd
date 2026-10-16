// Runs the frozen Core source inventory through WASD on the Dart VM.
// Original source paths avoid the testsuite mirror's basename collisions.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _inventoryPath = 'tool/core_spec_inventory.json';
const _revision = '957c932e7158c5a6891be68ca424aaa0aa505f97';

/// Checks each original source path and Git blob before any Wasm execution.
Map<String, File> verifyCoreSpecInputs(Map<String, dynamic> inventory) {
  final entries = (inventory['files'] as List).cast<Map<String, dynamic>>();
  final inputs = <String, File>{};
  for (final entry in entries) {
    final path = entry['path'] as String;
    if (inputs.containsKey(path)) {
      throw FormatException('Duplicate official path: $path');
    }
    if ((!path.startsWith('test/core/') && !path.startsWith('test/custom/')) ||
        !path.endsWith('.wast') ||
        path.split('/').contains('..')) {
      throw FormatException('Invalid official path: $path');
    }
    inputs[path] = File(entry['source'] as String).absolute;
  }
  for (final entry in entries) {
    final path = entry['path'] as String;
    final bytes = inputs[path]!.readAsBytesSync();
    final prefix = utf8.encode('blob ${bytes.length}\u0000');
    final object = Uint8List(prefix.length + bytes.length)
      ..setAll(0, prefix)
      ..setAll(prefix.length, bytes);
    if (sha1.convert(object).toString() != entry['blob']) {
      throw StateError('Git blob mismatch: $path (${entry['source']})');
    }
  }
  return inputs;
}

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'Usage: dart run tool/core_spec_runner.dart [--check-only] '
      '[--file=test/core/path.wast] [--output-json=path] [--output-md=path] '
      '[--json-from-wast=path] [--wast2json=path] '
      '[--no-conversion-cache]',
    );
    return;
  }
  const forwardedOptions = ['--json-from-wast=', '--wast2json='];
  try {
    for (final arg in args) {
      if (arg != '--check-only' &&
          arg != '--no-conversion-cache' &&
          ![
            '--file=',
            '--output-json=',
            '--output-md=',
            ...forwardedOptions,
          ].any(arg.startsWith)) {
        throw ArgumentError('Unknown argument: $arg');
      }
    }
    final inventory =
        jsonDecode(File(_inventoryPath).readAsStringSync())
            as Map<String, dynamic>;
    if (inventory['revision'] != _revision ||
        (inventory['files'] as List).length != 261) {
      throw StateError('Expected 261 official WAST inputs at $_revision.');
    }
    final revision = await Process.run('git', [
      '-C',
      'third_party/wasm-spec-tests',
      'rev-parse',
      'HEAD',
    ]);
    if (revision.exitCode != 0 ||
        '${revision.stdout}'.trim() != inventory['testsuite_revision']) {
      throw StateError(
        'Expected testsuite revision ${inventory['testsuite_revision']}.',
      );
    }
    final inputs = verifyCoreSpecInputs(inventory);
    final requested = args
        .where((arg) => arg.startsWith('--file='))
        .map((arg) => arg.substring('--file='.length))
        .toSet();
    for (final path in requested) {
      if (!inputs.containsKey(path)) {
        throw ArgumentError('Unknown official source path: $path');
      }
    }
    final selected = requested.isEmpty
        ? inputs.keys.toList()
        : requested.toList();
    selected.sort();
    stdout.writeln(
      'Core inventory verified: ${inputs.length} files at $_revision; '
      '${selected.length} selected.',
    );
    if (args.contains('--check-only')) return;

    String option(String key, String fallback) => args
        .firstWhere(
          (arg) => arg.startsWith('$key='),
          orElse: () => '$key=$fallback',
        )
        .substring(key.length + 1);
    final jsonPath = option(
      '--output-json',
      '.dart_tool/spec_runner/core_spec_latest.json',
    );
    final markdownPath = option(
      '--output-md',
      '.dart_tool/spec_runner/core_spec_latest.md',
    );
    final temp = await Directory.systemTemp.createTemp('wasd-core-spec-');
    try {
      for (final path in selected) {
        final staged = File('${temp.path}/$path');
        await staged.parent.create(recursive: true);
        await inputs[path]!.copy(staged.path);
      }
      final runner = await Process.run(Platform.resolvedExecutable, [
        'tool/spec_testsuite_runner.dart',
        '--suite=core',
        '--testsuite-dir=${temp.path}',
        '--output-json=${temp.path}/result.json',
        '--output-md=${temp.path}/result.md',
        // Cache keys include temporary source paths and cannot be reused.
        '--no-conversion-cache',
        ...args.where((arg) => forwardedOptions.any(arg.startsWith)),
      ]);
      final runnerExitCode = runner.exitCode;
      final rawReport = File('${temp.path}/result.json');
      if (!await rawReport.exists()) {
        throw StateError('VM runner exited $runnerExitCode without a report.');
      }
      final payload = jsonDecode(await rawReport.readAsString()) as Map;
      final totals = payload['totals'] as Map;
      final files = (payload['files'] as List).cast<Map>();
      for (final file in files) {
        final reason = file['commands_seen'] == 0
            ? 'no-wast-commands'
            : file['commands_skipped'] != 0
            ? 'commands-skipped'
            : null;
        if (reason == null || file['passed'] != true) continue;
        file['passed'] = false;
        totals['files_passed'] = (totals['files_passed'] as int) - 1;
        totals['files_failed'] = (totals['files_failed'] as int) + 1;
        final group = (payload['group_stats'] as Map)[file['group']] as Map;
        group['passed'] = (group['passed'] as int) - 1;
        group['failed'] = (group['failed'] as int) + 1;
        file['first_failure_reason'] = reason;
        final reasons = payload['reason_counts'] as Map;
        reasons[reason] = ((reasons[reason] as int?) ?? 0) + 1;
      }
      final passed =
          runnerExitCode == 0 &&
          totals['files_total'] == selected.length &&
          totals['files_failed'] == 0 &&
          totals['commands_failed'] == 0 &&
          totals['commands_skipped'] == 0;
      payload['status'] = passed ? 'passed' : 'failed';
      payload['core_specification'] = {
        'repository': inventory['repository'],
        'revision': _revision,
        'inventory': _inventoryPath,
        'testsuite_revision': inventory['testsuite_revision'],
        'files_verified': inputs.length,
        'files_selected': selected.length,
        'scope': selected.length == inputs.length ? 'full' : 'subset',
        'requires_zero_skips': true,
      };
      for (final file in files) {
        file['path'] = (file['path'] as String).substring(temp.path.length + 1);
      }
      final report = File(jsonPath);
      await report.parent.create(recursive: true);
      await report.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
      );
      final markdown = File(markdownPath);
      await markdown.parent.create(recursive: true);
      final summary = StringBuffer('# Frozen Core 3.0 Report\n\n')
        ..writeln('- Status: `${passed ? 'passed' : 'failed'}`')
        ..writeln('- Specification: `$_revision`')
        ..writeln('- Files verified: ${inputs.length}')
        ..writeln('- Files selected: ${selected.length}')
        ..writeln('- Passed files: ${totals['files_passed']}')
        ..writeln('- Failed files: ${totals['files_failed']}')
        ..writeln('- Commands seen: ${totals['commands_seen']}')
        ..writeln('- Commands passed: ${totals['commands_passed']}')
        ..writeln('- Commands failed: ${totals['commands_failed']}')
        ..writeln('- Commands skipped: ${totals['commands_skipped']}')
        ..writeln()
        ..writeln('| Source | Passed | Commands | Skipped | Failure |')
        ..writeln('| --- | --- | ---: | ---: | --- |');
      for (final file in files) {
        summary.writeln(
          '| `${file['path']}` | ${file['passed']} | '
          '${file['commands_seen']} | ${file['commands_skipped']} | '
          '${file['first_failure_reason'] ?? ''} |',
        );
      }
      await markdown.writeAsString(
        '$summary\nStrict zero-skip result: ${passed ? 'passed' : 'failed'}.\n',
      );
      if (runnerExitCode != 0) stderr.write(runner.stderr);
      stdout.writeln('Frozen Core status: ${passed ? 'passed' : 'failed'}');
      stdout.writeln('Frozen Core report: ${report.path}');
      stdout.writeln('Frozen Core markdown: ${markdown.path}');
      if (!passed) exitCode = 1;
    } finally {
      await temp.delete(recursive: true);
    }
  } catch (error) {
    stderr.writeln(error);
    exitCode = 2;
  }
}
