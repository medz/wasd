import '../http.dart';

/// Stub for non-`dart:io` platforms.
final class WASIPreview2NativeHttpHost extends WASIPreview2HttpHost {
  /// Throws because native HTTP requires `dart:io`.
  WASIPreview2NativeHttpHost({super.table, super.pollHost, super.streamsHost})
    : super() {
    throw UnsupportedError('WASIPreview2NativeHttpHost requires dart:io.');
  }
}
