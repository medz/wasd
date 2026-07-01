import '../sockets.dart';

/// Placeholder for platforms without `dart:io` socket access.
final class WASIPreview2NativeSocketsHost extends WASIPreview2SocketsHost {
  /// Throws because this platform cannot expose host sockets.
  WASIPreview2NativeSocketsHost({
    super.table,
    super.pollHost,
    super.streamsHost,
    super.resolveAddresses,
  }) : super() {
    throw UnsupportedError('WASIPreview2NativeSocketsHost requires dart:io.');
  }
}
