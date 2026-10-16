// Executes selected complete frozen Component value scripts on WASD's Dart VM.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/unicode_scalar.dart';
import 'package:wasd/src/wasi/preview2/component_runner.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/execution_error.dart';

const _defaultManifest = 'test/fixtures/component_spec/manifest.json';
const _revision = '0220da84209397d9067c19cac83dae969aa85a7b';
const _counts = ['instantiations', 'definitions', 'returns', 'traps'];
const _repository = 'https://github.com/WebAssembly/component-model';
// Independent source anchor: changing a manifest and its input cannot silently
// replace the complete upstream file while retaining the frozen revision.
const _frozenSources = {
  'test/values/strings.wast': {
    'path': 'test/values/strings.wast',
    'blob': 'e96f54e97689a32ba70b05e12226e01b8dea024b',
    'sha256':
        'a70c90a0ede0e2364040da75f4c2c0e56c2d34fdac746a11b6347fdbac60283c',
    'commands': 17,
    'instantiations': 8,
    'definitions': 0,
    'returns': 5,
    'traps': 4,
  },
  'test/values/numerics.wast': {
    'path': 'test/values/numerics.wast',
    'blob': '99fcbc03b0b352b29db247c90085ad0febbd3fe5',
    'sha256':
        '990040c362068e2c9d461439fc323af95878bcea283b43a10d67639015faf7b9',
    'commands': 26,
    'instantiations': 9,
    'definitions': 1,
    'returns': 13,
    'traps': 3,
  },
};

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

/// Matches only invalid core character scalars, preserving typed VM causes.
/// Unknown wrappers, ordinary host errors and cause cycles never match.
bool matchesComponentCharTrap(Object error) {
  final seen = Set<Object>.identity();
  while (error is WasmExecutionErrorContext) {
    if (!seen.add(error)) return false;
    error = error.cause;
  }
  return error is WASIComponentInvalidCharException;
}

void _checkFields(Map object, Set<String> allowed) {
  if (object.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('Unsupported Component JSON field.');
  }
}

WasmComponentFunctionTypeContext _exportType(
  WasmComponent component,
  String name,
) {
  for (final export in component.exports) {
    if (export.name != name ||
        export.sort.kind != WasmComponentSortKind.function) {
      continue;
    }
    final types = component.componentFunctionIndexTypeContexts;
    final index = export.sort.index;
    if (index >= 0 && index < types.length && types[index] != null) {
      return types[index]!;
    }
    throw UnsupportedError('Unavailable Component export signature: $name');
  }
  throw StateError('Component function export `$name` not found.');
}

String _valueTypeName(
  WasmComponentValueType type,
  WasmComponentFunctionTypeContext context,
) {
  if (type.kind == WasmComponentValueTypeKind.primitive) {
    return switch (type.primitive) {
      WasmComponentPrimitiveValueType.boolean => 'bool',
      WasmComponentPrimitiveValueType.u8 => 'u8',
      WasmComponentPrimitiveValueType.s8 => 's8',
      WasmComponentPrimitiveValueType.u16 => 'u16',
      WasmComponentPrimitiveValueType.s16 => 's16',
      WasmComponentPrimitiveValueType.u32 => 'u32',
      WasmComponentPrimitiveValueType.char => 'char',
      WasmComponentPrimitiveValueType.string => 'string',
      _ => throw UnsupportedError('Unsupported Component scalar type.'),
    };
  }
  final index = type.typeIndex;
  final definition =
      context.typeScope?.definitionAt(index) ??
      (index != null && index >= 0 && index < context.typeDefinitions.length
          ? context.typeDefinitions[index]
          : null);
  if (definition?.definedValue?.kind ==
      WasmComponentDefinedValueTypeKind.flags) {
    return 'flags';
  }
  throw UnsupportedError('Unsupported Component value type.');
}

