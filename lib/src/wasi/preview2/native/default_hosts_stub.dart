import '../filesystem.dart';
import '../http.dart';
import '../io.dart';
import '../poll.dart';
import '../sockets.dart';

/// Throws because native Preview2 backends require `dart:io`.
WASIPreview2FilesystemHost createNativePreview2FilesystemHost({
  required Map<String, String> preopens,
  required bool canMutate,
  required WASIPreview2StreamsHost streamsHost,
}) {
  throw UnsupportedError('WASIPreview2ComponentHost.native requires dart:io.');
}

/// Throws because native Preview2 backends require `dart:io`.
WASIPreview2SocketsHost createNativePreview2SocketsHost({
  required WASIPreview2PollHost pollHost,
  required WASIPreview2StreamsHost streamsHost,
  WASIPreview2AddressResolver? resolveAddresses,
}) {
  throw UnsupportedError('WASIPreview2ComponentHost.native requires dart:io.');
}

/// Throws because native Preview2 backends require `dart:io`.
WASIPreview2HttpHost createNativePreview2HttpHost({
  required WASIPreview2PollHost pollHost,
  required WASIPreview2StreamsHost streamsHost,
}) {
  throw UnsupportedError('WASIPreview2ComponentHost.native requires dart:io.');
}

/// Non-native platforms do not expose a native stdin terminal.
bool isNativeStdinTerminal() => false;

/// Non-native platforms do not expose a native stdout terminal.
bool isNativeStdoutTerminal() => false;

/// Non-native platforms do not expose a native stderr terminal.
bool isNativeStderrTerminal() => false;
