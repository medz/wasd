import 'wasi_socket_transport.dart';
import 'wasi_socket_auto_stub.dart'
    if (dart.library.io) 'wasi_socket_auto_io.dart'
    if (dart.library.js_interop) 'wasi_socket_auto_web.dart'
    as auto;

WasiSocketTransport createAutoWasiSocketTransport({
  Map<int, Object> preopenedSockets = const {},
}) {
  return auto.createAutoWasiSocketTransport(preopenedSockets: preopenedSockets);
}

bool get autoHostSocketSupported => auto.autoHostSocketSupported;
