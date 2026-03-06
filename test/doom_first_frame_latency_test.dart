import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const String _doomWasmPath = 'test/fixtures/doom/doom.wasm';
const String _doomIwadPath = 'test/fixtures/doom/doom1.wad';
const String _frameDir = '.dart_tool/doom_first_frame_latency';
const Duration _latencyBudget = Duration(seconds: 30);

void main() {
  test(
    'DOOM node monitor reaches first frame within latency budget',
    () async {
      final frameDirectory = Directory(_frameDir);
      if (await frameDirectory.exists()) {
        await frameDirectory.delete(recursive: true);
      }

      final stopwatch = Stopwatch()..start();
      final result = await Process.run('node', <String>[
        'tool/doom_node_monitor.mjs',
        '--mode=start',
        '--wasm=$_doomWasmPath',
        '--iwad=$_doomIwadPath',
        '--frame-dir=$_frameDir',
        '--write-frames=1',
      ]);
      stopwatch.stop();

      final stdoutText = '${result.stdout}';
      final stderrText = '${result.stderr}';
      expect(
        result.exitCode,
        0,
        reason:
            'node monitor failed\nstdout:\n$stdoutText\nstderr:\n$stderrText',
      );
      expect(
        stopwatch.elapsed,
        lessThan(_latencyBudget),
        reason:
            'first frame exceeded budget ${_latencyBudget.inSeconds}s; elapsed=${stopwatch.elapsed.inMilliseconds}ms\nstdout:\n$stdoutText\nstderr:\n$stderrText',
      );

      final reportFile = File('$_frameDir/report.json');
      expect(
        await reportFile.exists(),
        isTrue,
        reason: 'missing report file: ${reportFile.path}',
      );

      final rawReport = jsonDecode(await reportFile.readAsString());
      expect(rawReport, isA<Map<String, dynamic>>());
      final report = rawReport as Map<String, dynamic>;
      expect('${report['health']}', 'ok');

      final frameCount = report['frameCount'];
      expect(frameCount, isA<int>());
      expect(frameCount as int, greaterThan(0));

      final callbackTrace =
          (report['callbackTrace'] as List<dynamic>? ?? const <dynamic>[])
              .map((entry) => '$entry')
              .toList(growable: false);
      expect(
        callbackTrace.any((entry) => entry.startsWith('render_frame(')),
        isTrue,
        reason: 'callbackTrace has no render_frame entry: $callbackTrace',
      );

      final writtenFrames =
          (report['writtenFrames'] as List<dynamic>? ?? const <dynamic>[])
              .map((entry) => '$entry')
              .toList(growable: false);
      expect(writtenFrames, isNotEmpty);
      final firstFrame = File(writtenFrames.first);
      expect(
        await firstFrame.exists(),
        isTrue,
        reason: 'missing first frame artifact: ${firstFrame.path}',
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
    final nodeVersion = Process.runSync('node', <String>['--version']);
    if (nodeVersion.exitCode != 0) {
      return 'Node.js is required for DOOM first frame latency checks.';
    }
  } catch (_) {
    return 'Node.js is required for DOOM first frame latency checks.';
  }
  return null;
}
