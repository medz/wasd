import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _contractPath = 'tool/wasi_preview1_contract.lock.json';
const _contractSha256 =
    '33c7d3e98cfc2ae57de7230331ef75a0273aaf0b5677ac248610af7a71db8951';
const _wasiCommit = 'fae981bae14809d91f9bc2d63852d461f331d161';
const _runnerCommit = '6600796756adce3632409d7e207a9834c9d99ff8';
const _fixtureCommit = 'c63d52e69316d1aa2c9e7db6251892775204e7e0';

/// Reads the independent frozen Preview1 contract.
Map<String, dynamic> readPreview1Contract({File? file}) {
  final bytes = (file ?? File(_contractPath)).readAsBytesSync();
  if (sha256.convert(bytes).toString() != _contractSha256) {
    throw StateError('Preview1 lock differs from the frozen contract.');
  }
  final contract = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  if (contract['kind'] != 'wasd-preview1-contract' ||
      contract['abi']['module'] != 'wasi_snapshot_preview1' ||
      contract['abi']['commit'] != _wasiCommit ||
      contract['testsuite']['source_commit'] != _runnerCommit ||
      contract['testsuite']['fixture_commit'] != _fixtureCommit ||
      contract['testsuite']['target'] != 'wasm32-wasip1' ||
      contract['testsuite']['fixture_count'] != 72 ||
      (contract['testsuite']['inputs'] as List).length != 137) {
    throw StateError('Invalid Preview1 contract.');
  }
  preview1ExpectedCases(contract);
  return contract;
}

/// Returns the exact case names for each official suite, rejecting duplicates.
Map<String, Set<String>> preview1ExpectedCases(Map<String, dynamic> contract) {
  final suites = contract['testsuite']['suites'];
  final expected = <String, Set<String>>{};
  if (suites is! List || suites.isEmpty) {
    throw StateError('Missing Preview1 suite inventory.');
  }
  var count = 0;
  for (final suite in suites) {
    final name = suite['name'];
    final cases = suite['cases'];
    if (name is! String ||
        name.isEmpty ||
        expected.containsKey(name) ||
        cases is! List ||
        cases.isEmpty) {
      throw StateError('Invalid or duplicate Preview1 suite: $name.');
    }
    final names = <String>{};
    for (final name in cases) {
      if (name is! String || name.isEmpty || !names.add(name)) {
        throw StateError('Invalid or duplicate Preview1 case: $name.');
      }
    }
    expected[name] = names;
    count += names.length;
  }
  if (count != contract['testsuite']['fixture_count']) {
    throw StateError('Preview1 case count differs from its frozen inventory.');
  }
  return expected;
}

File _inputFile(Directory base, Object? path) {
  if (path is! String ||
      path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.split('/').contains('..')) {
    throw StateError('Invalid relative Preview1 input path: $path.');
  }
  return File('${base.path}/$path');
}

Set<String> _verifyInputs(
  Directory directory,
  Object? inputs, {
  Map<String, int>? totals,
}) {
  if (inputs is! List || inputs.isEmpty) {
    throw StateError('Missing Preview1 input hashes.');
  }
  final counts = totals ?? <String, int>{};
  counts.addAll({
    'files_total': inputs.length,
    'files_verified': 0,
    'files_failed': 0,
  });
  final paths = <String>{};
  final failures = <String>[];
  for (final input in inputs) {
    try {
      if (input is! Map) throw StateError('Invalid Preview1 input record.');
      final path = input['path'];
      final file = _inputFile(directory, path);
      if (!paths.add(path as String)) {
        throw StateError('Duplicate Preview1 input path: $path.');
      }
      final bytes = file.readAsBytesSync();
      if (sha256.convert(bytes).toString() != input['sha256']) {
        throw StateError('SHA-256 mismatch: ${file.path}.');
      }
      final prefix = utf8.encode('blob ${bytes.length}\u0000');
      final object = Uint8List(prefix.length + bytes.length)
        ..setAll(0, prefix)
        ..setAll(prefix.length, bytes);
      if (sha1.convert(object).toString() != input['git_blob']) {
        throw StateError('Git blob mismatch: ${file.path}.');
      }
      counts['files_verified'] = counts['files_verified']! + 1;
    } catch (error) {
      counts['files_failed'] = counts['files_failed']! + 1;
      failures.add(error.toString());
    }
  }
  if (failures.isNotEmpty) throw StateError(failures.join('\n'));
  return paths;
}

