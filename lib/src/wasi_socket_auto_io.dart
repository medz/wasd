import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'wasi_socket_transport.dart';

WasiSocketTransport createAutoWasiSocketTransport({
  Map<int, Object> preopenedSockets = const {},
}) {
  return _IoSocketTransport(preopenedSockets: preopenedSockets).transport;
}

const bool autoHostSocketSupported = true;

final class _IoSocketTransport {
  _IoSocketTransport({required Map<int, Object> preopenedSockets}) {
    for (final entry in preopenedSockets.entries) {
      final value = entry.value;
      if (value is RawServerSocket) {
        _listeners[entry.key] = _IoListenerSocket(value);
      } else if (value is RawSocket) {
        _streams[entry.key] = _IoStreamSocket(value);
      }
    }
  }

  final Map<int, _IoListenerSocket> _listeners = <int, _IoListenerSocket>{};
  final Map<int, _IoStreamSocket> _streams = <int, _IoStreamSocket>{};

  WasiSocketTransport get transport => WasiSocketTransport(
    accept: _accept,
    recv: _recv,
    send: _send,
    shutdown: _shutdown,
    close: _close,
    containsFd: _containsFd,
  );

  bool _containsFd({required int fd}) {
    return _listeners.containsKey(fd) || _streams.containsKey(fd);
  }

  WasiSockAcceptResult _accept({
    required int fd,
    required int flags,
    required WasiSockAllocateFd allocateFd,
  }) {
    final listener = _listeners[fd];
    if (listener == null) {
      return const WasiSockAcceptResult.error(_errnoBadf);
    }
    final accepted = listener.accept();
    if (accepted == null) {
      return const WasiSockAcceptResult.error(_errnoAgain);
    }
    final acceptedFd = allocateFd();
    _streams[acceptedFd] = _IoStreamSocket(accepted);
    return WasiSockAcceptResult.accepted(acceptedFd);
  }

  WasiSockRecvResult _recv({
    required int fd,
    required int flags,
    required int maxBytes,
  }) {
    final socket = _streams[fd];
    if (socket == null) {
      return const WasiSockRecvResult.error(_errnoBadf);
    }
    if (maxBytes < 0) {
      return const WasiSockRecvResult.error(_errnoInval);
    }
    if (maxBytes == 0) {
      return WasiSockRecvResult.received(Uint8List(0));
    }

    final bytes = socket.read(maxBytes);
    if (bytes.isEmpty && !socket.readClosed) {
      return const WasiSockRecvResult.error(_errnoAgain);
    }
    return WasiSockRecvResult.received(bytes);
  }

  WasiSockSendResult _send({
    required int fd,
    required int flags,
    required Uint8List data,
  }) {
    final socket = _streams[fd];
    if (socket == null) {
      return const WasiSockSendResult.error(_errnoBadf);
    }
    if (data.isEmpty) {
      return const WasiSockSendResult.sent(0);
    }

    final written = socket.write(data);
    if (written == 0) {
      return const WasiSockSendResult.error(_errnoAgain);
    }
    return WasiSockSendResult.sent(written);
  }

  int? _shutdown({required int fd, required int how}) {
    final socket = _streams[fd];
    if (socket == null) {
      return _errnoBadf;
    }
    return socket.shutdown(how);
  }

  int? _close({required int fd}) {
    final stream = _streams.remove(fd);
    if (stream != null) {
      stream.close();
      return _errnoSuccess;
    }
    final listener = _listeners.remove(fd);
    if (listener != null) {
      listener.close();
      return _errnoSuccess;
    }
    return null;
  }
}

final class _IoListenerSocket {
  _IoListenerSocket(this.socket) {
    _subscription = socket.listen(
      (client) => _pending.addLast(client),
      onDone: () => _closed = true,
      onError: (_, _) => _closed = true,
    );
  }

  final RawServerSocket socket;
  final Queue<RawSocket> _pending = Queue<RawSocket>();
  late final StreamSubscription<RawSocket> _subscription;
  bool _closed = false;

  RawSocket? accept() {
    if (_pending.isNotEmpty) {
      return _pending.removeFirst();
    }
    if (_closed) {
      return null;
    }
    return null;
  }

  void close() {
    _subscription.cancel();
    socket.close();
    while (_pending.isNotEmpty) {
      _pending.removeFirst().close();
    }
    _closed = true;
  }
}

final class _IoStreamSocket {
  _IoStreamSocket(this.socket) {
    socket.readEventsEnabled = true;
    socket.writeEventsEnabled = true;
    _subscription = socket.listen(
      _onEvent,
      onDone: () => _readClosed = true,
      onError: (_, _) => _readClosed = true,
    );
  }

  final RawSocket socket;
  final Queue<int> _pendingBytes = Queue<int>();
  late final StreamSubscription<RawSocketEvent> _subscription;
  bool _readClosed = false;

  bool get readClosed => _readClosed;

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        while (true) {
          final chunk = socket.read();
          if (chunk == null || chunk.isEmpty) {
            break;
          }
          _pendingBytes.addAll(chunk);
        }
      case RawSocketEvent.readClosed:
        _readClosed = true;
      case RawSocketEvent.closed:
        _readClosed = true;
      case RawSocketEvent.write:
        break;
    }
  }

  Uint8List read(int maxBytes) {
    if (maxBytes <= 0 || _pendingBytes.isEmpty) {
      return Uint8List(0);
    }
    final count = _pendingBytes.length < maxBytes
        ? _pendingBytes.length
        : maxBytes;
    final out = Uint8List(count);
    for (var i = 0; i < count; i++) {
      out[i] = _pendingBytes.removeFirst();
    }
    return out;
  }

  int write(Uint8List data) {
    if (data.isEmpty) {
      return 0;
    }
    var offset = 0;
    while (offset < data.length) {
      final written = socket.write(data, offset, data.length - offset);
      if (written <= 0) {
        break;
      }
      offset += written;
    }
    return offset;
  }

  int shutdown(int how) {
    switch (how) {
      case 0:
        socket.shutdown(SocketDirection.receive);
        return _errnoSuccess;
      case 1:
        socket.shutdown(SocketDirection.send);
        return _errnoSuccess;
      case 2:
        socket.shutdown(SocketDirection.both);
        return _errnoSuccess;
      default:
        return _errnoInval;
    }
  }

  void close() {
    _subscription.cancel();
    socket.close();
    _readClosed = true;
  }
}

const int _errnoSuccess = 0;
const int _errnoAgain = 6;
const int _errnoBadf = 8;
const int _errnoInval = 28;
