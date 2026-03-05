import 'dart:convert';
import 'dart:io';

import 'doom_monitor_types.dart';

/// Creates an IO-backed DOOM monitor client.
DoomMonitorClient createDoomMonitorClient() => _IoDoomMonitorClient();

final class _IoDoomMonitorClient implements DoomMonitorClient {
  @override
  bool get supportsLiveMonitor => true;

  @override
  Future<DoomMonitorRunResult> runMonitor() async {
    try {
      final nodeCheck = await Process.run('node', const <String>['--version']);
      if (nodeCheck.exitCode != 0) {
        return DoomMonitorRunResult(
          ok: false,
          log: '${nodeCheck.stdout}\n${nodeCheck.stderr}',
          error: 'Node.js is not available.',
        );
      }

      final script = _resolveMonitorScript();
      if (script == null) {
        return const DoomMonitorRunResult(
          ok: false,
          log: '',
          error: 'Cannot locate tool/doom_node_monitor.mjs',
        );
      }

      final scriptFile = File(script).absolute;
      final repoRoot = scriptFile.parent.parent.path;
      final run = await Process.run('node', <String>[
        scriptFile.path,
      ], workingDirectory: repoRoot);

      final log = _formatLog(run);
      if (run.exitCode != 0) {
        return DoomMonitorRunResult(
          ok: false,
          log: log,
          error: 'Node monitor exited with code ${run.exitCode}.',
        );
      }

      final output = '${run.stdout}';
      final reportPathRaw = _extractLineValue(output, 'report=');
      final framePathRaw = _extractLineValue(output, 'first_frame=');
      if (reportPathRaw == null || framePathRaw == null) {
        return DoomMonitorRunResult(
          ok: false,
          log: log,
          error: 'Node monitor output missing report/frame paths.',
        );
      }

      final reportFile = _resolveRepoPath(repoRoot, reportPathRaw);
      final frameFile = _resolveRepoPath(repoRoot, framePathRaw);
      if (!reportFile.existsSync()) {
        return DoomMonitorRunResult(
          ok: false,
          log: log,
          error: 'Report file does not exist: ${reportFile.path}',
        );
      }
      if (!frameFile.existsSync()) {
        return DoomMonitorRunResult(
          ok: false,
          log: log,
          error: 'Frame file does not exist: ${frameFile.path}',
        );
      }

      final reportRaw = jsonDecode(await reportFile.readAsString());
      if (reportRaw is! Map<String, dynamic>) {
        return DoomMonitorRunResult(
          ok: false,
          log: log,
          error: 'Report JSON format invalid.',
        );
      }
      reportRaw['source'] = 'live';

      final frameBytes = await frameFile.readAsBytes();
      final snapshot = DoomSnapshot.fromReport(
        reportRaw,
        frameBytes: frameBytes,
        framePath: frameFile.path,
      );
      return DoomMonitorRunResult(ok: true, log: log, snapshot: snapshot);
    } catch (error) {
      return DoomMonitorRunResult(ok: false, log: '', error: error.toString());
    }
  }

  String? _resolveMonitorScript() {
    const candidates = <String>[
      '../../tool/doom_node_monitor.mjs',
      '../tool/doom_node_monitor.mjs',
      'tool/doom_node_monitor.mjs',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  String _formatLog(ProcessResult run) {
    final out = StringBuffer();
    out.writeln('exit=${run.exitCode}');
    final stdoutText = '${run.stdout}'.trimRight();
    final stderrText = '${run.stderr}'.trimRight();
    if (stdoutText.isNotEmpty) {
      out.writeln('[stdout]');
      out.writeln(stdoutText);
    }
    if (stderrText.isNotEmpty) {
      out.writeln('[stderr]');
      out.writeln(stderrText);
    }
    return out.toString().trimRight();
  }
}

String? _extractLineValue(String text, String prefix) {
  for (final rawLine in LineSplitter.split(text)) {
    final line = rawLine.trim();
    if (line.startsWith(prefix)) {
      return line.substring(prefix.length).trim();
    }
  }
  return null;
}

File _resolveRepoPath(String repoRoot, String rawPath) {
  final file = File(rawPath);
  if (file.isAbsolute) {
    return file;
  }
  return File('$repoRoot/$rawPath');
}
