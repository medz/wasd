import 'doom_monitor_types.dart';

/// Creates a non-IO fallback DOOM monitor client.
DoomMonitorClient createDoomMonitorClient() => _StubDoomMonitorClient();

final class _StubDoomMonitorClient implements DoomMonitorClient {
  @override
  bool get supportsLiveMonitor => false;

  @override
  Future<DoomMonitorRunResult> runMonitor() async => const DoomMonitorRunResult(
    ok: false,
    log: '',
    error: 'Live monitor requires `dart:io` + Node.js environment.',
  );
}
