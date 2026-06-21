import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/measured_process.dart';

void main() {
  test(
    'runMeasuredProcess captures output, exit code, and elapsed time',
    () async {
      final result = await runMeasuredProcess(<String>[
        Platform.resolvedExecutable,
        '--version',
      ], rssSampleInterval: const Duration(milliseconds: 25));

      expect(result.exitCode, 0);
      expect(result.durationMs, greaterThanOrEqualTo(0));
      expect('${result.stdout}\n${result.stderr}', contains('Dart'));
      expect(result.metricsLine, contains('elapsed_ms='));
      expect(result.metricsLine, contains('peak_rss_bytes='));
    },
  );
}
