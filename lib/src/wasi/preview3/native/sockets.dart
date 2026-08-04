import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;
import 'dart:typed_data';

import '../../component/async_values.dart';
import '../sockets.dart';
import 'socket_options.dart';

/// Dart VM-backed WASI 0.3 sockets host.
///
/// Synchronous WIT socket calls are exposed as pending Dart callbacks while
/// `dart:io` obtains the real OS endpoint. Explicit TCP bind is unsupported
/// because [io.ServerSocket.bind] starts listening before WASI `listen`.
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
  _NativeSocketsBackend()
    : _optionAbi = NativeSocketOptionAbi.forOperatingSystem(
        io.Platform.operatingSystem,
      );

  final Expando<io.Socket> _tcpSockets = Expando<io.Socket>();
  final NativeSocketOptionAbi? _optionAbi;

  @override
  bool get supportsTcpSocketOptions => _optionAbi != null;

  @override
  bool get supportsUdpSocketOptions => _optionAbi != null;

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpBinding> startTcpBind(
    WASIPreview3IpSocketAddress localAddress, {
    required BigInt backlog,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpBinding>.completed(
    const WASIPreview3SocketResult<WASIPreview3TcpBinding>.error(
      'not-supported',
    ),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpConnection> startTcpConnect({
    required WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress,
    WASIPreview3TcpBinding? binding,
  }) {
    try {
      final pending = _startConnect(
        remoteAddress,
        localAddress,
        binding: binding,
      );
      final future = pending.socket.then(
        (socket) => WASIPreview3SocketResult<WASIPreview3TcpConnection>.ok(
          _createTcpConnection(socket),
        ),
        onError: (Object error) =>
            WASIPreview3SocketResult<WASIPreview3TcpConnection>.error(
              _socketErrorCode(error),
            ),
      );
      return WASIPreview3SocketOperation<WASIPreview3TcpConnection>.pending(
        future,
        disposeValue: (connection) => connection.close(),
        cancel: pending.cancel,
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
    WASIPreview3TcpBinding? binding,
  }) {
    try {
      if (binding != null) {
        binding.close();
        return WASIPreview3SocketOperation<WASIPreview3TcpListener>.completed(
          const WASIPreview3SocketResult<WASIPreview3TcpListener>.error(
            'invalid-state',
          ),
        );
      }
      final future =
          io.ServerSocket.bind(
            _internetAddress(localAddress),
            localAddress.port,
            backlog: _backlog(backlog),
            v6Only: localAddress.family == WASIPreview3IpAddressFamily.ipv6,
          ).then<WASIPreview3SocketResult<WASIPreview3TcpListener>>(
            (server) => WASIPreview3SocketResult<WASIPreview3TcpListener>.ok(
              _createTcpListener(server, backlog),
            ),
            onError: (Object error) =>
                WASIPreview3SocketResult<WASIPreview3TcpListener>.error(
                  _socketErrorCode(error),
                ),
          );
      return WASIPreview3SocketOperation<WASIPreview3TcpListener>.pending(
        future,
        disposeValue: (listener) => listener.close(),
      );
    } on Object catch (error) {
      binding?.close();
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
      final future =
          io.RawDatagramSocket.bind(
            _internetAddress(localAddress),
            localAddress.port,
          ).then<WASIPreview3SocketResult<WASIPreview3UdpBinding>>(
            (socket) => WASIPreview3SocketResult<WASIPreview3UdpBinding>.ok(
              _NativeUdpBinding(socket),
            ),
            onError: (Object error) =>
                WASIPreview3SocketResult<WASIPreview3UdpBinding>.error(
                  _socketErrorCode(error),
                ),
          );
      return WASIPreview3SocketOperation<WASIPreview3UdpBinding>.pending(
        future,
        disposeValue: (binding) => binding.close(),
      );
    } on Object catch (error) {
      return WASIPreview3SocketOperation<WASIPreview3UdpBinding>.completed(
        WASIPreview3SocketResult<WASIPreview3UdpBinding>.error(
          _socketErrorCode(error),
        ),
      );
    }
  }

  ({Future<io.Socket> socket, void Function() cancel}) _startConnect(
    WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress, {
    WASIPreview3TcpBinding? binding,
  }) {
    io.ConnectionTask<io.Socket>? task;
    var cancelled = false;
    final pending = () async {
      binding?.close();
      if (cancelled) throw const io.SocketException('cancelled');
      final started = await io.Socket.startConnect(
        _internetAddress(remoteAddress),
        remoteAddress.port,
        sourceAddress: localAddress == null
            ? null
            : _internetAddress(localAddress),
        sourcePort: localAddress?.port ?? 0,
      );
      task = started;
      if (cancelled) started.cancel();
      return started.socket;
    }();
    return (
      socket: pending,
      cancel: () {
        if (cancelled) return;
        cancelled = true;
        task?.cancel();
      },
    );
  }

  WASIPreview3TcpListener _createTcpListener(
    io.ServerSocket server,
    BigInt backlog,
  ) {
    try {
      return _NativeTcpListener(
        server,
        maxQueuedConnections: _backlog(backlog),
        createConnection: _createTcpConnection,
        applyOptions: _applyTcpOptionsToConnection,
      );
    } on Object {
      unawaited(server.close());
      rethrow;
    }
  }

  WASIPreview3TcpConnection _createTcpConnection(io.Socket socket) {
    try {
      final connection = _tcpConnection(socket);
      _tcpSockets[connection] = socket;
      return connection;
    } on Object {
      socket.destroy();
      rethrow;
    }
  }

  void _applyTcpOptionsToConnection(
    WASIPreview3TcpConnection connection,
    WASIPreview3TcpSocketOptions options,
  ) {
    final socket = _tcpSockets[connection];
    if (socket == null) throw StateError('Unknown native TCP connection.');
    final abi = _optionAbi;
    if (abi == null) throw UnsupportedError('Unsupported socket option ABI.');
    applyNativeTcpSocketOptions(
      socket,
      connection.localAddress.family,
      options,
      abi,
    );
  }

  @override
  String? applyTcpSocketOptions({
    required WASIPreview3TcpSocketOptions options,
    WASIPreview3TcpConnection? connection,
    WASIPreview3TcpListener? listener,
  }) {
    if (_optionAbi == null) return 'not-supported';
    try {
      if (connection != null) {
        _applyTcpOptionsToConnection(connection, options);
      }
      if (listener case final _NativeTcpListener nativeListener) {
        nativeListener.applyOptions(options);
      }
      return null;
    } on Object catch (error) {
      return _socketErrorCode(error);
    }
  }

  @override
  String? applyUdpSocketOptions({
    required WASIPreview3UdpSocketOptions options,
    WASIPreview3UdpBinding? binding,
  }) {
    final abi = _optionAbi;
    if (abi == null) return 'not-supported';
    try {
      if (binding case final _NativeUdpBinding nativeBinding) {
        nativeBinding.applyOptions(options, abi);
      }
      return null;
    } on Object catch (error) {
      return _socketErrorCode(error);
    }
  }
}

final class _NativeTcpListener implements WASIPreview3TcpListener {
  _NativeTcpListener(
    this._server, {
    required int maxQueuedConnections,
    required WASIPreview3TcpConnection Function(io.Socket socket)
    createConnection,
    required void Function(
      WASIPreview3TcpConnection connection,
      WASIPreview3TcpSocketOptions options,
    )
    applyOptions,
  }) : _createConnection = createConnection,
       _applyOptions = applyOptions,
       _maxQueuedConnections = maxQueuedConnections < 1
           ? 1
           : maxQueuedConnections,
       localAddress = _socketAddress(_server.address, _server.port) {
    _subscription = _server.listen(
      (socket) {
        if (_closed) {
          socket.destroy();
          return;
        }
        final connection = _createConnection(socket);
        final options = _options;
        if (options != null) {
          try {
            _applyOptions(connection, options);
          } on Object {
            connection.close();
            return;
          }
        }
        _connections.add(connection);
        if (_connections.length >= _maxQueuedConnections &&
            !_subscription.isPaused) {
          _subscription.pause();
        }
        _notify();
      },
      onError: (Object _) => _terminate(closeServer: true),
      onDone: _terminate,
      cancelOnError: false,
    );
  }

  final io.ServerSocket _server;
  final WASIPreview3TcpConnection Function(io.Socket socket) _createConnection;
  final void Function(
    WASIPreview3TcpConnection connection,
    WASIPreview3TcpSocketOptions options,
  )
  _applyOptions;
  final int _maxQueuedConnections;
  late final StreamSubscription<io.Socket> _subscription;
  final List<WASIPreview3TcpConnection> _connections =
      <WASIPreview3TcpConnection>[];
  final List<Completer<void>> _waiters = <Completer<void>>[];
  WASIPreview3TcpSocketOptions? _options;
  bool _closed = false;

  @override
  final WASIPreview3IpSocketAddress localAddress;

  void applyOptions(WASIPreview3TcpSocketOptions options) {
    for (final connection in _connections) {
      _applyOptions(connection, options);
    }
    _options = options;
  }

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
      final connection = _connections.removeAt(0);
      if (_subscription.isPaused && !_closed) {
        _subscription.resume();
      }
      return WASIPreview3SocketResult<WASIPreview3TcpConnection>.ok(connection);
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
    write: (bytes) async {
      if (closed || sendClosed) {
        return const WASIPreview3SocketResult<void>.error('connection-broken');
      }
      try {
        socket.add(bytes);
        await socket.flush();
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

final class _NativeUdpBinding
    implements WASIPreview3UdpBinding, WASIPreview3UdpBindingLifecycle {
  _NativeUdpBinding(this._socket)
    : localAddress = _socketAddress(_socket.address, _socket.port) {
    _subscription = _socket.listen(
      (event) {
        if (event == io.RawSocketEvent.read) {
          while (_datagrams.length < _maxQueuedDatagrams) {
            final datagram = _socket.receive();
            if (datagram == null) break;
            if (!_matchesAddressFamily(datagram.address, localAddress.family)) {
              continue;
            }
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
  bool get isClosed => _closed;

  @override
  final WASIPreview3IpSocketAddress localAddress;

  void applyOptions(
    WASIPreview3UdpSocketOptions options,
    NativeSocketOptionAbi abi,
  ) {
    applyNativeUdpSocketOptions(_socket, localAddress.family, options, abi);
  }

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
      (address.flowInfo != 0 || address.scopeId != 0)) {
    throw UnsupportedError(
      'dart:io cannot preserve IPv6 flow info or a numeric scope id',
    );
  }
  return io.InternetAddress(address.host);
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

bool _matchesAddressFamily(
  io.InternetAddress address,
  WASIPreview3IpAddressFamily family,
) {
  final bytes = address.rawAddress;
  if (family == WASIPreview3IpAddressFamily.ipv4) return bytes.length == 4;
  if (bytes.length != 16) return false;
  for (var index = 0; index < 10; index++) {
    if (bytes[index] != 0) return true;
  }
  return bytes[10] != 0xff || bytes[11] != 0xff;
}

int _u16(List<int> bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _backlog(BigInt value) {
  return value > BigInt.from(_maxTcpBacklog) ? _maxTcpBacklog : value.toInt();
}

const int _maxTcpBacklog = 4096;

String _socketErrorCode(Object error) {
  if (error is UnsupportedError) return 'not-supported';
  if (error is ArgumentError) return 'invalid-argument';
  if (error is io.SocketException) {
    return _socketErrnoCode(error.osError?.errorCode) ?? 'other';
  }
  if (error is io.OSError) {
    return _socketErrnoCode(error.errorCode) ?? 'other';
  }
  return 'other';
}

String _resolverErrorCode(Object error) {
  if (error is io.SocketException) {
    final code = error.osError?.errorCode;
    if (io.Platform.isWindows) {
      return switch (code) {
        11002 => 'temporary-resolver-failure',
        11003 => 'permanent-resolver-failure',
        11001 || 11004 => 'name-unresolvable',
        10013 => 'access-denied',
        _ => 'name-unresolvable',
      };
    }
    if (io.Platform.isMacOS || io.Platform.isIOS) {
      return switch (code) {
        2 => 'temporary-resolver-failure',
        4 => 'permanent-resolver-failure',
        8 => 'name-unresolvable',
        _ => 'name-unresolvable',
      };
    }
    return switch (code) {
      -3 => 'temporary-resolver-failure',
      -4 => 'permanent-resolver-failure',
      -2 || -5 => 'name-unresolvable',
      13 => 'access-denied',
      _ => 'name-unresolvable',
    };
  }
  return 'name-unresolvable';
}

String? _socketErrnoCode(int? code) {
  if (code == null) return null;
  if (io.Platform.isWindows) {
    return switch (code) {
      10013 => 'access-denied',
      10022 => 'invalid-argument',
      10045 => 'not-supported',
      10048 => 'address-in-use',
      10049 => 'address-not-bindable',
      10050 || 10051 || 10065 => 'remote-unreachable',
      10053 => 'connection-aborted',
      10054 => 'connection-reset',
      10055 => 'out-of-memory',
      10060 => 'timeout',
      10061 => 'connection-refused',
      _ => null,
    };
  }
  final darwin = io.Platform.isMacOS || io.Platform.isIOS;
  if (darwin) {
    return switch (code) {
      12 => 'out-of-memory',
      1 || 13 => 'access-denied',
      22 => 'invalid-argument',
      32 => 'connection-broken',
      45 => 'not-supported',
      48 => 'address-in-use',
      49 => 'address-not-bindable',
      51 || 65 => 'remote-unreachable',
      53 => 'connection-aborted',
      54 => 'connection-reset',
      60 => 'timeout',
      61 => 'connection-refused',
      _ => null,
    };
  }
  return switch (code) {
    12 => 'out-of-memory',
    1 || 13 => 'access-denied',
    22 => 'invalid-argument',
    32 => 'connection-broken',
    95 => 'not-supported',
    98 => 'address-in-use',
    99 => 'address-not-bindable',
    101 || 113 => 'remote-unreachable',
    103 => 'connection-aborted',
    104 => 'connection-reset',
    110 => 'timeout',
    111 => 'connection-refused',
    _ => null,
  };
}
