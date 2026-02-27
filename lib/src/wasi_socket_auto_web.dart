import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'wasi_socket_transport.dart';

WasiSocketTransport createAutoWasiSocketTransport({
  Map<int, Object> preopenedSockets = const {},
}) {
  return _WebSocketTransport(preopenedSockets: preopenedSockets).transport;
}

const bool autoHostSocketSupported = true;

final class _WebSocketTransport {
  _WebSocketTransport({required Map<int, Object> preopenedSockets}) {
    for (final entry in preopenedSockets.entries) {
      final webSocket = _asWebSocket(entry.value);
      if (webSocket != null) {
        _sockets[entry.key] = _WebSocketEndpoint(webSocket);
      }
    }
  }

  final Map<int, _WebSocketEndpoint> _sockets = <int, _WebSocketEndpoint>{};

  WasiSocketTransport get transport => WasiSocketTransport(
    accept: _accept,
    recv: _recv,
    send: _send,
    shutdown: _shutdown,
    close: _close,
    containsFd: _containsFd,
  );

  bool _containsFd({required int fd}) => _sockets.containsKey(fd);

  WasiSockAcceptResult _accept({
    required int fd,
    required int flags,
    required WasiSockAllocateFd allocateFd,
  }) {
    return const WasiSockAcceptResult.error(_errnoNosys);
  }

  WasiSockRecvResult _recv({
    required int fd,
    required int flags,
    required int maxBytes,
  }) {
    final socket = _sockets[fd];
    if (socket == null) {
      return const WasiSockRecvResult.error(_errnoBadf);
    }
    if (maxBytes < 0) {
      return const WasiSockRecvResult.error(_errnoInval);
    }
    final bytes = socket.read(maxBytes);
    if (bytes.isEmpty && !socket.closed) {
      return const WasiSockRecvResult.error(_errnoAgain);
    }
    return WasiSockRecvResult.received(bytes);
  }

  WasiSockSendResult _send({
    required int fd,
    required int flags,
    required Uint8List data,
  }) {
    final socket = _sockets[fd];
    if (socket == null) {
      return const WasiSockSendResult.error(_errnoBadf);
    }
    socket.send(data);
    return WasiSockSendResult.sent(data.length);
  }

  int? _shutdown({required int fd, required int how}) {
    final socket = _sockets[fd];
    if (socket == null) {
      return _errnoBadf;
    }
    if (how < 0 || how > 2) {
      return _errnoInval;
    }
    socket.close();
    return _errnoSuccess;
  }

  int? _close({required int fd}) {
    final socket = _sockets.remove(fd);
    if (socket == null) {
      return null;
    }
    socket.close();
    return _errnoSuccess;
  }
}

web.WebSocket? _asWebSocket(Object value) {
  final jsValue = value as JSAny?;
  if (jsValue == null || !jsValue.isA<web.WebSocket>()) {
    return null;
  }
  return jsValue as web.WebSocket;
}

final class _WebSocketEndpoint {
  _WebSocketEndpoint(this.socket) {
    socket.binaryType = 'arraybuffer';
    _messageSubscription = web.EventStreamProviders.messageEvent
        .forTarget(socket)
        .listen((event) {
          final payload = event.data?.dartify();
          if (payload is ByteBuffer) {
            _pending.addAll(Uint8List.view(payload));
          } else if (payload is Uint8List) {
            _pending.addAll(payload);
          } else if (payload is List<int>) {
            _pending.addAll(payload);
          } else if (payload is String) {
            _pending.addAll(utf8.encode(payload));
          }
        });
    _closeSubscription = web.EventStreamProviders.closeEvent
        .forTarget(socket)
        .listen((_) => closed = true);
  }

  final web.WebSocket socket;
  final Queue<int> _pending = Queue<int>();
  late final StreamSubscription<web.MessageEvent> _messageSubscription;
  late final StreamSubscription<web.CloseEvent> _closeSubscription;
  bool closed = false;

  Uint8List read(int maxBytes) {
    if (maxBytes <= 0 || _pending.isEmpty) {
      return Uint8List(0);
    }
    final count = _pending.length < maxBytes ? _pending.length : maxBytes;
    final out = Uint8List(count);
    for (var i = 0; i < count; i++) {
      out[i] = _pending.removeFirst();
    }
    return out;
  }

  void send(Uint8List data) {
    socket.send(data.toJS);
  }

  void close() {
    closed = true;
    _messageSubscription.cancel();
    _closeSubscription.cancel();
    socket.close();
  }
}

const int _errnoSuccess = 0;
const int _errnoAgain = 6;
const int _errnoBadf = 8;
const int _errnoInval = 28;
const int _errnoNosys = 52;
