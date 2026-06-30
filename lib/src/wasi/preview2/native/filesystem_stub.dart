import '../filesystem.dart';

/// Placeholder for platforms without `dart:io` host filesystem access.
final class WASIPreview2NativeFilesystemHost
    extends WASIPreview2FilesystemHost {
  /// Throws because this platform cannot expose host directories.
  WASIPreview2NativeFilesystemHost({
    required Map<String, String> preopens,
    bool canMutate = false,
  }) : super() {
    throw UnsupportedError(
      'WASIPreview2NativeFilesystemHost requires dart:io.',
    );
  }
}
