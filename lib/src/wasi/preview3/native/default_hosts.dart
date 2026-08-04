import '../filesystem.dart';
import '../http.dart';
import '../sockets.dart';
import '../../component/resource_table.dart';
import 'filesystem.dart';
import 'http.dart';
import 'sockets.dart';

/// Creates the Dart VM-backed Preview3 filesystem host.
WASIPreview3FilesystemHost createNativePreview3FilesystemHost({
  required Map<String, String> preopens,
  required bool canMutate,
  required WASIComponentResourceTable table,
}) => WASIPreview3NativeFilesystemHost(
  preopens: preopens,
  canMutate: canMutate,
  table: table,
);

/// Creates the Dart VM-backed Preview3 sockets host.
WASIPreview3SocketsHost createNativePreview3SocketsHost({
  required WASIComponentResourceTable table,
  WASIPreview3AddressResolver? resolveAddresses,
}) => WASIPreview3NativeSocketsHost(
  table: table,
  resolveAddresses: resolveAddresses,
);

/// Creates the Dart VM-backed Preview3 HTTP host.
WASIPreview3HttpHost createNativePreview3HttpHost({
  required WASIComponentResourceTable table,
  WASIPreview3HttpBackend? handlerBackend,
}) => WASIPreview3NativeHttpHost(table: table, handlerBackend: handlerBackend);

/// Creates the default Preview3 filesystem host on the Dart VM.
WASIPreview3FilesystemHost createDefaultPreview3FilesystemHost({
  required Map<String, String> preopens,
  required bool canMutate,
  required WASIComponentResourceTable table,
}) => createNativePreview3FilesystemHost(
  preopens: preopens,
  canMutate: canMutate,
  table: table,
);

/// Creates the default Preview3 sockets host on the Dart VM.
WASIPreview3SocketsHost createDefaultPreview3SocketsHost({
  required WASIComponentResourceTable table,
  WASIPreview3AddressResolver? resolveAddresses,
}) => createNativePreview3SocketsHost(
  table: table,
  resolveAddresses: resolveAddresses,
);

/// Creates the default Preview3 HTTP host on the Dart VM.
WASIPreview3HttpHost createDefaultPreview3HttpHost({
  required WASIComponentResourceTable table,
  WASIPreview3HttpBackend? handlerBackend,
}) =>
    createNativePreview3HttpHost(table: table, handlerBackend: handlerBackend);
