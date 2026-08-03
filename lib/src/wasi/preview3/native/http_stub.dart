import '../http.dart';

/// Placeholder for platforms without `dart:io` HTTP support.
final class WASIPreview3NativeHttpHost extends WASIPreview3HttpHost {
  /// Throws because this platform cannot provide the native HTTP client.
  WASIPreview3NativeHttpHost({super.table, super.handlerBackend}) {
    throw UnsupportedError('WASIPreview3NativeHttpHost requires dart:io.');
  }
}
