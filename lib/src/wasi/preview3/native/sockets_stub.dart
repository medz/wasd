import '../sockets.dart';

/// Placeholder for platforms without `dart:io` socket access.
final class WASIPreview3NativeSocketsHost extends WASIPreview3SocketsHost {
  /// Throws because this platform cannot expose host sockets.
  WASIPreview3NativeSocketsHost({super.table, super.resolveAddresses})
    : super() {
    throw UnsupportedError('WASIPreview3NativeSocketsHost requires dart:io.');
  }
}
