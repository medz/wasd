import '../filesystem.dart';
import '../http.dart';
import '../sockets.dart';
import '../../component/resource_table.dart';

/// Throws because native Preview3 backends require `dart:io`.
WASIPreview3FilesystemHost createNativePreview3FilesystemHost({
  required Map<String, String> preopens,
  required bool canMutate,
  required WASIComponentResourceTable table,
}) {
  throw UnsupportedError('WASIPreview3ComponentHost.native requires dart:io.');
}

/// Throws because native Preview3 backends require `dart:io`.
WASIPreview3SocketsHost createNativePreview3SocketsHost({
  required WASIComponentResourceTable table,
  WASIPreview3AddressResolver? resolveAddresses,
}) {
  throw UnsupportedError('WASIPreview3ComponentHost.native requires dart:io.');
}

/// Throws because native Preview3 backends require `dart:io`.
WASIPreview3HttpHost createNativePreview3HttpHost({
  required WASIComponentResourceTable table,
  WASIPreview3HttpBackend? handlerBackend,
}) {
  throw UnsupportedError('WASIPreview3ComponentHost.native requires dart:io.');
}

/// Creates the default portable Preview3 filesystem host.
WASIPreview3FilesystemHost createDefaultPreview3FilesystemHost({
  required Map<String, String> preopens,
  required bool canMutate,
  required WASIComponentResourceTable table,
}) {
  if (preopens.isNotEmpty || canMutate) {
    throw UnsupportedError(
      'Default Preview3 filesystem preopens require dart:io.',
    );
  }
  return WASIPreview3FilesystemHost(table: table);
}

/// Creates the default portable Preview3 sockets host.
WASIPreview3SocketsHost createDefaultPreview3SocketsHost({
  required WASIComponentResourceTable table,
  WASIPreview3AddressResolver? resolveAddresses,
}) => WASIPreview3SocketsHost(table: table, resolveAddresses: resolveAddresses);

/// Creates the default portable Preview3 HTTP host.
WASIPreview3HttpHost createDefaultPreview3HttpHost({
  required WASIComponentResourceTable table,
  WASIPreview3HttpBackend? handlerBackend,
}) => WASIPreview3HttpHost(table: table, handlerBackend: handlerBackend);
