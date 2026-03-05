import 'doom_monitor_client_stub.dart'
    if (dart.library.io) 'doom_monitor_client_io.dart'
    as impl;
import 'doom_monitor_types.dart';

export 'doom_monitor_types.dart';

/// Creates a platform-appropriate DOOM monitor client.
DoomMonitorClient createDoomMonitorClient() => impl.createDoomMonitorClient();