Object _decodeValue(
  Object? raw,
  WasmComponentValueType type,
  WasmComponentFunctionTypeContext context,
) {
  if (raw is! Map) throw const FormatException('Expected a Component value.');
  _checkFields(raw, const {'type', 'value'});
  final name = _valueTypeName(type, context);
  if (raw['type'] != name) {
    throw const FormatException(
      'Component value type does not match export signature.',
    );
  }
  final value = raw['value'];
  switch (name) {
    case 'string':
      if (value is String) return value;
      throw const FormatException('Invalid string value.');
    case 'char':
      if (singleWASIComponentUnicodeScalar(value) != null) {
        return value as String;
      }
      throw const FormatException('Invalid char value.');
    case 'bool':
      if (value is bool) return value;
      throw const FormatException('Invalid bool value.');
    case 'flags':
      if (value is! List ||
          value.any((label) => label is! String) ||
          value.toSet().length != value.length) {
        throw const FormatException('Invalid flags value.');
      }
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.flags,
        rawBytes: Uint8List(0),
        labels: value.cast<String>(),
      );
    default:
      final (minimum, maximum) = switch (name) {
        'u8' => (0, 255),
        's8' => (-128, 127),
        'u16' => (0, 65535),
        's16' => (-32768, 32767),
        'u32' => (0, 4294967295),
        _ => throw UnsupportedError('Unsupported Component scalar type: $name'),
      };
      final integer =
          value is String && RegExp(r'^(0|-?[1-9][0-9]*)$').hasMatch(value)
          ? int.tryParse(value)
          : null;
      if (integer == null || integer < minimum || integer > maximum) {
        throw FormatException('Invalid $name value.');
      }
      return integer;
  }
}

bool _sameValue(Object expected, Object? actual) {
  if (expected is WasmComponentValueData) {
    if (actual is! WasmComponentValueData ||
        actual.kind != WasmComponentValueDataKind.flags ||
        actual.labels.length != expected.labels.length ||
        actual.labels.toSet().length != actual.labels.length) {
      return false;
    }
    final labels = actual.labels.toSet();
    return expected.labels.every(labels.contains);
  }
  return switch (expected) {
    int() => actual is int && actual == expected,
    bool() => actual is bool && actual == expected,
    String() => actual is String && actual == expected,
    _ => false,
  };
}

Object? _reportValue(Object? value) =>
    value is WasmComponentValueData ? value.labels : value;