/// Verifies every fixture, configuration and root file against the lock.
/// Added or removed inputs in the selected suites fail instead of shrinking
/// the official gate silently.
int verifyPreview1Fixtures(
  Map<String, dynamic> contract,
  Directory directory, {
  Map<String, int>? totals,
}) {
  preview1ExpectedCases(contract);
  final inventory = contract['testsuite'] as Map;
  final paths = _verifyInputs(directory, inventory['inputs'], totals: totals);
  final actual = <String>{};
  final expectedWasm = <String>{};
  for (final suite in inventory['suites'] as List) {
    final suitePath = suite['path'] as String;
    _inputFile(directory, suitePath);
    final root = Directory('${directory.path}/$suitePath');
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is Directory) continue;
      if (entity is! File) {
        throw StateError('Unexpected fixture link: ${entity.path}.');
      }
      actual.add(
        entity.path.substring(directory.path.length + 1).replaceAll('\\', '/'),
      );
    }
    for (final name in suite['cases'] as List) {
      expectedWasm.add('$suitePath/$name.wasm');
    }
  }
  if (actual.length != paths.length || !actual.containsAll(paths)) {
    final extra = actual.difference(paths).length;
    if (totals != null && extra > 0) {
      totals['files_total'] = totals['files_total']! + extra;
      totals['files_failed'] = totals['files_failed']! + extra;
    }
    throw StateError(
      'Preview1 fixture files differ from the frozen inventory.',
    );
  }
  final wasm = paths.where((path) => path.endsWith('.wasm')).toSet();
  if (wasm.length != expectedWasm.length || !wasm.containsAll(expectedWasm)) {
    throw StateError('Preview1 guest cases differ from the frozen inventory.');
  }
  return paths.length;
}

/// Verifies the executable Python runner sources and requirements by content.
/// This permits an isolated archive checkout without relying on a parent Git
/// repository or sharing the Preview3 checkout.
void verifyPreview1Runner(Map<String, dynamic> contract, Directory directory) {
  _verifyInputs(directory, contract['testsuite']['runner_inputs']);
}

/// Accepts only the complete official case inventory, executed with WASD.
/// Expected failures are checked independently because the upstream summary's
/// passed count includes xfail outcomes.
Map<String, Object?> validatePreview1Results(
  Map<String, dynamic> raw,
  Map<String, dynamic> contract, {
  int runnerExitCode = 0,
}) {
  final expected = preview1ExpectedCases(contract);
  final failures = <String>[];
  final seenSuites = <String>{};
  final totals = <String, int>{
    'expected': expected.values.fold(0, (n, cases) => n + cases.length),
    'total': 0,
    'executed': 0,
    'passed': 0,
    'failed': 0,
    'skipped': 0,
    'xfailed': 0,
    'xpassed': 0,
  };
  if (runnerExitCode != 0) {
    failures.add('Official runner exited $runnerExitCode.');
  }
  final results = raw['results'];
  if (results is! List || results.isEmpty) {
    failures.add('Missing or empty official Preview1 results.');
  } else {
    for (final suite in results) {
      if (suite is! Map) {
        failures.add('Official suite result must be an object.');
        continue;
      }
      final name = suite['name'];
      final validSuite =
          name is String && expected.containsKey(name) && seenSuites.add(name);
      if (!validSuite) {
        failures.add('Unexpected or duplicate official suite: $name.');
      }
      if (suite['runtime'] is! Map || suite['runtime']['name'] != 'wasd') {
        failures.add('Suite $name was not executed by WASD.');
      }
      final cases = suite['tests'];
      if (cases is! List || cases.isEmpty) {
        failures.add('Missing or empty official cases: $name.');
        continue;
      }
      final seen = <String>{};
      for (final test in cases) {
        totals['total'] = totals['total']! + 1;
        if (test is! Map) {
          failures.add('Invalid case result in $name.');
          totals['failed'] = totals['failed']! + 1;
          continue;
        }
        final caseName = test['name'];
        final validCase =
            validSuite &&
            caseName is String &&
            expected[name]!.contains(caseName) &&
            seen.add(caseName);
        if (!validCase) {
          failures.add('Unexpected or duplicate case: $name / $caseName.');
        }
        if (test['executed'] == true) {
          totals['executed'] = totals['executed']! + 1;
        } else {
          failures.add('Case was not executed: $name / $caseName.');
        }
        final outcome = test['outcome'];
        final cleanPass =
            validCase &&
            test['executed'] == true &&
            outcome == 'pass' &&
            test['failures'] is List &&
            (test['failures'] as List).isEmpty;
        final counter = cleanPass
            ? 'passed'
            : switch (outcome) {
                'skip' => 'skipped',
                'xfail' => 'xfailed',
                'xpass' => 'xpassed',
                _ => 'failed',
              };
        totals[counter] = totals[counter]! + 1;
        if (!cleanPass) {
          failures.add('Case did not pass cleanly: $name / $caseName.');
        }
      }
      if (validSuite &&
          (seen.length != expected[name]!.length ||
              !seen.containsAll(expected[name]!))) {
        failures.add('Official cases are missing from $name.');
      }
      if (suite['passed'] != cases.length ||
          [
            'failed',
            'skipped',
            'xfailed',
            'xpassed',
          ].any((key) => suite[key] != 0)) {
        failures.add(
          'Official suite summary does not show complete passes: $name.',
        );
      }
    }
  }
  if (seenSuites.length != expected.length ||
      totals['total'] != totals['expected'] ||
      totals['passed'] != totals['expected'] ||
      totals['executed'] != totals['expected']) {
    failures.add('The complete frozen Preview1 inventory was not accepted.');
  }
  return {
    'status': failures.isEmpty ? 'passed' : 'failed',
    'totals': totals,
    'failures': failures,
  };
}

