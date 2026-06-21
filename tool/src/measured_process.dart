import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

final class MeasuredProcessResult {
  const MeasuredProcessResult({
    required this.command,
    required this.exitCode,
    required this.durationMs,
    required this.stdout,
    required this.stderr,
    required this.peakRssBytes,
  });

  final List<String> command;
  final int exitCode;
  final int durationMs;
  final String stdout;
  final String stderr;
  final int? peakRssBytes;

  String get metricsLine {
    final rss = peakRssBytes == null ? 'unknown' : '$peakRssBytes';
    return 'elapsed_ms=$durationMs peak_rss_bytes=$rss';
  }

  String diagnostics(String header) {
    return [
      header,
      'command: ${command.join(' ')}',
      metricsLine,
      'stdout:',
      stdout,
      'stderr:',
      stderr,
    ].join('\n');
  }
}

Future<MeasuredProcessResult> runMeasuredProcess(
  List<String> command, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
  Duration rssSampleInterval = const Duration(milliseconds: 250),
}) async {
  if (command.isEmpty) {
    throw ArgumentError.value(command, 'command', 'must not be empty');
  }

  final watch = Stopwatch()..start();
  final process = await Process.start(
    command.first,
    command.sublist(1),
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
  final completed = Completer<void>();
  final peakRss = _samplePeakResidentSetBytes(
    process.pid,
    rssSampleInterval,
    completed.future,
  );
  final stdoutText = utf8.decodeStream(process.stdout);
  final stderrText = utf8.decodeStream(process.stderr);

  final exitCode = await process.exitCode;
  watch.stop();
  if (!completed.isCompleted) {
    completed.complete();
  }

  return MeasuredProcessResult(
    command: List<String>.unmodifiable(command),
    exitCode: exitCode,
    durationMs: watch.elapsedMilliseconds,
    stdout: await stdoutText,
    stderr: await stderrText,
    peakRssBytes: await peakRss,
  );
}

Future<int?> _samplePeakResidentSetBytes(
  int processId,
  Duration interval,
  Future<void> completed,
) async {
  int? peak;
  while (true) {
    peak = _maxNullable(peak, await _residentSetBytes(processId));
    final done = await Future.any<Object>([
      completed.then<Object>((_) => true),
      Future<void>.delayed(interval).then<Object>((_) => false),
    ]);
    if (done == true) {
      peak = _maxNullable(peak, await _residentSetBytes(processId));
      return peak;
    }
  }
}

Future<int?> _residentSetBytes(int processId) async {
  try {
    final result = await Process.run('ps', <String>[
      '-o',
      'rss=',
      '-p',
      '$processId',
    ]);
    if (result.exitCode != 0) {
      return null;
    }
    final text = result.stdout.toString().trim();
    if (text.isEmpty) {
      return null;
    }
    final kibibytes = int.tryParse(text.split(RegExp(r'\s+')).first);
    if (kibibytes == null) {
      return null;
    }
    return kibibytes * 1024;
  } catch (_) {
    return null;
  }
}

int? _maxNullable(int? a, int? b) {
  if (a == null) {
    return b;
  }
  if (b == null) {
    return a;
  }
  return math.max(a, b);
}
