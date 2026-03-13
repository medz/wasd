import 'dart:io';

import 'package:wasd/wasm.dart';

import '../test/support/wasm_fixtures.dart';

const int _defaultIterations = 200000;

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final iterations =
      int.tryParse(options['iterations'] ?? '') ?? _defaultIterations;
  final maxMs = int.tryParse(options['max-ms'] ?? '');

  final result = await WebAssembly.instantiate(directCallModuleBytes().buffer);
  final callTwice =
      (result.instance.exports['call_twice']! as FunctionImportExportValue).ref;

  var checksum = 0;
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += callTwice([i]) as int;
  }
  stopwatch.stop();

  final elapsedMs = stopwatch.elapsedMicroseconds / 1000.0;
  stdout.writeln(
    'iterations=$iterations elapsedMs=${elapsedMs.toStringAsFixed(3)} checksum=$checksum',
  );

  if (maxMs != null && elapsedMs > maxMs) {
    stderr.writeln(
      'direct call benchmark exceeded budget: '
      '${elapsedMs.toStringAsFixed(3)}ms > ${maxMs}ms',
    );
    exitCode = 1;
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      continue;
    }
    final eq = arg.indexOf('=');
    if (eq != -1) {
      result[arg.substring(2, eq)] = arg.substring(eq + 1);
      continue;
    }
    final key = arg.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      result[key] = args[i + 1];
      i++;
      continue;
    }
    result[key] = 'true';
  }
  return result;
}
