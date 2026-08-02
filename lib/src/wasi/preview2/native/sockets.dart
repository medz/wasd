import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import '../io.dart';
import '../sockets.dart';

/// Dart VM-backed WASI 0.2 sockets host.
final class WASIPreview2NativeSocketsHost extends WASIPreview2SocketsHost {
  /// Creates a Preview2 sockets host backed by `dart:io`.
  WASIPreview2NativeSocketsHost({
    super.table,
    super.pollHost,
    super.streamsHost,
    WASIPreview2AddressResolver? resolveAddresses,
  }) : super(
         resolveAddresses: resolveAddresses ?? _resolveNativeAddresses,
         backend: _NativeSocketsBackend(),
       );
}

final class _NativeSocketsBackend
    implements WASIPreview2SocketsBackend, WASIPreview2SocketOptionsBackend {
  @override
  bool get supportsTcpSocketOptions => false;

  @override
  bool get supportsUdpSocketOptions => false;

  @override
  WASIPreview2SocketOperation<WASIPreview2IpSocketAddress> startTcpBind(
    WASIPreview2IpSocketAddress localAddress,
  ) {
    return WASIPreview2SocketOperation<WASIPreview2IpSocketAddress>.completed(
      const WASIPreview2SocketResult<WASIPreview2IpSocketAddress>.error(
        'not-supported',
      ),
    );
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2TcpConnection> startTcpConnect({
    required WASIPreview2IpSocketAddress remoteAddress,
    WASIPreview2IpSocketAddress? localAddress,
  }) {
    final future = _connect(remoteAddress, localAddress).then(
      (socket) => WASIPreview2SocketResult<WASIPreview2TcpConnection>.ok(
        _tcpConnection(socket),
      ),
      onError: (Object error) =>
          WASIPreview2SocketResult<WASIPreview2TcpConnection>.error(
            _socketErrorCode(error),
          ),
    );
    return WASIPreview2SocketOperation<WASIPreview2TcpConnection>.pending(
      future,
    );
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2TcpListener> startTcpListen({
    required WASIPreview2IpSocketAddress localAddress,
    required BigInt backlog,
  }) {
    final future =
        io.ServerSocket.bind(
          _internetAddress(localAddress),
          localAddress.port,
          backlog: _backlog(backlog),
        ).then(
          (server) => WASIPreview2SocketResult<WASIPreview2TcpListener>.ok(
            _NativeTcpListener(server),
          ),
          onError: (Object error) =>
              WASIPreview2SocketResult<WASIPreview2TcpListener>.error(
                _socketErrorCode(error),
              ),
        );
    return WASIPreview2SocketOperation<WASIPreview2TcpListener>.pending(future);
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2UdpBinding> startUdpBind(
    WASIPreview2IpSocketAddress localAddress,
  ) {
    final future =
        io.RawDatagramSocket.bind(
          _internetAddress(localAddress),
          localAddress.port,
        ).then(
          (socket) => WASIPreview2SocketResult<WASIPreview2UdpBinding>.ok(
            _NativeUdpBinding(socket),
          ),
          onError: (Object error) =>
              WASIPreview2SocketResult<WASIPreview2UdpBinding>.error(
                _socketErrorCode(error),
              ),
        );
    return WASIPreview2SocketOperation<WASIPreview2UdpBinding>.pending(future);
  }

  Future<io.Socket> _connect(
    WASIPreview2IpSocketAddress remoteAddress,
    WASIPreview2IpSocketAddress? localAddress,
  ) {
    if (localAddress == null) {
      return io.Socket.connect(
        _internetAddress(remoteAddress),
        remoteAddress.port,
      );
    }
    return io.Socket.connect(
      _internetAddress(remoteAddress),
      remoteAddress.port,
      sourceAddress: _internetAddress(localAddress),
      sourcePort: localAddress.port,
    );
  }
}

final class _NativeTcpListener implements WASIPreview2TcpListener {
  _NativeTcpListener(this._server)
    : localAddress = _socketAddress(_server.address, _server.port) {
    _subscription = _server.listen(
      (socket) {
        _queue.add(_tcpConnection(socket));
        _notify();
      },
      onError: (Object error) => _terminate(closeServer: true),
      onDone: _terminate,
      cancelOnError: false,
    );
  }

  final io.ServerSocket _server;
  late final StreamSubscription<io.Socket> _subscription;
  final List<WASIPreview2TcpConnection> _queue = [];
  final List<Completer<void>> _waiters = [];
  bool _closed = false;

  @override
  final WASIPreview2IpSocketAddress localAddress;

  @override
  bool get canAccept => _queue.isNotEmpty || _closed;

  @override
  Future<void> waitAccept() {
    if (canAccept) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  @override
  WASIPreview2SocketResult<WASIPreview2TcpConnection> accept() {
    if (_queue.isNotEmpty) {
      return WASIPreview2SocketResult<WASIPreview2TcpConnection>.ok(
        _queue.removeAt(0),
      );
    }
    return WASIPreview2SocketResult<WASIPreview2TcpConnection>.error(
      _closed ? 'connection-aborted' : 'would-block',
    );
  }

  @override
  void close() {
    _terminate(closeServer: true);
    for (final connection in _queue) {
      connection.dispose?.call();
    }
    _queue.clear();
  }

  void _terminate({bool closeServer = false}) {
    if (_closed) {
      return;
    }
    _closed = true;
    if (closeServer) {
      unawaited(_subscription.cancel());
      unawaited(_server.close());
    }
    _notify();
  }

  void _notify() {
    final waiters = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}

final class _NativeUdpBinding implements WASIPreview2UdpBinding {
  _NativeUdpBinding(this._socket)
    : localAddress = _socketAddress(_socket.address, _socket.port) {
    _subscription = _socket.listen((event) {
      if (event == io.RawSocketEvent.read) {
        while (true) {
          final received = _socket.receive();
          if (received == null) {
            break;
          }
          _queue.add(
            WASIPreview2IncomingDatagram(
              data: Uint8List.fromList(received.data),
              remoteAddress: _socketAddress(received.address, received.port),
            ),
          );
        }
        _notifyReceive();
      } else if (event == io.RawSocketEvent.write) {
        _sendReady = true;
        _notifySend();
      }
    });
  }

  final io.RawDatagramSocket _socket;
  late final StreamSubscription<io.RawSocketEvent> _subscription;
  final List<WASIPreview2IncomingDatagram> _queue = [];
  final List<Completer<void>> _receiveWaiters = [];
  final List<Completer<void>> _sendWaiters = [];
  bool _closed = false;
  bool _sendReady = true;

  @override
  final WASIPreview2IpSocketAddress localAddress;

  @override
  WASIPreview2IpSocketAddress? get remoteAddress => null;

  @override
  BigInt get sendCapacity => BigInt.from(64);

  @override
  bool get canReceive => _queue.isNotEmpty || _closed;

  @override
  bool get canSend => !_closed && _sendReady;

  @override
  Future<void> waitReceive() {
    if (canReceive) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _receiveWaiters.add(completer);
    return completer.future;
  }

  @override
  Future<void> waitSend() {
    if (canSend || _closed) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _sendWaiters.add(completer);
    return completer.future;
  }

  @override
  WASIPreview2SocketResult<List<WASIPreview2IncomingDatagram>> receive(
    BigInt maxResults,
  ) {
    if (_closed && _queue.isEmpty) {
      return const WASIPreview2SocketResult<
        List<WASIPreview2IncomingDatagram>
      >.error('invalid-state');
    }
    final count = maxResults < BigInt.from(_queue.length)
        ? maxResults.toInt()
        : _queue.length;
    final datagrams = _queue.sublist(0, count);
    _queue.removeRange(0, count);
    return WASIPreview2SocketResult<List<WASIPreview2IncomingDatagram>>.ok(
      datagrams,
    );
  }

  @override
  WASIPreview2SocketResult<BigInt> send(
    List<WASIPreview2OutgoingDatagram> datagrams,
  ) {
    if (_closed) {
      return const WASIPreview2SocketResult<BigInt>.error('invalid-state');
    }
    if (!_sendReady) {
      return WASIPreview2SocketResult<BigInt>.ok(BigInt.zero);
    }
    var sent = 0;
    for (final datagram in datagrams) {
      final remoteAddress = datagram.remoteAddress;
      if (remoteAddress == null) {
        return sent == 0
            ? const WASIPreview2SocketResult<BigInt>.error('remote-unreachable')
            : WASIPreview2SocketResult<BigInt>.ok(BigInt.from(sent));
      }
      final bytes = _socket.send(
        datagram.data,
        _internetAddress(remoteAddress),
        remoteAddress.port,
      );
      if (bytes == 0) {
        _sendReady = false;
        _socket.writeEventsEnabled = true;
        return WASIPreview2SocketResult<BigInt>.ok(BigInt.from(sent));
      }
      if (bytes != datagram.data.length) {
        return sent == 0
            ? const WASIPreview2SocketResult<BigInt>.error('datagram-too-large')
            : WASIPreview2SocketResult<BigInt>.ok(BigInt.from(sent));
      }
      sent++;
    }
    return WASIPreview2SocketResult<BigInt>.ok(BigInt.from(sent));
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _subscription.cancel();
    _socket.close();
    _notifyReceive();
    _notifySend();
  }

  void _notifyReceive() {
    final waiters = List<Completer<void>>.of(_receiveWaiters);
    _receiveWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  void _notifySend() {
    final waiters = List<Completer<void>>.of(_sendWaiters);
    _sendWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}

WASIPreview2TcpConnection _tcpConnection(io.Socket socket) {
  final input = WASIPreview2InputStream();
  var disposed = false;
  var receiveShutdown = false;
  var sendShutdown = false;
  Future<void>? sendClose;
  late final StreamSubscription<Uint8List> subscription;
  final output = WASIPreview2OutputStream(
    onWrite: (bytes) {
      if (disposed || sendShutdown) {
        return 'socket is closed';
      }
      try {
        socket.add(bytes);
        return null;
      } on Object catch (error) {
        return error.toString();
      }
    },
  );
  void dispose() {
    if (disposed) {
      return;
    }
    disposed = true;
    receiveShutdown = true;
    sendShutdown = true;
    output.close();
    input.close();
    subscription.cancel();
    socket.destroy();
  }

  Future<void> closeSend() => sendClose ??= (() async {
    try {
      await socket.flush();
    } on Object {
      // Closing still needs to run after a failed flush.
    }
    try {
      await socket.close();
    } on Object {
      // Socket shutdown is best-effort after the synchronous WASI result.
    }
  })();

  String? shutdown(String type) {
    if (disposed) {
      return 'invalid-state';
    }
    if (type == 'receive') {
      if (!receiveShutdown) {
        receiveShutdown = true;
        input.close();
        unawaited(subscription.cancel());
      }
      return null;
    }
    if (type == 'send') {
      if (!sendShutdown) {
        sendShutdown = true;
        output.close();
        unawaited(closeSend());
      }
      return null;
    }
    if (type == 'both') {
      receiveShutdown = true;
      sendShutdown = true;
      input.close();
      output.close();
      unawaited(closeSend().whenComplete(subscription.cancel));
      return null;
    }
    return 'invalid-argument';
  }

  subscription = socket.listen(
    (bytes) {
      if (!disposed && !receiveShutdown) {
        input.append(bytes);
      }
    },
    onError: (Object error) => input.fail(error.toString()),
    onDone: input.close,
    cancelOnError: false,
  );
  return WASIPreview2TcpConnection(
    inputStream: input,
    outputStream: output,
    localAddress: _socketAddress(socket.address, socket.port),
    remoteAddress: _socketAddress(socket.remoteAddress, socket.remotePort),
    shutdown: shutdown,
    dispose: dispose,
  );
}

Future<Iterable<WASIPreview2IpAddress>> _resolveNativeAddresses(
  String name,
) async {
  try {
    final addresses = await io.InternetAddress.lookup(name);
    return <WASIPreview2IpAddress>[
      for (final address in addresses) _socketAddress(address, 0).address,
    ];
  } on Object catch (error, stackTrace) {
    Error.throwWithStackTrace(
      WASIPreview2AddressResolverError(_resolverErrorCode(error)),
      stackTrace,
    );
  }
}

String _resolverErrorCode(Object error) {
  final message = error.toString().toLowerCase();
  if (message.contains('temporary failure') ||
      message.contains('try again') ||
      message.contains('eai_again')) {
    return 'temporary-resolver-failure';
  }
  if (message.contains('non-recoverable') ||
      message.contains('nonrecoverable') ||
      message.contains('permanent failure') ||
      message.contains('eai_fail')) {
    return 'permanent-resolver-failure';
  }
  if (message.contains('name or service not known') ||
      message.contains('nodename nor servname') ||
      message.contains('no address associated') ||
      message.contains('eai_noname') ||
      message.contains('eai_nodata') ||
      message.contains('eai_addrfamily')) {
    return 'name-unresolvable';
  }

  final osError = error is io.SocketException ? error.osError : null;
  final code = osError?.errorCode;
  if (code != null) {
    if (code == 11002 ||
        code == -3 ||
        ((io.Platform.isMacOS || io.Platform.isIOS) && code == 2)) {
      return 'temporary-resolver-failure';
    }
    if (code == 11003 ||
        code == -4 ||
        ((io.Platform.isMacOS || io.Platform.isIOS) && code == 4)) {
      return 'permanent-resolver-failure';
    }
    if (code == 11001 ||
        code == 11004 ||
        code == -2 ||
        code == -5 ||
        code == -9 ||
        ((io.Platform.isMacOS || io.Platform.isIOS) &&
            (code == 1 || code == 7 || code == 8))) {
      return 'name-unresolvable';
    }
  }
  return 'name-unresolvable';
}

io.InternetAddress _internetAddress(WASIPreview2IpSocketAddress address) {
  return io.InternetAddress(address.host);
}

WASIPreview2IpSocketAddress _socketAddress(
  io.InternetAddress address,
  int port,
) {
  final bytes = address.rawAddress;
  if (bytes.length == 4) {
    return WASIPreview2IpSocketAddress.ipv4(
      port: port,
      a: bytes[0],
      b: bytes[1],
      c: bytes[2],
      d: bytes[3],
    );
  }
  return WASIPreview2IpSocketAddress.ipv6(
    port: port,
    a: _u16(bytes, 0),
    b: _u16(bytes, 2),
    c: _u16(bytes, 4),
    d: _u16(bytes, 6),
    e: _u16(bytes, 8),
    f: _u16(bytes, 10),
    g: _u16(bytes, 12),
    h: _u16(bytes, 14),
  );
}

int _u16(List<int> bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _backlog(BigInt value) {
  if (value <= BigInt.zero) {
    return 0;
  }
  const maxBacklog = 0x7fffffff;
  return value > BigInt.from(maxBacklog) ? maxBacklog : value.toInt();
}

String _socketErrorCode(Object error) {
  final message = error.toString().toLowerCase();
  if (message.contains('refused')) {
    return 'connection-refused';
  }
  if (message.contains('address already in use')) {
    return 'address-in-use';
  }
  if (message.contains('permission') || message.contains('denied')) {
    return 'access-denied';
  }
  if (message.contains('timed out') || message.contains('timeout')) {
    return 'timeout';
  }
  if (message.contains('unreachable')) {
    return 'remote-unreachable';
  }
  return 'unknown';
}
