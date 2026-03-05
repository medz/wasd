import 'dart:typed_data';

/// Contract for running DOOM frame monitoring.
abstract class DoomMonitorClient {
  /// Whether live monitor execution is supported on this platform.
  bool get supportsLiveMonitor;

  /// Runs the DOOM monitor and returns a result payload.
  Future<DoomMonitorRunResult> runMonitor();
}

/// Outcome of one DOOM monitor run.
final class DoomMonitorRunResult {
  /// Creates a monitor run result.
  const DoomMonitorRunResult({
    required this.ok,
    required this.log,
    this.error,
    this.snapshot,
  });

  /// True when a live monitor run completed successfully.
  final bool ok;

  /// Combined process output from the monitor run.
  final String log;

  /// Error message when [ok] is false.
  final String? error;

  /// Parsed snapshot when the run produced frame/report artifacts.
  final DoomSnapshot? snapshot;
}

/// Parsed monitor snapshot rendered by the Flutter example UI.
final class DoomSnapshot {
  /// Creates a snapshot from monitor report fields and frame bytes.
  const DoomSnapshot({
    required this.source,
    required this.health,
    required this.exitCode,
    required this.frameCount,
    required this.paletteUpdates,
    required this.windowWidth,
    required this.windowHeight,
    required this.uniqueFrameHashes,
    required this.callbackTrace,
    required this.frameBytes,
    required this.framePath,
  });

  /// Snapshot source (`bundled` or `live`).
  final String source;

  /// Monitor health status.
  final String health;

  /// WASI process exit code.
  final int exitCode;

  /// Number of frames received by the monitor.
  final int frameCount;

  /// Number of palette updates observed.
  final int paletteUpdates;

  /// Reported frame width.
  final int windowWidth;

  /// Reported frame height.
  final int windowHeight;

  /// Count of unique frame hashes observed.
  final int uniqueFrameHashes;

  /// Recorded host callback trace entries.
  final List<String> callbackTrace;

  /// Decoded frame image bytes.
  final Uint8List frameBytes;

  /// Original frame file path used for display metadata.
  final String framePath;

  /// Builds a snapshot from a monitor JSON report.
  factory DoomSnapshot.fromReport(
    Map<String, dynamic> report, {
    required Uint8List frameBytes,
    required String framePath,
  }) {
    final window = report['windowSize'];
    final windowMap = window is Map<String, dynamic>
        ? window
        : const <String, dynamic>{};
    return DoomSnapshot(
      source: '${report['source'] ?? 'live'}',
      health: '${report['health'] ?? 'unknown'}',
      exitCode: _asInt(report['exitCode']),
      frameCount: _asInt(report['frameCount']),
      paletteUpdates: _asInt(report['paletteUpdates']),
      windowWidth: _asInt(windowMap['width'], fallback: 320),
      windowHeight: _asInt(windowMap['height'], fallback: 200),
      uniqueFrameHashes: _asInt(report['uniqueFrameHashes']),
      callbackTrace: (report['callbackTrace'] as List<dynamic>? ?? const [])
          .map((dynamic value) => '$value')
          .toList(),
      frameBytes: frameBytes,
      framePath: framePath,
    );
  }

  static int _asInt(Object? value, {int fallback = 0}) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return fallback;
  }
}
