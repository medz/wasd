import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/measured_process.dart';

const String _doomWasmPath = 'test/fixtures/doom/doom.wasm';
const String _doomIwadPath = 'test/fixtures/doom/doom1.wad';

final String? _skipReason = _computeSkipReason();

void main() {
  test(
    'doom cli runtime matrix is consistent between dart-vm and dart2js/node',
    () async {
      final result = await runMeasuredProcess(<String>[
        'dart',
        'run',
        'tool/doom_runtime_matrix.dart',
        '--mode=instantiate',
        '--wasm=$_doomWasmPath',
        '--iwad=$_doomIwadPath',
      ]);

      expect(
        result.exitCode,
        0,
        reason: result.diagnostics('doom runtime matrix failed'),
      );

      expect(
        result.stdout,
        contains('RUNTIME MATRIX PASS'),
        reason: result.diagnostics('doom runtime matrix did not pass'),
      );
      expect(
        result.stdout,
        matches(
          RegExp(
            r'== dart-vm ==[\s\S]*elapsed_ms=\d+[\s\S]*peak_rss_bytes=(unknown|\d+)',
          ),
        ),
        reason: result.diagnostics(
          'doom runtime matrix did not report dart-vm process metrics',
        ),
      );
      expect(
        result.stdout,
        matches(
          RegExp(
            r'== node-js ==[\s\S]*elapsed_ms=\d+[\s\S]*peak_rss_bytes=(unknown|\d+)',
          ),
        ),
        reason: result.diagnostics(
          'doom runtime matrix did not report node-js process metrics',
        ),
      );
    },
    tags: const <String>['doom', 'slow'],
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