/// Records the requested runner profile without treating a bad opt-in as JIT.
Map<String, Object?> preview1RunnerMetadata({String? nativeRunner}) {
  final entrypoint = File('tool/wasi_testsuite_preview1_runner.dart').absolute;
  final metadata = <String, Object?>{
    'profile': nativeRunner == null ? 'jit' : 'native-aot',
    'entrypoint': entrypoint.path,
    'entrypoint_sha256': sha256
        .convert(entrypoint.readAsBytesSync())
        .toString(),
  };
  if (nativeRunner != null) {
    final executable = File(nativeRunner).absolute;
    if (!executable.existsSync() || (executable.statSync().mode & 0x49) == 0) {
      throw StateError('WASD_PREVIEW1_RUNNER must name an executable file.');
    }
    metadata['executable'] = executable.path;
    metadata['executable_sha256'] = sha256
        .convert(executable.readAsBytesSync())
        .toString();
  }
  return metadata;
}

Future<int> _runOfficial(
  Directory fixtures,
  Directory runner,
  Map<String, dynamic> contract,
  String python,
  File output,
) async {
  if (Platform.isWindows) {
    throw UnsupportedError(
      'This native Preview1 gate targets Linux and macOS.',
    );
  }
  final arguments = [
    '--test-suite',
    for (final suite in contract['testsuite']['suites'] as List)
      Directory('${fixtures.path}/${suite['path']}').absolute.path,
    '--runtime-adapter',
    File('tool/wasi_testsuite_wasd_adapter.py').absolute.path,
    '--json-output-location',
    output.absolute.path,
    '--disable-colors',
  ];
  if (output.existsSync()) output.deleteSync();
  final process = await Process.start(
    python,
    [
      '-c',
      'import os,runpy; os.setsid(); '
          'runpy.run_module("wasi_test_runner",run_name="__main__")',
      ...arguments,
    ],
    environment: {
      'PYTHONPATH': runner.absolute.path,
      'DART': jsonEncode(Platform.resolvedExecutable),
    },
  );
  final stdoutText = process.stdout.transform(utf8.decoder).join();
  final stderrText = process.stderr.transform(utf8.decoder).join();
  try {
    final code = await process.exitCode.timeout(const Duration(minutes: 6));
    stdout.write(await stdoutText.timeout(const Duration(seconds: 2)));
    stderr.write(await stderrText.timeout(const Duration(seconds: 2)));
    return code;
  } on TimeoutException {
    Process.killPid(-process.pid, ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 2));
    throw StateError('Official Preview1 runner timed out.');
  }
}

