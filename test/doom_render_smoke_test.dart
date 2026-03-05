import 'dart:io';

import 'package:test/test.dart';

const String _doomWasmPath = 'test/fixtures/doom/doom.wasm';
const String _doomIwadPath = 'test/fixtures/doom/doom1.wad';

void main() {
  test(
    'doom node monitor captures first frame image',
    () async {
      final result = await Process.run('node', <String>[
        'tool/doom_node_monitor.mjs',
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
        contains('DOOM NODE MONITOR PASS'),
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: _skipReason(),
  );
}

String? _skipReason() {
  if (!File(_doomWasmPath).existsSync() || !File(_doomIwadPath).existsSync()) {
    return 'Doom fixtures missing, run: tool/setup_test_fixtures.sh --doom-only';
  }
  try {
    final nodeResult = Process.runSync('node', <String>['--version']);
    if (nodeResult.exitCode != 0) {
      return 'Node.js is required for DOOM render smoke test.';
    }
  } catch (_) {
    return 'Node.js is required for DOOM render smoke test.';
  }
  return null;
}
