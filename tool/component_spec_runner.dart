// Executes the complete frozen Component strings script on WASD's Dart VM.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/preview2/component_runner.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

const _defaultManifest = 'test/fixtures/component_spec/manifest.json';
const _revision = '0220da84209397d9067c19cac83dae969aa85a7b';
const _counts = ['instantiations', 'returns', 'traps'];

/// Recognizes only the three string trap categories used by the frozen file.
/// Decode, link and lookup errors are never accepted as string traps.
bool matchesComponentStringTrap(Object error, String expected) =>
    switch (expected) {
      'string pointer/length out of bounds of memory' =>
        error is RangeError && error.name == 'pointer + length',
      'invalid utf-8' =>
        error is FormatException &&
            error.message.startsWith('Invalid UTF-8 byte'),
      'incomplete utf-8 byte sequence' =>
        error is FormatException &&
            error.message.startsWith('Unfinished UTF-8 octet sequence'),
      _ => false,
    };

/// Executes a prepared script. Unsupported commands, values and traps fail.
/// A single resource scope preserves live instances throughout the script.
Future<Map<String, Object?>> executeComponentSpecScript(
  Map<String, dynamic> script, {
  required Directory directory,
}) async {
  final records = <Map<String, Object?>>[];
  final host = WASIComponentHost();
  WASIComponentNativeRuntime? current;
  final commands = script['commands'];
  if (commands is! List || commands.isEmpty) {
    return {
      'status': 'failed',
      'error': 'Missing or empty Component commands.',
      'commands': records,
      'totals': _totals(records),
    };
  }
  await host.table.runScoped(() {
    for (var i = 0; i < commands.length; i++) {
      final raw = commands[i];
      final record = <String, Object?>{'index': i, 'passed': false};
      records.add(record);
      try {
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('Command must be an object.');
        }
        final type = raw['type'];
        record['type'] = type;
        record['line'] = raw['line'];
        switch (type) {
          case 'module':
            current = null;
            if (raw['name'] != null || raw['module_type'] == 'text') {
              throw UnsupportedError(
                'Only unnamed binary components are supported.',
              );
            }
            final file = _inputFile(directory, raw['filename']);
            final bytes = file.readAsBytesSync();
            record['binary_sha256'] = sha256.convert(bytes).toString();
            final component = WasmComponent.decode(bytes);
            final runtime = WASIComponentNativeRuntime.component(
              component: component,
              host: host,
            );
            runtime.initialize();
            current = runtime;
            break;
          case 'assert_return':
          case 'assert_trap':
            final action = raw['action'];
            if (action is! Map ||
                action['type'] != 'invoke' ||
                action['module'] != null ||
                action['field'] is! String ||
                action['args'] is! List ||
                (action['args'] as List).isNotEmpty) {
              throw UnsupportedError(
                'Expected an unnamed zero-argument invoke.',
              );
            }
            final runtime = current;
            if (runtime == null) throw StateError('No initialized component.');
            final name = action['field'] as String;
            record['export'] = name;
            if (type == 'assert_return') {
              final expected = raw['expected'];
              if (expected is! List ||
                  expected.length != 1 ||
                  expected.single is! Map ||
                  (expected.single as Map)['type'] != 'string' ||
                  (expected.single as Map)['value'] is! String) {
                throw UnsupportedError('Expected exactly one string result.');
              }
              final actual = runtime.invokeExportSynchronously(name, const []);
              final value = (expected.single as Map)['value'] as String;
              record['expected'] = value;
              record['actual'] = actual;
              if (actual is! String || actual != value) {
                throw StateError(
                  'String result differs from the expected value.',
                );
              }
            } else {
              final expected = raw['text'];
              if (expected != 'string pointer/length out of bounds of memory' &&
                  expected != 'invalid utf-8' &&
                  expected != 'incomplete utf-8 byte sequence') {
                throw UnsupportedError('Unsupported expected trap: $expected');
              }
              // Only this invocation may satisfy the expected trap. Parsing,
              // initialization and action decoding happen outside this catch.
              Object? invocationError;
              try {
                runtime.invokeExportSynchronously(name, const []);
              } catch (error) {
                invocationError = error;
              }
              if (invocationError == null) {
                throw StateError('Invocation did not trap.');
              }
              if (!matchesComponentStringTrap(
                invocationError,
                expected as String,
              )) {
                throw StateError(
                  'Unexpected invocation error: $invocationError',
                );
              }
              record['trap'] = expected;
              record['error_type'] = invocationError.runtimeType.toString();
            }
            break;
          default:
            throw UnsupportedError('Unsupported Component command: $type');
        }
        record['passed'] = true;
      } catch (error) {
        record['error'] = error.toString();
        record['error_type'] = error.runtimeType.toString();
      }
    }
  });
  return {
    'status': records.every((record) => record['passed'] == true)
        ? 'passed'
        : 'failed',
    'commands': records,
    'totals': _totals(records),
  };
}

