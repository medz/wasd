// Runs a fixed multi-memory subset through the public Dart VM API.
// wasm-tools only converts WAST; it never executes the modules.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/wasm.dart';

const _revision = '193e551ff22663995b1ac95dc62344133669e14b';
const _files = [
  'memory-multi',
  'memory_copy0',
  'memory_copy1',
  'memory_fill0',
  'memory_init0',
  'data_drop0',
  'memory_grow',
  'memory_size_import',
  'memory_size0',
  'memory_size1',
  'memory_size2',
  'memory_size3',
  'memory_trap0',
  'memory_trap1',
];

Future<void> main(List<String> args) async {
  String option(String key, String fallback) => args
      .firstWhere(
        (a) => a.startsWith('--$key='),
        orElse: () => '--$key=$fallback',
      )
      .substring(key.length + 3);
  final suite = option('testsuite', 'third_party/wasm-spec-tests');
  final tool = option('wasm-tools', '.toolchains/bin/wasm-tools');
  final output = option('output', 'build/core-multi-memory-public.json');
  final revision = await Process.run('git', ['-C', suite, 'rev-parse', 'HEAD']);
  if (revision.exitCode != 0 || '${revision.stdout}'.trim() != _revision) {
    throw StateError('Expected testsuite revision $_revision.');
  }
  final version = await Process.run(tool, ['--version']);
  if (version.exitCode != 0) throw StateError('${version.stderr}');
  final temp = Directory.systemTemp.createTempSync('wasd-public-multi-memory-');
  final results = <Map<String, Object?>>[];
  var passed = 0;
  try {
    for (final name in _files) {
      final dir = Directory('${temp.path}/$name')..createSync();
      final script = '${dir.path}/script.json';
      final conversion = await Process.run(tool, [
        'json-from-wast',
        '$suite/$name.wast',
        '--wasm-dir',
        dir.path,
        '-o',
        script,
      ]);
      if (conversion.exitCode != 0) throw StateError('${conversion.stderr}');
      final commands =
          (jsonDecode(File(script).readAsStringSync()) as Map)['commands']
              as List;
      final registry = <String, Instance>{};
      final named = <String, Instance>{};
      Instance? current;
      Module compile(Map command) => Module(
        File('${dir.path}/${command['filename']}').readAsBytesSync().buffer,
        features: {CoreFeature.multiMemory},
      );
      Instance instantiate(Module module) => Instance(module, {
        for (final entry in registry.entries)
          entry.key: {
            for (final export in entry.value.exports.entries)
              export.key: export.value as ImportValue,
          },
      });
      Object? action(Map command) {
        if (command['type'] != 'invoke') {
          throw UnsupportedError('Action $command');
        }
        final instance = command['module'] == null
            ? current!
            : named[command['module']]!;
        final function =
            instance.exports[command['field']]! as FunctionImportExportValue;
        return function.ref([
          for (final arg in command['args'] as List) _scalar(arg as Map),
        ]);
      }

      var count = 0;
      for (final raw in commands) {
        final command = raw as Map;
        try {
          switch (command['type']) {
            case 'module':
              current = instantiate(compile(command));
              if (command['name'] != null) {
                named[command['name'] as String] = current;
              }
            case 'register':
              registry[command['as'] as String] = command['name'] == null
                  ? current!
                  : named[command['name']]!;
            case 'action':
              action(command['action'] as Map);
            case 'assert_return':
              final result = action(command['action'] as Map);
              final expected = command['expected'] as List;
              if (expected.isEmpty
                  ? result != null
                  : expected.length != 1 ||
                        !_matches(result, _scalar(expected.single as Map))) {
                throw StateError(
                  'Unexpected result $result, expected $expected',
                );
              }
            case 'assert_trap':
              _expectBoundsTrap(() => action(command['action'] as Map));
            case 'assert_uninstantiable':
              final module = compile(
                command,
              ); // Invalid compilation is not a trap.
              _expectBoundsTrap(() => instantiate(module));
            case 'assert_invalid':
              try {
                compile(command);
              } on CompileError {
                break;
              }
              throw StateError('Invalid module compiled successfully.');
            default:
              throw UnsupportedError('Command $command');
          }
          count++;
        } catch (e) {
          throw StateError(
            '$name.wast:${command['line']} ${command['type']}: $e',
          );
        }
      }
      results.add({'file': '$name.wast', 'passed_commands': count});
      passed += count;
      stdout.writeln('$name.wast: $count commands passed');
    }
    final file = File(output)..parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'testsuite_revision': _revision,
        'converter': '${version.stdout}'.trim(),
        'execution': 'WASD public Module/Instance, pure Dart VM',
        'features': ['multiMemory'],
        'files': results,
        'passed_commands': passed,
        'failed_commands': 0,
        'skipped_commands': 0,
        'scope':
            'Fixed multi-memory subset, not full Core conformance. '
            'data0.wast/data1.wast require global host imports unsupported by the existing public VM adapter.',
      }),
    );
    stdout.writeln(
      '${results.length} files, $passed commands passed, zero skips',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

Object _scalar(Map value) {
  final bits = BigInt.parse(value['value'] as String);
  switch (value['type']) {
    case 'i32':
      return bits.toSigned(32).toInt();
    case 'i64':
      return bits.toSigned(64);
    case 'f32':
      return (ByteData(4)
            ..setUint32(0, bits.toUnsigned(32).toInt(), Endian.little))
          .getFloat32(0, Endian.little);
    case 'f64':
      return (ByteData(8)
            ..setUint32(0, bits.toUnsigned(32).toInt(), Endian.little)
            ..setUint32(4, (bits >> 32).toUnsigned(32).toInt(), Endian.little))
          .getFloat64(0, Endian.little);
    default:
      throw UnsupportedError('Non-scalar value $value');
  }
}

bool _matches(Object? actual, Object expected) => expected is BigInt
    ? (actual is int ? BigInt.from(actual) : actual) == expected
    : actual == expected;

void _expectBoundsTrap(Object? Function() run) {
  try {
    run();
  } catch (e) {
    final message = '$e'.toLowerCase().replaceAll('-', ' ');
    if (message.contains('out of bounds')) return;
    rethrow;
  }
  throw StateError('Expected an out-of-bounds trap.');
}
