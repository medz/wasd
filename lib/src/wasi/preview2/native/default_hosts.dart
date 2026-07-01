import '../filesystem.dart';
import '../http.dart';
import '../io.dart';
import '../poll.dart';
import '../sockets.dart';
import 'filesystem.dart';
import 'http.dart';
import 'sockets.dart';

/// Creates the native Preview2 filesystem host for Dart VM runtimes.
WASIPreview2FilesystemHost createNativePreview2FilesystemHost({
  required Map<String, String> preopens,
  required bool canMutate,
  required WASIPreview2StreamsHost streamsHost,
}) => WASIPreview2NativeFilesystemHost(
  preopens: preopens,
  canMutate: canMutate,
  streamsHost: streamsHost,
);

/// Creates the native Preview2 sockets host for Dart VM runtimes.
WASIPreview2SocketsHost createNativePreview2SocketsHost({
  required WASIPreview2PollHost pollHost,
  required WASIPreview2StreamsHost streamsHost,
  WASIPreview2AddressResolver? resolveAddresses,
}) => WASIPreview2NativeSocketsHost(
  pollHost: pollHost,
  streamsHost: streamsHost,
  resolveAddresses: resolveAddresses,
);

/// Creates the native Preview2 HTTP host for Dart VM runtimes.
WASIPreview2HttpHost createNativePreview2HttpHost({
  required WASIPreview2PollHost pollHost,
  required WASIPreview2StreamsHost streamsHost,
}) => WASIPreview2NativeHttpHost(pollHost: pollHost, streamsHost: streamsHost);
