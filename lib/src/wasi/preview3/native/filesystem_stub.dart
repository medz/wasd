import '../filesystem.dart';

/// Placeholder for platforms without `dart:io` host filesystem access.
final class WASIPreview3NativeFilesystemHost
    extends WASIPreview3FilesystemHost {
  /// Throws because this platform cannot expose host directories.
  WASIPreview3NativeFilesystemHost({
    required Map<String, String> preopens,
    bool canMutate = false,
  }) : super() {
    throw UnsupportedError(
      'WASIPreview3NativeFilesystemHost requires dart:io.',
    );
  }
}
