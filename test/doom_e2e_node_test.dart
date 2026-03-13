import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('DOOM node monitor boots and emits first frame', () async {
    final result = await Process.run('node', <String>[
      'tool/doom_node_monitor.mjs',
      '--mode=start',
      '--write-frames=1',
    ]);

    final stdoutText = result.stdout.toString();
    final stderrText = result.stderr.toString();

    expect(
      result.exitCode,
      0,
      reason: 'node monitor failed\nstdout:\n$stdoutText\nstderr:\n$stderrText',
    );
    expect(stdoutText, contains('DOOM NODE MONITOR PASS'));

    final firstFrameLine = stdoutText
        .split('\n')
        .map((line) => line.trim())
        .firstWhere(
          (line) => line.startsWith('first_frame='),
          orElse: () => '',
        );
    expect(firstFrameLine, isNotEmpty);

    final firstFramePath = firstFrameLine.substring('first_frame='.length);
    final frameFile = File(firstFramePath);
    expect(
      await frameFile.exists(),
      isTrue,
      reason: 'missing frame file: $firstFramePath',
    );
  });
}
