import 'dart:io';

import 'package:test/test.dart';

const String _doomWasmPath = 'test/fixtures/doom/doom.wasm';
const String _doomIwadPath = 'test/fixtures/doom/doom1.wad';

final String? _skipReason = _computeSkipReason();

void main() {
  test(
    'doom cli runtime matrix is consistent between dart-vm and dart2js/node',
    () async {
      final result = await Process.run('dart', <String>[
        'run',
        'tool/doom_runtime_matrix.dart',
        '--mode=instantiate',
        '--wasm=$_doomWasmPath',
        '--iwad=$_doomIwadPath',
      ]);

      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );

      expect(
        '${result.stdout}',
        contains('RUNTIME MATRIX PASS'),
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: _skipReason,
  );
}

String? _computeSkipReason() {
  if (!File(_doomWasmPath).existsSync() || !File(_doomIwadPath).existsSync()) {
    return 'Doom fixtures missing, run: tool/setup_test_fixtures.sh --doom-only';
  }

  try {
    final nodeVersion = Process.runSync('node', <String>['--version']);
    if (nodeVersion.exitCode != 0) {
      return 'Node.js is required for dart2js runtime parity checks.';
    }
  } catch (_) {
    return 'Node.js is required for dart2js runtime parity checks.';
  }

  return null;
}