Map<String, int> _totals(List<Map<String, Object?>> records) {
  final passed = records.where((record) => record['passed'] == true).length;
  final result = <String, int>{
    'commands_seen': records.length,
    'commands_passed': passed,
    'commands_failed': records.length - passed,
    'commands_skipped': 0,
  };
  for (final entry in {
    'instantiations': 'module',
    'returns': 'assert_return',
    'traps': 'assert_trap',
  }.entries) {
    final selected = records.where((record) => record['type'] == entry.value);
    result['${entry.key}_seen'] = selected.length;
    result['${entry.key}_passed'] = selected
        .where((record) => record['passed'] == true)
        .length;
  }
  return result;
}

File _inputFile(Directory base, Object? path) {
  if (path is! String ||
      path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.split('/').contains('..')) {
    throw FormatException('Invalid relative input path: $path');
  }
  return File('${base.path}/$path');
}

void _verifyHash(File file, Object? expected) {
  if (expected is! String ||
      sha256.convert(file.readAsBytesSync()).toString() != expected) {
    throw StateError('SHA-256 mismatch: ${file.path}');
  }
}

/// Verifies the complete source before fresh conversion and WASD execution.
/// [usePreparedInputs] is only for offline unit tests of the command executor;
/// official CLI runs always convert the checked-in WAST again.
Future<Map<String, Object?>> runComponentSpecManifest(
  File manifest, {
  String converter = '.toolchains/bin/wasm-tools',
  bool usePreparedInputs = false,
}) async {
  final reports = <Map<String, Object?>>[];
  final result = <String, Object?>{
    'kind': 'component-assertion-execution',
    'engine': 'wasd',
    'runtime': 'dart-vm',
    'status': 'failed',
    'input_mode': usePreparedInputs ? 'verified-prepared' : 'fresh-conversion',
    'files': reports,
  };
  Directory? temporary;
  try {
    final inventory = jsonDecode(manifest.readAsStringSync()) as Map;
    final files = inventory['files'];
    if (inventory['kind'] != 'wasd-component-execution-inputs' ||
        inventory['revision'] != _revision ||
        files is! List ||
        files.isEmpty) {
      throw const FormatException(
        'Invalid or empty frozen Component inventory.',
      );
    }
    final base = manifest.absolute.parent;
    if (usePreparedInputs) {
      result['converter'] = inventory['converter'];
    } else {
      final version = await Process.run(converter, ['--version']);
      if (version.exitCode != 0 ||
          !'${version.stdout}'.trim().startsWith('wasm-tools 1.262.0 ')) {
        throw StateError(
          'Expected pinned wasm-tools 1.262.0: ${version.stdout}',
        );
      }
      result['converter'] = {
        'name': 'wasm-tools',
        'version': '${version.stdout}'.trim(),
        'command': 'json-from-wast',
        'executable_sha256': sha256
            .convert(File(converter).readAsBytesSync())
            .toString(),
      };
      temporary = await Directory.systemTemp.createTemp('wasd-component-spec-');
    }
    for (var i = 0; i < files.length; i++) {
      final entry = files[i] as Map;
      final report = <String, Object?>{
        'path': entry['path'],
        'status': 'failed',
      };
      reports.add(report);
      try {
        final source = _inputFile(base, entry['source']);
        _verifyHash(source, entry['sha256']);
        final bytes = source.readAsBytesSync();
        final prefix = utf8.encode('blob ${bytes.length}\u0000');
        final object = Uint8List(prefix.length + bytes.length)
          ..setAll(0, prefix)
          ..setAll(prefix.length, bytes);
        if (sha1.convert(object).toString() != entry['blob']) {
          throw StateError('Git blob mismatch: ${source.path}');
        }
        report['source'] = {
          'repository': inventory['repository'],
          'revision': _revision,
          'path': entry['path'],
          'git_blob': entry['blob'],
          'sha256': entry['sha256'],
        };
        final File prepared;
        if (usePreparedInputs) {
          final inputs = entry['inputs'];
          if (inputs is! List || inputs.isEmpty) {
            throw const FormatException('Missing prepared input hashes.');
          }
          for (final input in inputs) {
            _verifyHash(_inputFile(base, input['path']), input['sha256']);
          }
          prepared = _inputFile(base, entry['prepared']);
          if (!inputs.any((input) => input['path'] == entry['prepared'])) {
            throw const FormatException('Prepared JSON has no verified hash.');
          }
          final script = jsonDecode(prepared.readAsStringSync()) as Map;
          for (final command in script['commands'] as List) {
            if (command['type'] != 'module') continue;
            final binary = _inputFile(prepared.parent, command['filename']);
            if (!inputs.any(
              (input) =>
                  _inputFile(base, input['path']).absolute.path ==
                  binary.absolute.path,
            )) {
              throw FormatException(
                'Binary has no verified hash: ${binary.path}',
              );
            }
          }
        } else {
          final directory = Directory('${temporary!.path}/$i')..createSync();
          prepared = File('${directory.path}/script.json');
          final conversion = await Process.run(File(converter).absolute.path, [
            'json-from-wast',
            source.path,
            '-o',
            prepared.path,
          ], workingDirectory: directory.path);
          if (conversion.exitCode != 0 || !prepared.existsSync()) {
            throw StateError('WAST conversion failed: ${conversion.stderr}');
          }
        }
        final script =
            jsonDecode(prepared.readAsStringSync()) as Map<String, dynamic>;
        report['prepared_json_sha256'] = sha256
            .convert(prepared.readAsBytesSync())
            .toString();
        report.addAll(
          await executeComponentSpecScript(script, directory: prepared.parent),
        );
        final totals = report['totals'] as Map;
        if (totals['commands_seen'] != entry['commands'] ||
            _counts.any((kind) => totals['${kind}_seen'] != entry[kind])) {
          report['status'] = 'failed';
          report['error'] =
              'Converted command counts differ from the frozen inventory.';
        }
      } catch (error) {
        report['status'] = 'failed';
        report['error'] = error.toString();
      }
    }
    result['status'] = reports.every((report) => report['status'] == 'passed')
        ? 'passed'
        : 'failed';
  } catch (error) {
    result['error'] = error.toString();
  } finally {
    if (temporary != null) await temporary.delete(recursive: true);
  }
  final totals = <String, int>{
    'files_total': reports.length,
    'files_passed': reports
        .where((report) => report['status'] == 'passed')
        .length,
    'files_failed': reports
        .where((report) => report['status'] != 'passed')
        .length,
    ..._totals(const []),
  };
  for (final report in reports) {
    final counts = report['totals'];
    if (counts is! Map) continue;
    for (final key in _totals(const []).keys) {
      totals[key] = totals[key]! + (counts[key] as int);
    }
  }
  result['totals'] = totals;
  return result;
}

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'Usage: dart run tool/component_spec_runner.dart '
      '[--manifest=path] [--json-from-wast=path] [--output-json=path]',
    );
    return;
  }
  const options = ['--manifest=', '--json-from-wast=', '--output-json='];
  if (args.any((arg) => !options.any(arg.startsWith))) {
    stderr.writeln('Unknown Component runner argument.');
    exitCode = 1;
    return;
  }
  String option(String key, String fallback) => args
      .firstWhere(
        (arg) => arg.startsWith('$key='),
        orElse: () => '$key=$fallback',
      )
      .substring(key.length + 1);
  final report = await runComponentSpecManifest(
    File(option('--manifest', _defaultManifest)),
    converter: option('--json-from-wast', '.toolchains/bin/wasm-tools'),
  );
  final file = File(
    option('--output-json', '.dart_tool/component_spec/strings.json'),
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  final totals = report['totals'] as Map;
  stdout.writeln(
    'Component strings: ${report['status']}; '
    '${totals['commands_passed']}/${totals['commands_seen']} commands; '
    '${totals['commands_skipped']} skipped.',
  );
  if (report['status'] != 'passed') exitCode = 1;
}