/// Executes a prepared script. Unsupported commands, values and traps fail.
/// A single resource scope preserves live instances throughout the script.
Future<Map<String, Object?>> executeComponentSpecScript(
  Map<String, dynamic> script, {
  required Directory directory,
}) async {
  final records = <Map<String, Object?>>[];
  final host = WASIComponentHost();
  final definitions = <String, WasmComponent>{};
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
  await host.table.runScoped(() async {
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
          case 'module_definition':
            if (type == 'module') current = null;
            _checkFields(raw, const {
              'type',
              'line',
              'name',
              'filename',
              'module_type',
            });
            final encoding = raw['module_type'];
            if (encoding != null && encoding != 'binary' ||
                type == 'module' && raw['name'] != null) {
              throw UnsupportedError(
                'Only unnamed binary components are supported.',
              );
            }
            final name = raw['name'];
            if (type == 'module_definition' &&
                (name is! String || name.isEmpty)) {
              throw const FormatException(
                'Component definition requires a name.',
              );
            }
            final file = _inputFile(directory, raw['filename']);
            final bytes = file.readAsBytesSync();
            record['binary_sha256'] = sha256.convert(bytes).toString();
            final component = WasmComponent.decode(bytes);
            if (type == 'module_definition') {
              final errors = component.validate();
              if (errors.isNotEmpty) {
                throw FormatException(
                  'Component definition validation failed: ${errors.join(', ')}',
                );
              }
              definitions[name as String] = component;
              record['definition'] = name;
            } else {
              final runtime = WASIComponentNativeRuntime.component(
                component: component,
                host: host,
              );
              await runtime.initialize();
              current = runtime;
            }
            break;
          case 'module_instance':
            current = null;
            _checkFields(raw, const {'type', 'line', 'instance', 'module'});
            final name = raw['module'];
            final instance = raw['instance'];
            if (name is! String ||
                name.isEmpty ||
                instance is! String ||
                instance.isEmpty) {
              throw const FormatException(
                'Component instance requires definition and instance names.',
              );
            }
            final component = definitions[name];
            if (component == null) {
              throw StateError('Unknown component definition `$name`.');
            }
            final runtime = WASIComponentNativeRuntime.component(
              component: component,
              host: host,
            );
            await runtime.initialize();
            current = runtime;
            record['definition'] = name;
            record['instance'] = instance;
            break;
          case 'assert_return':
          case 'assert_trap':
            _checkFields(
              raw,
              type == 'assert_return'
                  ? const {'type', 'line', 'action', 'expected'}
                  : const {'type', 'line', 'action', 'text'},
            );
            final action = raw['action'];
            if (action is! Map ||
                action['type'] != 'invoke' ||
                action['module'] != null ||
                action['field'] is! String ||
                action['args'] is! List) {
              throw UnsupportedError('Expected an unnamed Component invoke.');
            }
            _checkFields(action, const {'type', 'module', 'field', 'args'});
            final runtime = current;
            if (runtime == null) throw StateError('No initialized component.');
            final name = action['field'] as String;
            final context = _exportType(runtime.component, name);
            final params = context.functionType.params;
            final rawArgs = action['args'] as List;
            if (rawArgs.length != params.length) {
              throw const FormatException(
                'Component invocation argument count mismatch.',
              );
            }
            final args = <Object?>[
              for (var j = 0; j < params.length; j++)
                _decodeValue(rawArgs[j], params[j].type, context),
            ];
            record['export'] = name;
            if (type == 'assert_return') {
              final expected = raw['expected'];
              final resultType = context.functionType.result;
              if (expected is! List ||
                  expected.length != 1 ||
                  resultType == null) {
                throw UnsupportedError(
                  'Expected exactly one Component result.',
                );
              }
              final value = _decodeValue(expected.single, resultType, context);
              final actual = await runtime.invokeExport(name, args);
              record['expected'] = _reportValue(value);
              record['actual'] = _reportValue(actual);
              if (!_sameValue(value, actual)) {
                throw StateError(
                  'Component result differs from the expected value.',
                );
              }
            } else {
              final expected = raw['text'];
              if (expected != 'string pointer/length out of bounds of memory' &&
                  expected != 'invalid utf-8' &&
                  expected != 'incomplete utf-8 byte sequence' &&
                  expected != 'invalid `char` bit pattern') {
                throw UnsupportedError('Unsupported expected trap: $expected');
              }
              // Only the invocation may satisfy a trap; arguments, signature
              // lookup, decoding, linking and initialization are outside here.
              Object? invocationError;
              try {
                await runtime.invokeExport(name, args);
              } catch (error) {
                invocationError = error;
              }
              if (invocationError == null) {
                throw StateError('Invocation did not trap.');
              }
              final matches = expected == 'invalid `char` bit pattern'
                  ? matchesComponentCharTrap(invocationError)
                  : matchesComponentStringTrap(
                      invocationError,
                      expected as String,
                    );
              if (!matches) {
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
    'instantiations': const {'module', 'module_instance'},
    'definitions': const {'module_definition'},
    'returns': const {'assert_return'},
    'traps': const {'assert_trap'},
  }.entries) {
    final selected = records.where(
      (record) => entry.value.contains(record['type']),
    );
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
      final report = <String, Object?>{'index': i, 'status': 'failed'};
      reports.add(report);
      try {
        final entry = files[i];
        if (entry is! Map) {
          throw const FormatException('File entry must be an object.');
        }
        report['path'] = entry['path'];
        final anchor = _frozenSources[entry['path']];
        if (inventory['repository'] != _repository ||
            anchor == null ||
            anchor.entries.any((field) => entry[field.key] != field.value)) {
          throw const FormatException(
            'Frozen Component source identity mismatch.',
          );
        }
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
            if (command['type'] != 'module' &&
                command['type'] != 'module_definition') {
              continue;
            }
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
    if (temporary != null) {
      try {
        await temporary.delete(recursive: true);
      } catch (error) {
        result['status'] = 'failed';
        result['cleanup_error'] = error.toString();
      }
    }
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
    option('--output-json', '.dart_tool/component_spec/values.json'),
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  final totals = report['totals'] as Map;
  stdout.writeln(
    'Component values: ${report['status']}; '
    '${totals['commands_passed']}/${totals['commands_seen']} commands; '
    '${totals['commands_skipped']} skipped.',
  );
  if (report['status'] != 'passed') exitCode = 1;
}
