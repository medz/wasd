import 'wasi_socket_transport.dart';

WasiSocketTransport createAutoWasiSocketTransport({
  Map<int, Object> preopenedSockets = const {},
}) {
  return const WasiSocketTransport();
}

const bool autoHostSocketSupported = false;
