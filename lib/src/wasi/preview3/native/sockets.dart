import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;
import 'dart:typed_data';

import '../../component/async_values.dart';
import '../sockets.dart';

/// Dart VM-backed WASI 0.3 sockets host.
///
/// `dart:io` creates listeners and datagram sockets asynchronously. The stable
/// synchronous WIT `bind` and `listen` calls therefore start those operations;
/// a late bind failure closes the listener stream or is returned by the next
/// dependent asynchronous socket operation.
final class WASIPreview3NativeSocketsHost extends WASIPreview3SocketsHost {
  /// Creates a Preview3 sockets host backed by `dart:io`.
  WASIPreview3NativeSocketsHost({
    super.table,
    WASIPreview3AddressResolver? resolveAddresses,
  }) : super(
         resolveAddresses: resolveAddresses ?? _resolveNativeAddresses,
         backend: _NativeSocketsBackend(),
       );
}

final class _NativeSocketsBackend
    implements WASIPreview3SocketsBackend, WASIPreview3SocketOptionsBackend {
  static var _nextPort = 49152 + (io.pid % 16384);

  @override
  bool get supportsTcpSocketOptions => true;

  @override
  bool get supportsUdpSocketOptions => true;

  @override
  WASIPreview3SocketOperation<WASIPreview3IpSocketAddress> startTcpBind(
    WASIPreview3IpSocketAddress localAddress,
  ) {
    if (!_isBindableAddress(localAddress.address)) {
      return WASIPreview3SocketOperation<WASIPreview3IpSocketAddress>.completed(
        const WASIPreview3SocketResult<WASIPreview3IpSocketAddress>.error(
          'address-not-bindable',
        ),
      );
    }
    final effective = _ephemeralAddress(localAddress);
    return WASIPreview3SocketOperation<WASIPreview3IpSocketAddress>.completed(
      WASIPreview3SocketResult<WASIPreview3IpSocketAddress>.ok(effective),
    );
  }

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpConnection> startTcpConnect({
    required WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress,
  }) {
    try {
      final future = _connect(remoteAddress, localAddress).then(
        (socket) => WASIPreview3SocketResult<WASIPreview3TcpConnection>.ok(
          _tcpConnection(socket),
        ),
        onError: (Object error) =>
            WASIPreview3SocketResult<WASIPreview3TcpConnection>.error(
              _socketErrorCode(error),
            ),
      );
      return WASIPreview3SocketOperation<WASIPreview3TcpConnection>.pending(
        future,
        disposeValue: (connection) => connection.close(),
      );
    } on Object catch (error) {
      return WASIPreview3SocketOperation<WASIPreview3TcpConnection>.completed(
        WASIPreview3SocketResult<WASIPreview3TcpConnection>.error(
          _socketErrorCode(error),
        ),
      );
    }
  }

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpListener> startTcpListen({
    required WASIPreview3IpSocketAddress localAddress,
    required BigInt backlog,
  }) {
    try {
      if (!_isBindableAddress(localAddress.address)) {
        return WASIPreview3SocketOperation<WASIPreview3TcpListener>.completed(
          const WASIPreview3SocketResult<WASIPreview3TcpListener>.error(
            'address-not-bindable',
          ),
        );
      }
      final effective = _ephemeralAddress(localAddress);
      final listener = _DeferredNativeTcpListener(
        effective,
        io.ServerSocket.bind(
          _internetAddress(effective),
          effective.port,
          backlog: _backlog(backlog),
        ),
      );
      return WASIPreview3SocketOperation<WASIPreview3TcpListener>.completed(
        WASIPreview3SocketResult<WASIPreview3TcpListener>.ok(listener),
      );
    } on Object catch (error) {
      return WASIPreview3SocketOperation<WASIPreview3TcpListener>.completed(
        WASIPreview3SocketResult<WASIPreview3TcpListener>.error(
          _socketErrorCode(error),
        ),
      );
    }
  }

  @override
  WASIPreview3SocketOperation<WASIPreview3UdpBinding> startUdpBind(
    WASIPreview3IpSocketAddress localAddress,
  ) {
    try {
      if (!_isBindableAddress(localAddress.address)) {
        return WASIPreview3SocketOperation<WASIPreview3UdpBinding>.completed(
          const WASIPreview3SocketResult<WASIPreview3UdpBinding>.error(
            'address-not-bindable',
          ),
        );
      }
      final effective = _ephemeralAddress(localAddress);
      final binding = _DeferredNativeUdpBinding(
        effective,
        io.RawDatagramSocket.bind(_internetAddress(effective), effective.port),
      );
      return WASIPreview3SocketOperation<WASIPreview3UdpBinding>.completed(
        WASIPreview3SocketResult<WASIPreview3UdpBinding>.ok(binding),
      );
    } on Object catch (error) {
      return WASIPreview3SocketOperation<WASIPreview3UdpBinding>.completed(
        WASIPreview3SocketResult<WASIPreview3UdpBinding>.error(
          _socketErrorCode(error),
        ),
      );
    }
  }

  Future<io.Socket> _connect(
    WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress,
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

  WASIPreview3IpSocketAddress _ephemeralAddress(
    WASIPreview3IpSocketAddress address,
  ) {
    if (address.port != 0) return address;
    final port = _nextPort;
    _nextPort = _nextPort == 65535 ? 49152 : _nextPort + 1;
    return _withPort(address, port);
  }
}

final class _DeferredNativeTcpListener implements WASIPreview3TcpListener {
  _DeferredNativeTcpListener(this.localAddress, Future<io.ServerSocket> server)
    : _ready = server.then<WASIPreview3SocketResult<_NativeTcpListener>>(
        (value) => WASIPreview3SocketResult<_NativeTcpListener>.ok(
          _NativeTcpListener(value),
        ),
        onError: (Object error) =>
            WASIPreview3SocketResult<_NativeTcpListener>.error(
              _socketErrorCode(error),
            ),
      ) {
    _ready.then((result) {
      if (_closed) {
        result.value?.close();
        return;
      }
      _listener = result.value;
      _errorCode = result.errorCode;
    });
  }

  @override
  final WASIPreview3IpSocketAddress localAddress;

  final Future<WASIPreview3SocketResult<_NativeTcpListener>> _ready;
  _NativeTcpListener? _listener;
  String? _errorCode;
  bool _closed = false;

  @override
  bool get canAccept =>
      _closed || _errorCode != null || (_listener?.canAccept ?? false);

  @override
  Future<void> waitAccept() async {
    if (_closed) return;
    final result = await _ready;
    if (_closed || !result.isOk) return;
    await result.value!.waitAccept();
  }

  @override
  WASIPreview3SocketResult<WASIPreview3TcpConnection> accept() {
    if (_closed) {
      return const WASIPreview3SocketResult<WASIPreview3TcpConnection>.error(
        'connection-aborted',
      );
    }
    final listener = _listener;
    if (listener != null) return listener.accept();
    return WASIPreview3SocketResult<WASIPreview3TcpConnection>.error(
      _errorCode ?? 'would-block',
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _listener?.close();
  }
}

final class _NativeTcpListener implements WASIPreview3TcpListener {
  _NativeTcpListener(this._server)
    : localAddress = _socketAddress(_server.address, _server.port) {
    _subscription = _server.listen(
      (socket) {
        if (_closed) {
          socket.destroy();
          return;
        }
        _connections.add(_tcpConnection(socket));
        _notify();
      },
      onError: (Object _) => _terminate(closeServer: true),
      onDone: _terminate,
      cancelOnError: false,
    );
  }

  final io.ServerSocket _server;
  late final StreamSubscription<io.Socket> _subscription;
  final List<WASIPreview3TcpConnection> _connections =
      <WASIPreview3TcpConnection>[];
  final List<Completer<void>> _waiters = <Completer<void>>[];
  bool _closed = false;

  @override
  final WASIPreview3IpSocketAddress localAddress;

  @override
  bool get canAccept => _connections.isNotEmpty || _closed;

  @override
  Future<void> waitAccept() {
    if (canAccept) return Future<void>.value();
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  @override
  WASIPreview3SocketResult<WASIPreview3TcpConnection> accept() {
    if (_connections.isNotEmpty) {
      return WASIPreview3SocketResult<WASIPreview3TcpConnection>.ok(
        _connections.removeAt(0),
      );
    }
    return WASIPreview3SocketResult<WASIPreview3TcpConnection>.error(
      _closed ? 'connection-aborted' : 'would-block',
    );
  }

  @override
  void close() {
    _terminate(closeServer: true);
    for (final connection in _connections) {
      connection.close();
    }
    _connections.clear();
  }

  void _terminate({bool closeServer = false}) {
    if (_closed) return;
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
      if (!waiter.isCompleted) waiter.complete();
    }
  }
}

WASIPreview3TcpConnection _tcpConnection(io.Socket socket) {
  final incomingDone = Completer<WASIPreview3SocketResult<void>>();
  late final StreamSubscription<Uint8List> subscription;
  var closed = false;
  var receiveClosed = false;
  var sendClosed = false;

  void completeIncoming(WASIPreview3SocketResult<void> result) {
    if (!incomingDone.isCompleted) incomingDone.complete(result);
  }

  late final WASIComponentStream<int> incoming;
  void closeReceive() {
    if (closed || receiveClosed) return;
    receiveClosed = true;
    if (!incoming.writable.isClosed) incoming.writable.close();
    completeIncoming(const WASIPreview3SocketResult<void>.ok());
    unawaited(subscription.cancel());
  }

  incoming = WASIComponentStream<int>(
    'native-tcp-${socket.remoteAddress.address}:${socket.remotePort}',
    maxBufferedElements: 65536,
    onDrop: closeReceive,
  );

  subscription = socket.listen(
    (bytes) {
      if (closed || receiveClosed || incoming.writable.isClosed) return;
      subscription.pause();
      _writeAll(incoming.writable, bytes).then(
        (_) {
          if (!closed && !receiveClosed) subscription.resume();
        },
        onError: (Object _) {
          if (!closed && !receiveClosed) {
            closed = true;
            if (!incoming.writable.isClosed) incoming.writable.close();
            socket.destroy();
            completeIncoming(
              const WASIPreview3SocketResult<void>.error('connection-reset'),
            );
          }
        },
      );
    },
    onError: (Object error) {
      if (closed || receiveClosed) return;
      if (!incoming.writable.isClosed) incoming.writable.close();
      completeIncoming(
        WASIPreview3SocketResult<void>.error(_socketErrorCode(error)),
      );
    },
    onDone: () {
      if (closed || receiveClosed) return;
      if (!incoming.writable.isClosed) incoming.writable.close();
      completeIncoming(const WASIPreview3SocketResult<void>.ok());
    },
    cancelOnError: false,
  );

  Future<WASIPreview3SocketResult<void>> finishSend() async {
    if (closed || sendClosed) {
      return const WASIPreview3SocketResult<void>.error('invalid-state');
    }
    sendClosed = true;
    try {
      await socket.flush();
      // Socket.close() closes the IOSink/send half. The receive subscription
      // remains alive until the peer closes or the resource is destroyed.
      await socket.close();
      return const WASIPreview3SocketResult<void>.ok();
    } on Object catch (error) {
      return WASIPreview3SocketResult<void>.error(_socketErrorCode(error));
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    if (!incoming.writable.isClosed) incoming.writable.close();
    completeIncoming(
      const WASIPreview3SocketResult<void>.error('connection-aborted'),
    );
    unawaited(subscription.cancel());
    socket.destroy();
  }

  return WASIPreview3TcpConnection(
    incoming: incoming,
    incomingDone: incomingDone.future,
    write: (bytes) {
      if (closed || sendClosed) {
        return const WASIPreview3SocketResult<void>.error('connection-broken');
      }
      try {
        socket.add(bytes);
        return const WASIPreview3SocketResult<void>.ok();
      } on Object catch (error) {
        return WASIPreview3SocketResult<void>.error(_socketErrorCode(error));
      }
    },
    finishSend: finishSend,
    closeReceive: closeReceive,
    localAddress: _socketAddress(socket.address, socket.port),
    remoteAddress: _socketAddress(socket.remoteAddress, socket.remotePort),
    close: close,
  );
}

final class _DeferredNativeUdpBinding implements WASIPreview3UdpBinding {
  _DeferredNativeUdpBinding(
    this.localAddress,
    Future<io.RawDatagramSocket> socket,
  ) : _ready = socket.then<WASIPreview3SocketResult<_NativeUdpBinding>>(
        (value) => WASIPreview3SocketResult<_NativeUdpBinding>.ok(
          _NativeUdpBinding(value),
        ),
        onError: (Object error) =>
            WASIPreview3SocketResult<_NativeUdpBinding>.error(
              _socketErrorCode(error),
            ),
      ) {
    _ready.then((result) {
      if (_closed) {
        result.value?.close();
        return;
      }
      _binding = result.value;
    });
  }

  @override
  final WASIPreview3IpSocketAddress localAddress;

  final Future<WASIPreview3SocketResult<_NativeUdpBinding>> _ready;
  _NativeUdpBinding? _binding;
  bool _closed = false;

  @override
  Future<WASIPreview3SocketResult<void>> send(
    Uint8List data,
    WASIPreview3IpSocketAddress remoteAddress,
  ) async {
    if (_closed) {
      return const WASIPreview3SocketResult<void>.error('invalid-state');
    }
    final result = await _ready;
    if (_closed) {
      return const WASIPreview3SocketResult<void>.error('invalid-state');
    }
    if (!result.isOk) {
      return WASIPreview3SocketResult<void>.error(result.errorCode!);
    }
    return result.value!.send(data, remoteAddress);
  }

  @override
  Future<WASIPreview3SocketResult<WASIPreview3IncomingDatagram>>
  receive() async {
    if (_closed) {
      return const WASIPreview3SocketResult<WASIPreview3IncomingDatagram>.error(
        'invalid-state',
      );
    }
    final result = await _ready;
    if (_closed) {
      return const WASIPreview3SocketResult<WASIPreview3IncomingDatagram>.error(
        'invalid-state',
      );
    }
    if (!result.isOk) {
      return WASIPreview3SocketResult<WASIPreview3IncomingDatagram>.error(
        result.errorCode!,
      );
    }
    return result.value!.receive();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _binding?.close();
  }
}

final class _NativeUdpBinding implements WASIPreview3UdpBinding {
  _NativeUdpBinding(this._socket)
    : localAddress = _socketAddress(_socket.address, _socket.port) {
    _subscription = _socket.listen(
      (event) {
        if (event == io.RawSocketEvent.read) {
          while (_datagrams.length < _maxQueuedDatagrams) {
            final datagram = _socket.receive();
            if (datagram == null) break;
            _datagrams.addLast(
              WASIPreview3IncomingDatagram(
                data: Uint8List.fromList(datagram.data),
                remoteAddress: _socketAddress(datagram.address, datagram.port),
              ),
            );
          }
          if (_datagrams.length >= _maxQueuedDatagrams) {
            _receivePaused = true;
            _socket.readEventsEnabled = false;
          }
          _notifyReceive();
        } else if (event == io.RawSocketEvent.write) {
          _canSend = true;
          _notifySend();
        }
      },
      onError: (Object _) => _terminate(closeSocket: true),
      onDone: _terminate,
      cancelOnError: false,
    );
  }

  final io.RawDatagramSocket _socket;
  late final StreamSubscription<io.RawSocketEvent> _subscription;
  final ListQueue<WASIPreview3IncomingDatagram> _datagrams =
      ListQueue<WASIPreview3IncomingDatagram>();
  final List<Completer<void>> _receiveWaiters = <Completer<void>>[];
  final List<Completer<void>> _sendWaiters = <Completer<void>>[];
  bool _closed = false;
  bool _canSend = true;
  bool _receivePaused = false;

  static const int _maxQueuedDatagrams = 256;

  @override
  final WASIPreview3IpSocketAddress localAddress;

  @override
  Future<WASIPreview3SocketResult<void>> send(
    Uint8List data,
    WASIPreview3IpSocketAddress remoteAddress,
  ) async {
    if (_closed) {
      return const WASIPreview3SocketResult<void>.error('invalid-state');
    }
    while (!_closed) {
      if (!_canSend) await _waitSend();
      try {
        final written = _socket.send(
          data,
          _internetAddress(remoteAddress),
          remoteAddress.port,
        );
        if (written == data.length) {
          return const WASIPreview3SocketResult<void>.ok();
        }
        if (written == 0) {
          _canSend = false;
          _socket.writeEventsEnabled = true;
          continue;
        }
        return const WASIPreview3SocketResult<void>.error('datagram-too-large');
      } on Object catch (error) {
        return WASIPreview3SocketResult<void>.error(_socketErrorCode(error));
      }
    }
    return const WASIPreview3SocketResult<void>.error('invalid-state');
  }

  @override
  Future<WASIPreview3SocketResult<WASIPreview3IncomingDatagram>>
  receive() async {
    while (_datagrams.isEmpty && !_closed) {
      final waiter = Completer<void>();
      _receiveWaiters.add(waiter);
      await waiter.future;
    }
    if (_datagrams.isNotEmpty) {
      final datagram = _datagrams.removeFirst();
      if (_receivePaused && !_closed) {
        _receivePaused = false;
        _socket.readEventsEnabled = true;
      }
      return WASIPreview3SocketResult<WASIPreview3IncomingDatagram>.ok(
        datagram,
      );
    }
    return const WASIPreview3SocketResult<WASIPreview3IncomingDatagram>.error(
      'invalid-state',
    );
  }

  @override
  void close() {
    _terminate(closeSocket: true);
  }

  void _terminate({bool closeSocket = false}) {
    if (_closed) return;
    _closed = true;
    _datagrams.clear();
    if (closeSocket) {
      unawaited(_subscription.cancel());
      _socket.close();
    }
    _notifyReceive();
    _notifySend();
  }

  Future<void> _waitSend() {
    if (_canSend || _closed) return Future<void>.value();
    final waiter = Completer<void>();
    _sendWaiters.add(waiter);
    return waiter.future;
  }

  void _notifyReceive() {
    final waiters = List<Completer<void>>.of(_receiveWaiters);
    _receiveWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _notifySend() {
    final waiters = List<Completer<void>>.of(_sendWaiters);
    _sendWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }
}

Future<void> _writeAll(
  WASIComponentWritableStream<int> writable,
  List<int> values,
) async {
  var offset = 0;
  while (offset < values.length) {
    final written = await writable.writeWhenAvailable(values.sublist(offset));
    if (written <= 0) {
      throw StateError('WASI component stream write made no progress.');
    }
    offset += written;
  }
}

Future<Iterable<WASIPreview3IpAddress>> _resolveNativeAddresses(
  String name,
) async {
  try {
    final addresses = await io.InternetAddress.lookup(name);
    return <WASIPreview3IpAddress>[
      for (final address in addresses) _socketAddress(address, 0).address,
    ];
  } on Object catch (error, stackTrace) {
    Error.throwWithStackTrace(
      WASIPreview3AddressResolverError(_resolverErrorCode(error)),
      stackTrace,
    );
  }
}

io.InternetAddress _internetAddress(WASIPreview3IpSocketAddress address) {
  if (address.family == WASIPreview3IpAddressFamily.ipv6 &&
      address.scopeId != 0) {
    throw UnsupportedError('dart:io cannot preserve a numeric IPv6 scope id');
  }
  return io.InternetAddress(address.host);
}

bool _isBindableAddress(WASIPreview3IpAddress address) {
  final parts = address.parts;
  if (parts.every((part) => part == 0)) return true;
  if (address.family == WASIPreview3IpAddressFamily.ipv4) {
    return parts[0] == 127;
  }
  return parts.take(parts.length - 1).every((part) => part == 0) &&
      parts.last == 1;
}

WASIPreview3IpSocketAddress _withPort(
  WASIPreview3IpSocketAddress address,
  int port,
) {
  final parts = address.address.parts;
  return address.family == WASIPreview3IpAddressFamily.ipv4
      ? WASIPreview3IpSocketAddress.ipv4(
          port: port,
          a: parts[0],
          b: parts[1],
          c: parts[2],
          d: parts[3],
        )
      : WASIPreview3IpSocketAddress.ipv6(
          port: port,
          a: parts[0],
          b: parts[1],
          c: parts[2],
          d: parts[3],
          e: parts[4],
          f: parts[5],
          g: parts[6],
          h: parts[7],
          flowInfo: address.flowInfo,
          scopeId: address.scopeId,
        );
}

WASIPreview3IpSocketAddress _socketAddress(
  io.InternetAddress address,
  int port,
) {
  final bytes = address.rawAddress;
  if (bytes.length == 4) {
    return WASIPreview3IpSocketAddress.ipv4(
      port: port,
      a: bytes[0],
      b: bytes[1],
      c: bytes[2],
      d: bytes[3],
    );
  }
  return WASIPreview3IpSocketAddress.ipv6(
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
  const max = 0x7fffffff;
  return value > BigInt.from(max) ? max : value.toInt();
}

String _socketErrorCode(Object error) {
  if (error is UnsupportedError) return 'not-supported';
  final message = error.toString().toLowerCase();
  if (message.contains('refused')) return 'connection-refused';
  if (message.contains('address already in use')) return 'address-in-use';
  if (message.contains('permission') || message.contains('denied')) {
    return 'access-denied';
  }
  if (message.contains('timed out') || message.contains('timeout')) {
    return 'timeout';
  }
  if (message.contains('unreachable')) return 'remote-unreachable';
  if (message.contains('reset')) return 'connection-reset';
  if (message.contains('broken pipe')) return 'connection-broken';
  if (message.contains('aborted')) return 'connection-aborted';
  return 'other';
}

String _resolverErrorCode(Object error) {
  final message = error.toString().toLowerCase();
  if (message.contains('temporary failure') ||
      message.contains('try again') ||
      message.contains('eai_again')) {
    return 'temporary-resolver-failure';
  }
  if (message.contains('non-recoverable') ||
      message.contains('permanent failure') ||
      message.contains('eai_fail')) {
    return 'permanent-resolver-failure';
  }
  return 'name-unresolvable';
}