Future<void> main(List<String> args) async {
  final options = <String, String>{
    '--testsuite-dir': '.dart_tool/wasi-preview1/fixtures',
    '--runner-dir': '.dart_tool/wasi-preview1/source/test-runner',
    '--python': 'python3',
    '--json': '.dart_tool/wasi-preview1/report.json',
  };
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'Usage: dart run tool/wasi_testsuite_preview1_gate.dart '
      '[--testsuite-dir DIR] [--runner-dir DIR] [--python PYTHON] [--json PATH]',
    );
    return;
  }
  for (var i = 0; i < args.length; i++) {
    final equal = args[i].indexOf('=');
    final key = equal < 0 ? args[i] : args[i].substring(0, equal);
    if (!options.containsKey(key) || (equal < 0 && i + 1 == args.length)) {
      stderr.writeln('Unknown or incomplete Preview1 gate option: ${args[i]}');
      exitCode = 2;
      return;
    }
    options[key] = equal < 0 ? args[++i] : args[i].substring(equal + 1);
  }
  final output = File(options['--json']!);
  await output.parent.create(recursive: true);
  final report = <String, Object?>{
    'suite': 'official-wasi-testsuite-preview1',
    'engine': 'wasd',
    'runtime': 'dart-vm',
    'execution_profile':
        Platform.environment.containsKey('WASD_PREVIEW1_RUNNER')
        ? 'native-aot'
        : 'jit',
    'status': 'failed',
    'input_verification': {
      'files_total': 137,
      'files_verified': 0,
      'files_failed': 137,
    },
    'platform': Platform.operatingSystem,
    'started_at': DateTime.now().toUtc().toIso8601String(),
  };
  try {
    final runnerMetadata = preview1RunnerMetadata(
      nativeRunner: Platform.environment['WASD_PREVIEW1_RUNNER'],
    );
    report['runner'] = runnerMetadata;
    final contract = readPreview1Contract();
    report['contract_sha256'] = sha256
        .convert(File(_contractPath).readAsBytesSync())
        .toString();
    report['abi'] = contract['abi'];
    report['testsuite'] = {
      for (final key in [
        'repository',
        'source_commit',
        'fixture_commit',
        'target',
      ])
        key: contract['testsuite'][key],
    };
    report['coverage_limits'] = contract['coverage_limits'];
    final fixtures = Directory(options['--testsuite-dir']!);
    final runner = Directory(options['--runner-dir']!);
    final inputTotals = report['input_verification'] as Map<String, int>;
    report['verified_fixture_files'] = verifyPreview1Fixtures(
      contract,
      fixtures,
      totals: inputTotals,
    );
    verifyPreview1Runner(contract, runner);
    report['verified_runner_files'] =
        (contract['testsuite']['runner_inputs'] as List).length;
    report['dart_version'] = (await Process.run(Platform.resolvedExecutable, [
      '--version',
    ])).stdout.toString().trim();
    final head = await Process.run('git', ['rev-parse', 'HEAD']);
    report['wasd_commit'] = head.stdout.toString().trim();
    final rawPath = File('${output.path}.raw-official.json');
    final code = await _runOfficial(
      fixtures,
      runner,
      contract,
      options['--python']!,
      rawPath,
    );
    if (runnerMetadata['profile'] == 'native-aot') {
      final executable = File(runnerMetadata['executable']! as String);
      final digest = sha256.convert(executable.readAsBytesSync()).toString();
      if (digest != runnerMetadata['executable_sha256']) {
        throw StateError('Preview1 runner executable changed during the gate.');
      }
    }
    report['runner_exit_code'] = code;
    report.addAll(
      validatePreview1Results(
        jsonDecode(rawPath.readAsStringSync()) as Map<String, dynamic>,
        contract,
        runnerExitCode: code,
      ),
    );
  } catch (error) {
    report['error'] = error.toString();
  }
  report['finished_at'] = DateTime.now().toUtc().toIso8601String();
  await output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln('Official Preview1 gate: ${report['status']}');
  if (report['status'] != 'passed') exitCode = 1;
}
