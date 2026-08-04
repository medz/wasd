import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/async_values.dart';
import '../component/resource_table.dart';
import '../component/wit_adapter.dart';

/// IP address family used by WASI 0.3 sockets.
enum WASIPreview3IpAddressFamily {
  /// Internet Protocol version 4.
  ipv4,

  /// Internet Protocol version 6.
  ipv6,
}

/// An IPv4 or IPv6 address used by WASI 0.3 sockets.
final class WASIPreview3IpAddress {
  /// Creates an IPv4 address.
  WASIPreview3IpAddress.ipv4(int a, int b, int c, int d)
    : family = WASIPreview3IpAddressFamily.ipv4,
      _parts = List<int>.unmodifiable(<int>[
        _part(a, 0xff, 'a'),
        _part(b, 0xff, 'b'),
        _part(c, 0xff, 'c'),
        _part(d, 0xff, 'd'),
      ]);

  /// Creates an IPv6 address from eight 16-bit segments.
  WASIPreview3IpAddress.ipv6(
    int a,
    int b,
    int c,
    int d,
    int e,
    int f,
    int g,
    int h,
  ) : family = WASIPreview3IpAddressFamily.ipv6,
      _parts = List<int>.unmodifiable(<int>[
        _part(a, 0xffff, 'a'),
        _part(b, 0xffff, 'b'),
        _part(c, 0xffff, 'c'),
        _part(d, 0xffff, 'd'),
        _part(e, 0xffff, 'e'),
        _part(f, 0xffff, 'f'),
        _part(g, 0xffff, 'g'),
        _part(h, 0xffff, 'h'),
      ]);

  WASIPreview3IpAddress._(this.family, Iterable<int> parts)
    : _parts = List<int>.unmodifiable(parts);

  /// Address family.
  final WASIPreview3IpAddressFamily family;

  final List<int> _parts;

  /// Four IPv4 octets or eight IPv6 16-bit segments.
  List<int> get parts => _parts;

  /// Text accepted by Dart networking APIs.
  String get host => family == WASIPreview3IpAddressFamily.ipv4
      ? _parts.join('.')
      : _parts.map((part) => part.toRadixString(16)).join(':');

  @override
  bool operator ==(Object other) =>
      other is WASIPreview3IpAddress &&
      family == other.family &&
      _listEquals(_parts, other._parts);

  @override
  int get hashCode => Object.hash(family, Object.hashAll(_parts));

  @override
  String toString() => host;

  /// Parses an IPv4 or IPv6 literal without performing DNS resolution.
  static WASIPreview3IpAddress? parse(String value) =>
      _parseIpv4(value) ?? _parseIpv6(value);
}

/// IP endpoint used by WASI 0.3 TCP and UDP sockets.
final class WASIPreview3IpSocketAddress {
  /// Creates an IPv4 socket address.
  WASIPreview3IpSocketAddress.ipv4({
    required int port,
    required int a,
    required int b,
    required int c,
    required int d,
  }) : this._(
         address: WASIPreview3IpAddress.ipv4(a, b, c, d),
         port: _part(port, 0xffff, 'port'),
         flowInfo: 0,
         scopeId: 0,
       );

  /// Creates an IPv6 socket address.
  WASIPreview3IpSocketAddress.ipv6({
    required int port,
    required int a,
    required int b,
    required int c,
    required int d,
    required int e,
    required int f,
    required int g,
    required int h,
    int flowInfo = 0,
    int scopeId = 0,
  }) : this._(
         address: WASIPreview3IpAddress.ipv6(a, b, c, d, e, f, g, h),
         port: _part(port, 0xffff, 'port'),
         flowInfo: _part(flowInfo, 0xffffffff, 'flowInfo'),
         scopeId: _part(scopeId, 0xffffffff, 'scopeId'),
       );

  WASIPreview3IpSocketAddress._({
    required this.address,
    required this.port,
    required this.flowInfo,
    required this.scopeId,
  });

  /// IP address.
  final WASIPreview3IpAddress address;

  /// TCP or UDP port.
  final int port;

  /// IPv6 flow information, or zero for IPv4.
  final int flowInfo;

  /// IPv6 scope identifier, or zero for IPv4.
  final int scopeId;

  /// Address family.
  WASIPreview3IpAddressFamily get family => address.family;

  /// Host text accepted by Dart networking APIs.
  String get host => address.host;

  @override
  bool operator ==(Object other) =>
      other is WASIPreview3IpSocketAddress &&
      address == other.address &&
      port == other.port &&
      flowInfo == other.flowInfo &&
      scopeId == other.scopeId;

  @override
  int get hashCode => Object.hash(address, port, flowInfo, scopeId);

  @override
  String toString() => family == WASIPreview3IpAddressFamily.ipv4
      ? '$host:$port'
      : '[$host]:$port';
}

/// Result returned by a Preview3 sockets backend operation.
final class WASIPreview3SocketResult<T> {
  /// Successful operation.
  const WASIPreview3SocketResult.ok([this.value]) : errorCode = null;

  /// Failed operation with a stable `wasi:sockets` error label.
  const WASIPreview3SocketResult.error(this.errorCode) : value = null;

  /// Success payload.
  final T? value;

  /// WIT error variant label on failure.
  final String? errorCode;

  /// Whether this result is successful.
  bool get isOk => errorCode == null;
}

/// A possibly pending backend operation.
final class WASIPreview3SocketOperation<T> {
  /// Creates an already completed operation.
  WASIPreview3SocketOperation.completed(WASIPreview3SocketResult<T> result)
    : _future = Future<WASIPreview3SocketResult<T>>.value(result),
      _result = result,
      _disposeValue = null,
      _cancel = null;

  /// Creates a pending operation.
  WASIPreview3SocketOperation.pending(
    Future<WASIPreview3SocketResult<T>> future, {
    void Function(T value)? disposeValue,
    void Function()? cancel,
  }) : _future = future.then<WASIPreview3SocketResult<T>>(
         (result) => result,
         onError: (Object _, StackTrace _) =>
             WASIPreview3SocketResult<T>.error('other'),
       ),
       _disposeValue = disposeValue,
       _cancel = cancel {
    unawaited(
      _future.then<void>((result) {
        _result = result;
        if (_disposed) {
          _dispose(result);
        }
      }),
    );
  }

  final Future<WASIPreview3SocketResult<T>> _future;
  WASIPreview3SocketResult<T>? _result;
  final void Function(T value)? _disposeValue;
  final void Function()? _cancel;
  void Function(T value)? _fallbackDisposeValue;
  bool _disposed = false;
  bool _cancelled = false;
  bool _valueDisposed = false;

  /// Completed result, or null while pending.
  WASIPreview3SocketResult<T>? get resultOrNull => _result;

  /// Completes with the operation result.
  Future<WASIPreview3SocketResult<T>> wait() => _future;

  /// Releases a late success value after the owning socket was dropped.
  void dispose({void Function(T value)? disposeValue}) {
    _fallbackDisposeValue ??= disposeValue;
    if (!_disposed && _result == null && !_cancelled) {
      _cancelled = true;
      _cancel?.call();
    }
    _disposed = true;
    final result = _result;
    if (result != null) _dispose(result);
  }

  void _dispose(WASIPreview3SocketResult<T> result) {
    if (_valueDisposed) return;
    final value = result.value;
    final disposeValue = _disposeValue ?? _fallbackDisposeValue;
    if (value == null || disposeValue == null) return;
    _valueDisposed = true;
    _result = null;
    disposeValue(value);
  }
}

/// OS-backed reservation created by `tcp-socket.bind`.
///
/// A backend consumes this reservation when starting `listen` or a bound
/// `connect`. Dropping the owning socket closes an unconsumed reservation.
abstract interface class WASIPreview3TcpBinding {
  /// Address selected by the operating system, including an ephemeral port.
  WASIPreview3IpSocketAddress get localAddress;

  /// Releases the reserved endpoint.
  void close();
}

/// Effective TCP socket options supplied to a native endpoint.
final class WASIPreview3TcpSocketOptions {
  /// Creates an immutable TCP option snapshot.
  const WASIPreview3TcpSocketOptions({
    required this.keepAliveEnabled,
    required this.keepAliveIdle,
    required this.keepAliveInterval,
    required this.keepAliveCount,
    required this.hopLimit,
    required this.receiveBufferSize,
    required this.sendBufferSize,
  });

  /// Whether TCP keepalive is enabled.
  final bool keepAliveEnabled;

  /// Keepalive idle duration in nanoseconds.
  final BigInt keepAliveIdle;

  /// Keepalive interval in nanoseconds.
  final BigInt keepAliveInterval;

  /// Number of failed probes before termination.
  final int keepAliveCount;

  /// IPv4 TTL or IPv6 unicast hop limit.
  final int hopLimit;

  /// Requested receive buffer size.
  final BigInt receiveBufferSize;

  /// Requested send buffer size.
  final BigInt sendBufferSize;
}

/// Effective UDP socket options supplied to a native endpoint.
final class WASIPreview3UdpSocketOptions {
  /// Creates an immutable UDP option snapshot.
  const WASIPreview3UdpSocketOptions({
    required this.hopLimit,
    required this.receiveBufferSize,
    required this.sendBufferSize,
  });

  /// IPv4 TTL or IPv6 unicast hop limit.
  final int hopLimit;

  /// Requested receive buffer size.
  final BigInt receiveBufferSize;

  /// Requested send buffer size.
  final BigInt sendBufferSize;
}

/// Writes one TCP chunk to a connected peer.
typedef WASIPreview3TcpWrite =
    FutureOr<WASIPreview3SocketResult<void>> Function(Uint8List bytes);

/// Finishes the TCP send half after the guest closes its input stream.
typedef WASIPreview3TcpFinishSend =
    FutureOr<WASIPreview3SocketResult<void>> Function();

/// Connected TCP I/O returned by a sockets backend.
final class WASIPreview3TcpConnection {
  /// Creates connected TCP I/O.
  const WASIPreview3TcpConnection({
    required this.incoming,
    required this.incomingDone,
    required this.write,
    required this.finishSend,
    required this.closeReceive,
    required this.localAddress,
    required this.remoteAddress,
    required this.close,
  });

  /// Bytes received from the peer.
  final WASIComponentStream<int> incoming;

  /// Terminal result for [incoming].
  final Future<WASIPreview3SocketResult<void>> incomingDone;

  /// Writes one bounded chunk.
  final WASIPreview3TcpWrite write;

  /// Flushes and half-closes the send direction.
  final WASIPreview3TcpFinishSend finishSend;

  /// Closes the receive direction while preserving the send direction.
  final void Function() closeReceive;

  /// Bound local address.
  final WASIPreview3IpSocketAddress localAddress;

  /// Connected peer address.
  final WASIPreview3IpSocketAddress remoteAddress;

  /// Releases the connection.
  final void Function() close;
}

/// Listening TCP socket returned by a sockets backend.
abstract interface class WASIPreview3TcpListener {
  /// Bound local address.
  WASIPreview3IpSocketAddress get localAddress;

  /// Whether [accept] can make progress without waiting.
  bool get canAccept;

  /// Waits until [accept] may make progress.
  Future<void> waitAccept();

  /// Accepts one queued connection.
  WASIPreview3SocketResult<WASIPreview3TcpConnection> accept();

  /// Closes the listener.
  void close();
}

/// Incoming UDP datagram.
final class WASIPreview3IncomingDatagram {
  /// Creates an incoming datagram.
  const WASIPreview3IncomingDatagram({
    required this.data,
    required this.remoteAddress,
  });

  /// Payload bytes.
  final Uint8List data;

  /// Sender address.
  final WASIPreview3IpSocketAddress remoteAddress;
}

/// Bound UDP socket returned by a sockets backend.
abstract interface class WASIPreview3UdpBinding {
  /// Bound local address.
  WASIPreview3IpSocketAddress get localAddress;

  /// Sends one datagram.
  Future<WASIPreview3SocketResult<void>> send(
    Uint8List data,
    WASIPreview3IpSocketAddress remoteAddress,
  );

  /// Receives one datagram.
  Future<WASIPreview3SocketResult<WASIPreview3IncomingDatagram>> receive();

  /// Closes the binding.
  void close();
}

/// Optional lifecycle state exposed by UDP bindings that can terminate without
/// a guest-initiated I/O operation.
abstract interface class WASIPreview3UdpBindingLifecycle
    implements WASIPreview3UdpBinding {
  /// Whether the underlying endpoint has terminated permanently.
  bool get isClosed;
}

/// Backend used by [WASIPreview3SocketsHost] for network I/O.
abstract interface class WASIPreview3SocketsBackend {
  /// Reserves a TCP endpoint.
  WASIPreview3SocketOperation<WASIPreview3TcpBinding> startTcpBind(
    WASIPreview3IpSocketAddress localAddress, {
    required BigInt backlog,
  });

  /// Connects a TCP endpoint, consuming [binding] when one is supplied.
  WASIPreview3SocketOperation<WASIPreview3TcpConnection> startTcpConnect({
    required WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress,
    WASIPreview3TcpBinding? binding,
  });

  /// Starts a TCP listener, consuming [binding] when one is supplied.
  WASIPreview3SocketOperation<WASIPreview3TcpListener> startTcpListen({
    required WASIPreview3IpSocketAddress localAddress,
    required BigInt backlog,
    WASIPreview3TcpBinding? binding,
  });

  /// Binds a UDP endpoint.
  WASIPreview3SocketOperation<WASIPreview3UdpBinding> startUdpBind(
    WASIPreview3IpSocketAddress localAddress,
  );
}

/// Optional capability marker for socket options.
///
/// Backends that cannot faithfully apply kernel options should implement this
/// interface and return false instead of accepting an in-memory-only setting.
abstract interface class WASIPreview3SocketOptionsBackend {
  /// Whether TCP option getters and setters are faithfully implemented.
  bool get supportsTcpSocketOptions;

  /// Whether UDP option getters and setters are faithfully implemented.
  bool get supportsUdpSocketOptions;

  /// Applies TCP options to an active connection or listener.
  String? applyTcpSocketOptions({
    required WASIPreview3TcpSocketOptions options,
    WASIPreview3TcpConnection? connection,
    WASIPreview3TcpListener? listener,
  });

  /// Applies UDP options to an active binding.
  String? applyUdpSocketOptions({
    required WASIPreview3UdpSocketOptions options,
    WASIPreview3UdpBinding? binding,
  });
}

/// Backend that explicitly rejects network access.
final class WASIPreview3UnsupportedSocketsBackend
    implements WASIPreview3SocketsBackend {
  /// Creates an unsupported backend.
  const WASIPreview3UnsupportedSocketsBackend();

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
  }) => WASIPreview3SocketOperation<WASIPreview3TcpConnection>.completed(
    const WASIPreview3SocketResult<WASIPreview3TcpConnection>.error(
      'not-supported',
    ),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpListener> startTcpListen({
    required WASIPreview3IpSocketAddress localAddress,
    required BigInt backlog,
    WASIPreview3TcpBinding? binding,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpListener>.completed(
    const WASIPreview3SocketResult<WASIPreview3TcpListener>.error(
      'not-supported',
    ),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3UdpBinding> startUdpBind(
    WASIPreview3IpSocketAddress localAddress,
  ) => WASIPreview3SocketOperation<WASIPreview3UdpBinding>.completed(
    const WASIPreview3SocketResult<WASIPreview3UdpBinding>.error(
      'not-supported',
    ),
  );
}

/// Resolves a host name to preferred IP addresses.
typedef WASIPreview3AddressResolver =
    FutureOr<Iterable<WASIPreview3IpAddress>> Function(String name);

/// A standardized DNS failure returned by [WASIPreview3AddressResolver].
final class WASIPreview3AddressResolverError implements Exception {
  /// Creates a DNS failure with a stable `ip-name-lookup.error-code` label.
  const WASIPreview3AddressResolverError(this.errorCode);

  /// DNS error variant label.
  final String errorCode;
}

/// WASI 0.3 `wasi:sockets` host imports.
base class WASIPreview3SocketsHost {
  /// Creates a sockets host.
  WASIPreview3SocketsHost({
    WASIComponentResourceTable? table,
    WASIPreview3AddressResolver? resolveAddresses,
    WASIPreview3SocketsBackend? backend,
  }) : table = table ?? WASIComponentResourceTable(),
       _resolveAddresses = resolveAddresses ?? _defaultResolver,
       _backend = backend ?? const WASIPreview3UnsupportedSocketsBackend();

  /// Shared component resource table.
  final WASIComponentResourceTable table;

  final WASIPreview3AddressResolver _resolveAddresses;
  final WASIPreview3SocketsBackend _backend;
  final Set<WASIPreview3IpSocketAddress> _tcpReservations =
      <WASIPreview3IpSocketAddress>{};
  final Set<WASIPreview3IpSocketAddress> _udpReservations =
      <WASIPreview3IpSocketAddress>{};

  late final WASIComponentResourceType<_TcpSocket> _tcpType = table
      .defineType<_TcpSocket>(
        'wasi:sockets/types@0.3.0.tcp-socket',
        onDrop: _dropTcp,
      );
  late final WASIComponentResourceType<_UdpSocket> _udpType = table
      .defineType<_UdpSocket>(
        'wasi:sockets/types@0.3.0.udp-socket',
        onDrop: _dropUdp,
      );

  /// Stable `wasi:sockets@0.3.0` import callbacks.
  late final Map<String, WASIComponentWitAdapterCallback>
  imports = Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
    'wasi:sockets/types@0.3.0.tcp-socket.create': (args) =>
        _createTcp(args.single),
    'wasi:sockets/types@0.3.0.tcp-socket.bind': (args) =>
        _tcpBind(_handle(args[0]), args[1]),
    'wasi:sockets/types@0.3.0.tcp-socket.connect': (args) =>
        _tcpConnect(_handle(args[0]), args[1]),
    'wasi:sockets/types@0.3.0.tcp-socket.listen': (args) =>
        _tcpListen(_handle(args.single)),
    'wasi:sockets/types@0.3.0.tcp-socket.send': (args) =>
        _tcpSend(_handle(args[0]), args[1]),
    'wasi:sockets/types@0.3.0.tcp-socket.receive': (args) =>
        _tcpReceive(_handle(args.single)),
    'wasi:sockets/types@0.3.0.tcp-socket.get-local-address': (args) =>
        _tcpLocalAddress(_handle(args.single)),
    'wasi:sockets/types@0.3.0.tcp-socket.get-remote-address': (args) =>
        _tcpRemoteAddress(_handle(args.single)),
    'wasi:sockets/types@0.3.0.tcp-socket.get-is-listening': (args) =>
        _tcp(_handle(args.single))?.state == _TcpState.listening,
    'wasi:sockets/types@0.3.0.tcp-socket.get-address-family': (args) =>
        _familyData(_requireTcp(_handle(args.single)).family),
    'wasi:sockets/types@0.3.0.tcp-socket.set-listen-backlog-size': (args) =>
        _tcpSetBacklog(_handle(args[0]), _u64(args[1])),
    'wasi:sockets/types@0.3.0.tcp-socket.get-keep-alive-enabled': (args) =>
        _tcpOption(
          _handle(args.single),
          (socket) => _ok(_bool(socket.keepAliveEnabled)),
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.set-keep-alive-enabled': (args) =>
        _tcpSetOption(_handle(args[0]), (socket) {
          socket.keepAliveEnabled = args[1] as bool;
        }),
    'wasi:sockets/types@0.3.0.tcp-socket.get-keep-alive-idle-time': (args) =>
        _tcpOption(
          _handle(args.single),
          (socket) => _ok(_integer(socket.keepAliveIdle)),
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.set-keep-alive-idle-time': (args) =>
        _tcpSetPositiveU64(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.keepAliveIdle = value,
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.get-keep-alive-interval': (args) =>
        _tcpOption(
          _handle(args.single),
          (socket) => _ok(_integer(socket.keepAliveInterval)),
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.set-keep-alive-interval': (args) =>
        _tcpSetPositiveU64(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.keepAliveInterval = value,
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.get-keep-alive-count': (args) =>
        _tcpOption(
          _handle(args.single),
          (socket) => _ok(_integer(socket.keepAliveCount)),
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.set-keep-alive-count': (args) =>
        _tcpSetPositiveInt(
          _handle(args[0]),
          _u32(args[1]),
          (socket, value) => socket.keepAliveCount = value,
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.get-hop-limit': (args) => _tcpOption(
      _handle(args.single),
      (socket) => _ok(_integer(socket.hopLimit)),
    ),
    'wasi:sockets/types@0.3.0.tcp-socket.set-hop-limit': (args) =>
        _tcpSetPositiveInt(
          _handle(args[0]),
          _u8(args[1]),
          (socket, value) => socket.hopLimit = value,
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.get-receive-buffer-size': (args) =>
        _tcpOption(
          _handle(args.single),
          (socket) => _ok(_integer(socket.receiveBufferSize)),
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.set-receive-buffer-size': (args) =>
        _tcpSetPositiveU64(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.receiveBufferSize = value,
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.get-send-buffer-size': (args) =>
        _tcpOption(
          _handle(args.single),
          (socket) => _ok(_integer(socket.sendBufferSize)),
        ),
    'wasi:sockets/types@0.3.0.tcp-socket.set-send-buffer-size': (args) =>
        _tcpSetPositiveU64(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.sendBufferSize = value,
        ),
    'wasi:sockets/types@0.3.0.udp-socket.create': (args) =>
        _createUdp(args.single),
    'wasi:sockets/types@0.3.0.udp-socket.bind': (args) =>
        _udpBind(_handle(args[0]), args[1]),
    'wasi:sockets/types@0.3.0.udp-socket.connect': (args) =>
        _udpConnect(_handle(args[0]), args[1]),
    'wasi:sockets/types@0.3.0.udp-socket.disconnect': (args) =>
        _udpDisconnect(_handle(args.single)),
    'wasi:sockets/types@0.3.0.udp-socket.send': (args) =>
        _udpSend(_handle(args[0]), args[1], args[2]),
    'wasi:sockets/types@0.3.0.udp-socket.receive': (args) =>
        _udpReceive(_handle(args.single)),
    'wasi:sockets/types@0.3.0.udp-socket.get-local-address': (args) =>
        _udpLocalAddress(_handle(args.single)),
    'wasi:sockets/types@0.3.0.udp-socket.get-remote-address': (args) =>
        _udpRemoteAddress(_handle(args.single)),
    'wasi:sockets/types@0.3.0.udp-socket.get-address-family': (args) =>
        _familyData(_requireUdp(_handle(args.single)).family),
    'wasi:sockets/types@0.3.0.udp-socket.get-unicast-hop-limit': (args) =>
        _udpOption(
          _handle(args.single),
          (socket) => _ok(_integer(socket.hopLimit)),
        ),
    'wasi:sockets/types@0.3.0.udp-socket.set-unicast-hop-limit': (args) =>
        _udpSetPositiveInt(
          _handle(args[0]),
          _u8(args[1]),
          (socket, value) => socket.hopLimit = value,
        ),
    'wasi:sockets/types@0.3.0.udp-socket.get-receive-buffer-size': (args) =>
        _udpOption(
          _handle(args.single),
          (socket) => _ok(_integer(socket.receiveBufferSize)),
        ),
    'wasi:sockets/types@0.3.0.udp-socket.set-receive-buffer-size': (args) =>
        _udpSetPositiveU64(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.receiveBufferSize = value,
        ),
    'wasi:sockets/types@0.3.0.udp-socket.get-send-buffer-size': (args) =>
        _udpOption(
          _handle(args.single),
          (socket) => _ok(_integer(socket.sendBufferSize)),
        ),
    'wasi:sockets/types@0.3.0.udp-socket.set-send-buffer-size': (args) =>
        _udpSetPositiveU64(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.sendBufferSize = value,
        ),
    'wasi:sockets/ip-name-lookup@0.3.0.resolve-addresses': (args) =>
        _resolve(args.single as String),
  });

  WasmComponentValueData _createTcp(Object? familyValue) {
    final family = _family(familyValue);
    if (family == null) return _error('invalid-argument');
    final handle = table.insert<_TcpSocket>(_tcpType, _TcpSocket(family));
    return _ok(_integer(handle));
  }

  WasmComponentValueData _createUdp(Object? familyValue) {
    final family = _family(familyValue);
    if (family == null) return _error('invalid-argument');
    final handle = table.insert<_UdpSocket>(_udpType, _UdpSocket(family));
    return _ok(_integer(handle));
  }

  FutureOr<WasmComponentValueData> _tcpBind(int handle, Object? addressValue) {
    final socket = _tcp(handle);
    if (socket == null ||
        socket.state == _TcpState.closed ||
        socket.pendingBind != null ||
        socket.pendingListen != null) {
      return _error('invalid-state');
    }
    if (socket.state != _TcpState.unbound) return _error('invalid-state');
    final address = _socketAddress(addressValue);
    final addressError = _addressError(
      address,
      socket.family,
      local: true,
      requireUnicast: true,
    );
    if (addressError != null) return _error(addressError);
    if (address!.port != 0 && _reservationInUse(_tcpReservations, address)) {
      return _error('address-in-use');
    }

    final operation = _backend.startTcpBind(
      address,
      backlog: socket.listenBacklog,
    );
    final immediate = operation.resultOrNull;
    if (immediate != null) {
      return _completeTcpBind(socket, operation, immediate);
    }
    socket.pendingBind = operation;
    return _finishTcpBind(socket, operation);
  }

  Future<WasmComponentValueData> _finishTcpBind(
    _TcpSocket socket,
    WASIPreview3SocketOperation<WASIPreview3TcpBinding> operation,
  ) async {
    final result = await operation.wait();
    if (socket.state == _TcpState.closed || socket.pendingBind != operation) {
      operation.dispose(disposeValue: (binding) => binding.close());
      return _error('invalid-state');
    }
    socket.pendingBind = null;
    return _completeTcpBind(socket, operation, result);
  }

  WasmComponentValueData _completeTcpBind(
    _TcpSocket socket,
    WASIPreview3SocketOperation<WASIPreview3TcpBinding> operation,
    WASIPreview3SocketResult<WASIPreview3TcpBinding> result,
  ) {
    if (!result.isOk) {
      operation.dispose();
      return _error(result.errorCode!);
    }
    final binding = result.value!;
    if (!_reserveTcp(socket, binding.localAddress)) {
      operation.dispose(disposeValue: (value) => value.close());
      return _error('address-in-use');
    }
    socket
      ..state = _TcpState.bound
      ..binding = binding
      ..localAddress = binding.localAddress;
    return _ok();
  }

  Future<WasmComponentValueData> _tcpConnect(
    int handle,
    Object? addressValue,
  ) async {
    final socket = _tcp(handle);
    if (socket == null ||
        (socket.state != _TcpState.unbound &&
            socket.state != _TcpState.bound) ||
        socket.pendingBind != null ||
        socket.pendingListen != null) {
      return _error('invalid-state');
    }
    final remote = _socketAddress(addressValue);
    final addressError = _addressError(
      remote,
      socket.family,
      local: false,
      requireUnicast: true,
    );
    if (addressError != null) return _error(addressError);
    socket.state = _TcpState.connecting;

    final operation = _backend.startTcpConnect(
      remoteAddress: remote!,
      localAddress: socket.localAddress,
      binding: socket.binding,
    );
    socket.binding = null;
    socket.pendingConnect = operation;
    final result = await operation.wait();
    if (socket.state == _TcpState.closed ||
        socket.pendingConnect != operation) {
      operation.dispose(disposeValue: (connection) => connection.close());
      return _error('invalid-state');
    }
    socket.pendingConnect = null;
    if (!result.isOk) {
      _releaseTcpReservation(socket);
      socket
        ..state = _TcpState.closed
        ..terminalError = result.errorCode;
      return _error(result.errorCode!);
    }
    final connection = result.value!;
    final optionError = _applyTcpSocketOptions(socket, connection: connection);
    if (optionError != null) {
      connection.close();
      _releaseTcpReservation(socket);
      socket
        ..state = _TcpState.closed
        ..localAddress = null
        ..terminalError = optionError;
      return _error(optionError);
    }
    socket
      ..state = _TcpState.connected
      ..connection = connection
      ..connectionReferences = 1
      ..localAddress = connection.localAddress
      ..remoteAddress = connection.remoteAddress;
    return _ok();
  }

  FutureOr<WasmComponentValueData> _tcpListen(int handle) {
    final socket = _tcp(handle);
    if (socket == null ||
        (socket.state != _TcpState.unbound &&
            socket.state != _TcpState.bound) ||
        socket.pendingBind != null ||
        socket.pendingListen != null) {
      return _error('invalid-state');
    }
    final requested = socket.localAddress ?? _wildcard(socket.family);
    final operation = _backend.startTcpListen(
      localAddress: requested,
      backlog: socket.listenBacklog,
      binding: socket.binding,
    );
    socket.binding = null;
    final immediate = operation.resultOrNull;
    if (immediate != null) {
      return _completeTcpListen(handle, socket, operation, immediate);
    }
    socket.pendingListen = operation;
    return _finishTcpListen(handle, socket, operation);
  }

  Future<WasmComponentValueData> _finishTcpListen(
    int handle,
    _TcpSocket socket,
    WASIPreview3SocketOperation<WASIPreview3TcpListener> operation,
  ) async {
    final result = await operation.wait();
    if (socket.state == _TcpState.closed || socket.pendingListen != operation) {
      operation.dispose(disposeValue: (listener) => listener.close());
      return _error('invalid-state');
    }
    socket.pendingListen = null;
    return _completeTcpListen(handle, socket, operation, result);
  }

  WasmComponentValueData _completeTcpListen(
    int handle,
    _TcpSocket socket,
    WASIPreview3SocketOperation<WASIPreview3TcpListener> operation,
    WASIPreview3SocketResult<WASIPreview3TcpListener> result,
  ) {
    if (!result.isOk) {
      _releaseTcpReservation(socket);
      socket
        ..state = _TcpState.closed
        ..localAddress = null
        ..terminalError = result.errorCode;
      operation.dispose();
      return _error(result.errorCode!);
    }
    final listener = result.value!;
    if (!_reserveTcp(socket, listener.localAddress)) {
      operation.dispose(disposeValue: (value) => value.close());
      return _error('address-in-use');
    }

    final optionError = _applyTcpSocketOptions(socket, listener: listener);
    if (optionError != null) {
      _releaseTcpReservation(socket);
      operation.dispose(disposeValue: (value) => value.close());
      socket
        ..state = _TcpState.closed
        ..localAddress = null
        ..terminalError = optionError;
      return _error(optionError);
    }

    final accepted = WASIComponentStream<int>(
      'wasi-sockets-tcp-listen-$handle',
      maxBufferedElements: _boundedBacklog(socket.listenBacklog),
      onReadableDrop: () => _releaseListener(socket),
      onDiscard: _dropAcceptedTcp,
    );
    socket
      ..state = _TcpState.listening
      ..listenStream = accepted
      ..listenerReferences = 2
      ..listener = listener
      ..localAddress = listener.localAddress;
    unawaited(_pumpListener(socket, listener, accepted));
    return _okPayload(accepted);
  }

  Future<void> _pumpListener(
    _TcpSocket owner,
    WASIPreview3TcpListener listener,
    WASIComponentStream<int> accepted,
  ) async {
    String? terminalError;
    try {
      while (!accepted.writable.isClosed) {
        if (!listener.canAccept) await listener.waitAccept();
        final result = listener.accept();
        if (!result.isOk) {
          if (result.errorCode == 'would-block') continue;
          terminalError = result.errorCode;
          break;
        }
        final connection = result.value!;
        final socket = _TcpSocket.connected(connection, owner);
        int handle;
        try {
          handle = table.insert<_TcpSocket>(_tcpType, socket);
        } on Object {
          connection.close();
          terminalError = 'other';
          break;
        }
        try {
          await accepted.writable.writeWhenAvailable(<int>[handle]);
        } on Object {
          try {
            table.drop<_TcpSocket>(_tcpType, handle);
          } on StateError {
            // A closed runtime scope already released the accepted socket.
          }
          break;
        }
      }
    } on Object {
      terminalError = 'other';
    } finally {
      if (!accepted.writable.isClosed) accepted.writable.close();
      if (terminalError != null &&
          owner.state == _TcpState.listening &&
          owner.listener == listener) {
        _releaseTcpReservation(owner);
        owner
          ..state = _TcpState.closed
          ..terminalError = terminalError
          ..localAddress = null
          ..listener = null;
        listener.close();
      }
    }
  }

  WASIComponentFuture<WasmComponentValueData> _tcpSend(
    int handle,
    Object? streamValue,
  ) {
    final socket = _tcp(handle);
    final stream = switch (streamValue) {
      WASIComponentReadableStream<Object?>() => streamValue,
      WASIComponentStream<Object?>() => streamValue.readable,
      _ => null,
    };
    if (socket == null ||
        socket.state != _TcpState.connected ||
        socket.connection == null ||
        socket.sendStarted ||
        stream == null) {
      final result = WASIComponentFuture<WasmComponentValueData>(
        'wasi-sockets-tcp-send-$handle',
      );
      stream?.drop();
      result.writable.complete(_error('invalid-state'));
      return result;
    }
    late final WASIComponentFuture<WasmComponentValueData> result;
    void cancelIfAbandoned() {
      if (socket.state != _TcpState.closed ||
          !result.readable.isDropped ||
          stream.isDropped) {
        return;
      }
      result.writable.dispose();
      stream.cancel();
    }

    result = WASIComponentFuture<WasmComponentValueData>(
      'wasi-sockets-tcp-send-$handle',
      onReadableDrop: cancelIfAbandoned,
    );
    socket.sendStarted = true;
    socket.connectionReferences++;
    socket.cancelAbandonedSend = cancelIfAbandoned;
    unawaited(_drainTcpSend(socket, stream, result, cancelIfAbandoned));
    return result;
  }

  Future<void> _drainTcpSend(
    _TcpSocket socket,
    WASIComponentReadableStream<Object?> stream,
    WASIComponentFuture<WasmComponentValueData> result,
    void Function() cancelIfAbandoned,
  ) async {
    final connection = socket.connection!;
    try {
      try {
        while (true) {
          final bytes = await stream.readWhenAvailable(65536);
          if (bytes.isEmpty) break;
          final written = await connection.write(
            Uint8List.fromList(bytes.cast<int>()),
          );
          if (!written.isOk) {
            result.writable.complete(_error(written.errorCode!));
            return;
          }
        }
      } on WASIComponentAsyncEndpointStateError catch (error) {
        if (error.failure != WASIComponentAsyncEndpointFailure.dropped) {
          rethrow;
        }
      }
      final finished = await connection.finishSend();
      result.writable.complete(
        finished.isOk ? _ok() : _error(finished.errorCode!),
      );
    } on Object {
      if (result.writable.canComplete) {
        result.writable.complete(_error('connection-broken'));
      }
    } finally {
      if (identical(socket.cancelAbandonedSend, cancelIfAbandoned)) {
        socket.cancelAbandonedSend = null;
      }
      _releaseConnection(socket);
    }
  }

  List<Object?> _tcpReceive(int handle) {
    final socket = _tcp(handle);
    if (socket == null ||
        socket.state != _TcpState.connected ||
        socket.connection == null ||
        socket.receiveStarted) {
      return _closedTcpReceive(handle, 'invalid-state');
    }
    socket.receiveStarted = true;
    socket.connectionReferences++;
    final connection = socket.connection!;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _releaseConnection(socket);
    }

    final result = WASIComponentFuture<WasmComponentValueData>(
      'wasi-sockets-tcp-receive-result-$handle',
    );
    late final WASIComponentStream<int> incoming;
    var readHalfDropped = false;
    void dropReadHalf() {
      if (readHalfDropped) return;
      readHalfDropped = true;
      connection.closeReceive();
      if (!incoming.writable.isClosed) incoming.writable.close();
      if (result.writable.canComplete) result.writable.complete(_ok());
      release();
    }

    incoming = WASIComponentStream<int>(
      'wasi-sockets-tcp-receive-$handle',
      maxBufferedElements: 65536,
      onReadableDrop: dropReadHalf,
    );
    unawaited(() async {
      try {
        while (true) {
          final chunk = await connection.incoming.readable.readWhenAvailable(
            65536,
          );
          if (chunk.isEmpty) break;
          await _writeAll(incoming.writable, chunk);
        }
        final completed = await connection.incomingDone;
        if (!incoming.writable.isClosed) incoming.writable.close();
        if (result.writable.canComplete) {
          result.writable.complete(
            completed.isOk ? _ok() : _error(completed.errorCode!),
          );
        }
      } on Object {
        if (!incoming.writable.isClosed) incoming.writable.close();
        if (result.writable.canComplete) {
          result.writable.complete(_error('connection-reset'));
        }
      } finally {
        release();
      }
    }());
    return <Object?>[incoming, result];
  }

  List<Object?> _closedTcpReceive(int handle, String error) {
    final stream = WASIComponentStream<int>(
      'wasi-sockets-tcp-receive-closed-$handle',
    );
    stream.writable.close();
    final result = WASIComponentFuture<WasmComponentValueData>(
      'wasi-sockets-tcp-receive-error-$handle',
    );
    result.writable.complete(_error(error));
    return <Object?>[stream, result];
  }

  WasmComponentValueData _tcpLocalAddress(int handle) {
    final socket = _tcp(handle);
    final address = socket?.localAddress;
    return address == null
        ? _error('invalid-state')
        : _ok(_addressData(address));
  }

  WasmComponentValueData _tcpRemoteAddress(int handle) {
    final socket = _tcp(handle);
    final address = socket?.remoteAddress;
    return address == null
        ? _error('invalid-state')
        : _ok(_addressData(address));
  }

  WasmComponentValueData _tcpSetBacklog(int handle, BigInt value) {
    final socket = _tcp(handle);
    if (socket == null ||
        socket.state == _TcpState.closed ||
        socket.state == _TcpState.connecting ||
        socket.state == _TcpState.connected) {
      return _error('invalid-state');
    }
    if (value <= BigInt.zero) return _error('invalid-argument');
    if (socket.state == _TcpState.listening) {
      return _error('not-supported');
    }
    socket.listenBacklog = value;
    return _ok();
  }

  WasmComponentValueData _tcpOption(
    int handle,
    WasmComponentValueData Function(_TcpSocket socket) callback,
  ) {
    final socket = _tcp(handle);
    if (socket == null || socket.state == _TcpState.closed) {
      return _error('invalid-state');
    }
    final backend = _backend;
    if (backend is WASIPreview3SocketOptionsBackend &&
        !(backend as WASIPreview3SocketOptionsBackend)
            .supportsTcpSocketOptions) {
      return _error('not-supported');
    }
    return callback(socket);
  }

  WasmComponentValueData _tcpSetOption(
    int handle,
    void Function(_TcpSocket socket) write,
  ) => _tcpOption(handle, (socket) {
    final previous = _tcpSocketOptions(socket);
    write(socket);
    final error = _applyTcpSocketOptions(socket);
    if (error != null) {
      _restoreTcpSocketOptions(socket, previous);
    }
    return error == null ? _ok() : _error(error);
  });

  String? _applyTcpSocketOptions(
    _TcpSocket socket, {
    WASIPreview3TcpConnection? connection,
    WASIPreview3TcpListener? listener,
  }) {
    final backend = _backend;
    if (backend is! WASIPreview3SocketOptionsBackend) return null;
    return (backend as WASIPreview3SocketOptionsBackend).applyTcpSocketOptions(
      options: _tcpSocketOptions(socket),
      connection: connection ?? socket.connection,
      listener: listener ?? socket.listener,
    );
  }

  WasmComponentValueData _tcpSetPositiveInt(
    int handle,
    int value,
    void Function(_TcpSocket socket, int value) write,
  ) {
    if (value == 0) {
      return _tcpOption(handle, (_) => _error('invalid-argument'));
    }
    return _tcpSetOption(handle, (socket) => write(socket, value));
  }

  WasmComponentValueData _tcpSetPositiveU64(
    int handle,
    BigInt value,
    void Function(_TcpSocket socket, BigInt value) write,
  ) {
    if (value <= BigInt.zero) {
      return _tcpOption(handle, (_) => _error('invalid-argument'));
    }
    return _tcpSetOption(handle, (socket) => write(socket, value));
  }

  FutureOr<WasmComponentValueData> _udpBind(int handle, Object? addressValue) {
    final socket = _udp(handle);
    if (socket == null ||
        socket.closed ||
        socket.binding != null ||
        socket.pendingBind != null) {
      return _error('invalid-state');
    }
    final terminalError = socket.terminalError;
    if (terminalError != null) return _error(terminalError);
    final address = _socketAddress(addressValue);
    final addressError = _addressError(
      address,
      socket.family,
      local: true,
      requireUnicast: true,
    );
    if (addressError != null) return _error(addressError);
    if (address!.port != 0 && _reservationInUse(_udpReservations, address)) {
      return _error('address-in-use');
    }
    final operation = _backend.startUdpBind(address);
    final immediate = operation.resultOrNull;
    if (immediate != null) {
      final error = _completeUdpBind(socket, operation, immediate);
      return error == null ? _ok() : _error(error);
    }
    socket.pendingBind = operation;
    final pending = _finishUdpBind(socket, operation);
    socket.pendingBinding = pending;
    return _finishExplicitUdpBind(socket, pending);
  }

  Future<WasmComponentValueData> _finishExplicitUdpBind(
    _UdpSocket socket,
    Future<WASIPreview3UdpBinding?> pending,
  ) async {
    final binding = await pending;
    if (binding != null) return _ok();
    return _error(socket.terminalError ?? 'invalid-state');
  }

  Future<WASIPreview3UdpBinding?> _finishUdpBind(
    _UdpSocket socket,
    WASIPreview3SocketOperation<WASIPreview3UdpBinding> operation,
  ) async {
    final result = await operation.wait();
    if (socket.pendingBind != operation || socket.closed) {
      operation.dispose(disposeValue: (binding) => binding.close());
      return null;
    }
    socket.pendingBind = null;
    final error = _completeUdpBind(socket, operation, result);
    return error == null ? socket.binding : null;
  }

  String? _completeUdpBind(
    _UdpSocket socket,
    WASIPreview3SocketOperation<WASIPreview3UdpBinding> operation,
    WASIPreview3SocketResult<WASIPreview3UdpBinding> result,
  ) {
    if (!result.isOk) {
      operation.dispose();
      _releaseUdpReservation(socket);
      socket
        ..localAddress = null
        ..terminalError = result.errorCode;
      return result.errorCode;
    }
    final binding = result.value!;
    if (!_reserveUdp(socket, binding.localAddress)) {
      operation.dispose(disposeValue: (value) => value.close());
      socket
        ..localAddress = null
        ..terminalError = 'address-in-use';
      return 'address-in-use';
    }
    final optionError = _applyUdpSocketOptions(socket, binding: binding);
    if (optionError != null) {
      _releaseUdpReservation(socket);
      operation.dispose(disposeValue: (value) => value.close());
      socket
        ..localAddress = null
        ..terminalError = optionError;
      return optionError;
    }
    socket
      ..binding = binding
      ..localAddress = binding.localAddress;
    return null;
  }

  FutureOr<WasmComponentValueData> _udpConnect(
    int handle,
    Object? addressValue,
  ) {
    final socket = _udp(handle);
    if (socket == null || socket.closed) return _error('invalid-state');
    final terminalError = socket.terminalError;
    if (terminalError != null) return _error(terminalError);
    final address = _socketAddress(addressValue);
    final addressError = _addressError(address, socket.family, local: false);
    if (addressError != null) return _error(addressError);
    if (socket.binding == null) {
      if (socket.pendingBind != null) return _error('invalid-state');
      final started = _startImplicitUdpBind(socket, remote: address);
      if (started != null) return _error(started);
      final binding = socket.binding;
      if (binding == null) {
        return _finishUdpConnect(socket, address!, socket.pendingBinding!);
      }
    }
    socket.remoteAddress = address;
    return _ok();
  }

  Future<WasmComponentValueData> _finishUdpConnect(
    _UdpSocket socket,
    WASIPreview3IpSocketAddress remote,
    Future<WASIPreview3UdpBinding?> pending,
  ) async {
    final binding = await pending;
    if (binding == null) {
      return _error(socket.terminalError ?? 'invalid-state');
    }
    socket.remoteAddress = remote;
    return _ok();
  }

  WasmComponentValueData _udpDisconnect(int handle) {
    final socket = _udp(handle);
    if (socket == null || socket.closed || socket.remoteAddress == null) {
      return _error('invalid-state');
    }
    socket.remoteAddress = null;
    return _ok();
  }

  Future<WasmComponentValueData> _udpSend(
    int handle,
    Object? dataValue,
    Object? remoteValue,
  ) async {
    final socket = _udp(handle);
    if (socket == null || socket.closed) return _error('invalid-state');
    final bytes = _bytes(dataValue);
    if (bytes == null) return _error('invalid-argument');
    if (bytes.length > 65535) return _error('datagram-too-large');
    final explicitRemote = _optionalSocketAddress(remoteValue);
    if (explicitRemote.isInvalid) return _error('invalid-argument');
    final connected = socket.remoteAddress;
    final remote = explicitRemote.value ?? connected;
    if (remote == null) return _error('invalid-argument');
    final addressError = _addressError(remote, socket.family, local: false);
    if (addressError != null) return _error(addressError);
    if (connected != null &&
        explicitRemote.value != null &&
        remote != connected) {
      return _error('invalid-argument');
    }
    if (socket.binding == null && socket.pendingBind == null) {
      final started = _startImplicitUdpBind(socket, remote: remote);
      if (started != null) return _error(started);
    }
    final binding = await _udpBinding(socket);
    if (binding == null) return _error(socket.terminalError ?? 'invalid-state');
    final sent = await binding.send(Uint8List.fromList(bytes), remote);
    if (!sent.isOk && sent.errorCode == 'invalid-state') {
      _terminateUdpBinding(socket, binding, sent.errorCode!);
    }
    return sent.isOk ? _ok() : _error(sent.errorCode!);
  }

  Future<WasmComponentValueData> _udpReceive(int handle) async {
    final socket = _udp(handle);
    if (socket == null || socket.closed) return _error('invalid-state');
    if (socket.binding == null &&
        socket.pendingBind == null &&
        socket.remoteAddress != null) {
      final started = _startImplicitUdpBind(
        socket,
        remote: socket.remoteAddress,
      );
      if (started != null) return _error(started);
    }
    final binding = await _udpBinding(socket);
    if (binding == null) return _error(socket.terminalError ?? 'invalid-state');
    while (true) {
      final received = await binding.receive();
      if (!received.isOk) {
        if (received.errorCode == 'invalid-state') {
          _terminateUdpBinding(socket, binding, received.errorCode!);
        }
        return _error(received.errorCode!);
      }
      final datagram = received.value!;
      final remote = socket.remoteAddress;
      if (remote != null && datagram.remoteAddress != remote) continue;
      return _ok(
        _tuple(<WasmComponentValueData>[
          _byteList(datagram.data),
          _addressData(datagram.remoteAddress),
        ]),
      );
    }
  }

  String? _startImplicitUdpBind(
    _UdpSocket socket, {
    WASIPreview3IpSocketAddress? remote,
  }) {
    final terminalError = socket.terminalError;
    if (terminalError != null) return terminalError;
    final requested = remote != null && _isLoopback(remote.address)
        ? _withPort(remote, 0)
        : _wildcard(socket.family);
    final operation = _backend.startUdpBind(requested);
    final immediate = operation.resultOrNull;
    if (immediate != null) {
      return _completeUdpBind(socket, operation, immediate);
    }
    socket.pendingBind = operation;
    socket.pendingBinding = _finishUdpBind(socket, operation);
    return null;
  }

  Future<WASIPreview3UdpBinding?> _udpBinding(_UdpSocket socket) async {
    final existing = socket.binding;
    if (existing != null) {
      if (existing is WASIPreview3UdpBindingLifecycle && existing.isClosed) {
        _terminateUdpBinding(socket, existing, 'invalid-state');
        return null;
      }
      return existing;
    }
    final pending = socket.pendingBinding;
    return pending == null ? null : await pending;
  }

  void _terminateUdpBinding(
    _UdpSocket socket,
    WASIPreview3UdpBinding binding,
    String error,
  ) {
    if (socket.binding != binding) return;
    _releaseUdpReservation(socket);
    socket
      ..binding = null
      ..localAddress = null
      ..terminalError = error;
    binding.close();
  }

  WasmComponentValueData _udpLocalAddress(int handle) {
    final socket = _udp(handle);
    final binding = socket?.binding;
    if (socket != null &&
        binding is WASIPreview3UdpBindingLifecycle &&
        binding.isClosed) {
      _terminateUdpBinding(socket, binding, 'invalid-state');
    }
    final address = socket?.localAddress;
    return address == null
        ? _error('invalid-state')
        : _ok(_addressData(address));
  }

  WasmComponentValueData _udpRemoteAddress(int handle) {
    final address = _udp(handle)?.remoteAddress;
    return address == null
        ? _error('invalid-state')
        : _ok(_addressData(address));
  }

  WasmComponentValueData _udpOption(
    int handle,
    WasmComponentValueData Function(_UdpSocket socket) callback,
  ) {
    final socket = _udp(handle);
    if (socket == null || socket.closed) return _error('invalid-state');
    final backend = _backend;
    if (backend is WASIPreview3SocketOptionsBackend &&
        !(backend as WASIPreview3SocketOptionsBackend)
            .supportsUdpSocketOptions) {
      return _error('not-supported');
    }
    return callback(socket);
  }

  WasmComponentValueData _udpSetOption(
    int handle,
    void Function(_UdpSocket socket) write,
  ) => _udpOption(handle, (socket) {
    final previous = _udpSocketOptions(socket);
    write(socket);
    final error = _applyUdpSocketOptions(socket);
    if (error != null) {
      _restoreUdpSocketOptions(socket, previous);
    }
    return error == null ? _ok() : _error(error);
  });

  String? _applyUdpSocketOptions(
    _UdpSocket socket, {
    WASIPreview3UdpBinding? binding,
  }) {
    final backend = _backend;
    if (backend is! WASIPreview3SocketOptionsBackend) return null;
    return (backend as WASIPreview3SocketOptionsBackend).applyUdpSocketOptions(
      options: _udpSocketOptions(socket),
      binding: binding ?? socket.binding,
    );
  }

  WasmComponentValueData _udpSetPositiveInt(
    int handle,
    int value,
    void Function(_UdpSocket socket, int value) write,
  ) {
    if (value == 0) {
      return _udpOption(handle, (_) => _error('invalid-argument'));
    }
    return _udpSetOption(handle, (socket) => write(socket, value));
  }

  WasmComponentValueData _udpSetPositiveU64(
    int handle,
    BigInt value,
    void Function(_UdpSocket socket, BigInt value) write,
  ) {
    if (value <= BigInt.zero) {
      return _udpOption(handle, (_) => _error('invalid-argument'));
    }
    return _udpSetOption(handle, (socket) => write(socket, value));
  }

  Future<WasmComponentValueData> _resolve(String name) async {
    final literal = WASIPreview3IpAddress.parse(name);
    final query = literal == null ? _toAsciiDnsName(name) : null;
    if (literal == null && query == null) return _dnsError('invalid-argument');
    try {
      final addresses = literal == null
          ? await _resolveAddresses(query!)
          : <WASIPreview3IpAddress>[literal];
      final filtered = <WASIPreview3IpAddress>[
        for (final address in addresses)
          if (!_isIpv4Mapped(address)) address,
      ];
      if (filtered.isEmpty) return _dnsError('name-unresolvable');
      return _ok(
        _list(<WasmComponentValueData>[
          for (final address in filtered) _ipAddressData(address),
        ]),
      );
    } on WASIPreview3AddressResolverError catch (error) {
      return _dnsError(error.errorCode);
    } on Object {
      return _dnsError('permanent-resolver-failure');
    }
  }

  void _dropTcp(_TcpSocket socket) {
    socket.state = _TcpState.closed;
    socket.cancelAbandonedSend?.call();
    _releaseTcpReservation(socket);
    socket.pendingBind?.dispose(disposeValue: (binding) => binding.close());
    socket.pendingListen?.dispose(disposeValue: (listener) => listener.close());
    socket.pendingConnect?.dispose(
      disposeValue: (connection) => connection.close(),
    );
    socket.binding?.close();
    _releaseListener(socket);
    _releaseConnection(socket);
  }

  void _releaseListener(_TcpSocket socket) {
    if (socket.listenerReferences == 0) return;
    socket.listenerReferences--;
    if (socket.listenerReferences == 0) {
      socket.listener?.close();
    }
  }

  void _releaseConnection(_TcpSocket socket) {
    if (socket.connectionReferences == 0) return;
    socket.connectionReferences--;
    if (socket.connectionReferences == 0) socket.connection?.close();
  }

  void _dropAcceptedTcp(int handle) {
    try {
      table.drop<_TcpSocket>(_tcpType, handle);
    } on StateError {
      // A closed runtime scope already released the accepted socket.
    }
  }

  void _dropUdp(_UdpSocket socket) {
    if (socket.closed) return;
    socket.closed = true;
    _releaseUdpReservation(socket);
    socket.pendingBind?.dispose(disposeValue: (binding) => binding.close());
    socket.binding?.close();
  }

  _TcpSocket? _tcp(int handle) {
    try {
      return table.get<_TcpSocket>(_tcpType, handle);
    } on StateError {
      return null;
    }
  }

  _TcpSocket _requireTcp(int handle) => table.get<_TcpSocket>(_tcpType, handle);

  _UdpSocket? _udp(int handle) {
    try {
      return table.get<_UdpSocket>(_udpType, handle);
    } on StateError {
      return null;
    }
  }

  _UdpSocket _requireUdp(int handle) => table.get<_UdpSocket>(_udpType, handle);

  bool _reserveTcp(_TcpSocket socket, WASIPreview3IpSocketAddress address) {
    if (socket.reservedLocalAddress == address) return true;
    if (address.port == 0) return true;
    if (_reservationInUse(_tcpReservations, address)) return false;
    _tcpReservations.add(address);
    socket.reservedLocalAddress = address;
    return true;
  }

  bool _reserveUdp(_UdpSocket socket, WASIPreview3IpSocketAddress address) {
    if (socket.reservedLocalAddress == address) return true;
    if (address.port == 0) return true;
    if (_reservationInUse(_udpReservations, address)) return false;
    _udpReservations.add(address);
    socket.reservedLocalAddress = address;
    return true;
  }

  void _releaseTcpReservation(_TcpSocket socket) {
    final address = socket.reservedLocalAddress;
    if (address == null) return;
    _tcpReservations.remove(address);
    socket.reservedLocalAddress = null;
  }

  void _releaseUdpReservation(_UdpSocket socket) {
    final address = socket.reservedLocalAddress;
    if (address == null) return;
    _udpReservations.remove(address);
    socket.reservedLocalAddress = null;
  }
}

WASIPreview3TcpSocketOptions _tcpSocketOptions(_TcpSocket socket) =>
    WASIPreview3TcpSocketOptions(
      keepAliveEnabled: socket.keepAliveEnabled,
      keepAliveIdle: socket.keepAliveIdle,
      keepAliveInterval: socket.keepAliveInterval,
      keepAliveCount: socket.keepAliveCount,
      hopLimit: socket.hopLimit,
      receiveBufferSize: socket.receiveBufferSize,
      sendBufferSize: socket.sendBufferSize,
    );

void _restoreTcpSocketOptions(
  _TcpSocket socket,
  WASIPreview3TcpSocketOptions options,
) {
  socket
    ..keepAliveEnabled = options.keepAliveEnabled
    ..keepAliveIdle = options.keepAliveIdle
    ..keepAliveInterval = options.keepAliveInterval
    ..keepAliveCount = options.keepAliveCount
    ..hopLimit = options.hopLimit
    ..receiveBufferSize = options.receiveBufferSize
    ..sendBufferSize = options.sendBufferSize;
}

WASIPreview3UdpSocketOptions _udpSocketOptions(_UdpSocket socket) =>
    WASIPreview3UdpSocketOptions(
      hopLimit: socket.hopLimit,
      receiveBufferSize: socket.receiveBufferSize,
      sendBufferSize: socket.sendBufferSize,
    );

void _restoreUdpSocketOptions(
  _UdpSocket socket,
  WASIPreview3UdpSocketOptions options,
) {
  socket
    ..hopLimit = options.hopLimit
    ..receiveBufferSize = options.receiveBufferSize
    ..sendBufferSize = options.sendBufferSize;
}

enum _TcpState { unbound, bound, connecting, connected, listening, closed }

final class _TcpSocket {
  _TcpSocket(this.family);

  _TcpSocket.connected(
    WASIPreview3TcpConnection connection,
    _TcpSocket listener,
  ) : family = connection.localAddress.family,
      state = _TcpState.connected,
      connection = connection,
      connectionReferences = 1,
      localAddress = connection.localAddress,
      remoteAddress = connection.remoteAddress,
      listenBacklog = listener.listenBacklog,
      keepAliveEnabled = listener.keepAliveEnabled,
      keepAliveIdle = listener.keepAliveIdle,
      keepAliveInterval = listener.keepAliveInterval,
      keepAliveCount = listener.keepAliveCount,
      hopLimit = listener.hopLimit,
      receiveBufferSize = listener.receiveBufferSize,
      sendBufferSize = listener.sendBufferSize;

  final WASIPreview3IpAddressFamily family;
  _TcpState state = _TcpState.unbound;
  WASIPreview3IpSocketAddress? localAddress;
  WASIPreview3IpSocketAddress? reservedLocalAddress;
  WASIPreview3IpSocketAddress? remoteAddress;
  WASIPreview3SocketOperation<WASIPreview3TcpBinding>? pendingBind;
  WASIPreview3SocketOperation<WASIPreview3TcpListener>? pendingListen;
  WASIPreview3SocketOperation<WASIPreview3TcpConnection>? pendingConnect;
  WASIPreview3TcpBinding? binding;
  WASIPreview3TcpListener? listener;
  WASIComponentStream<int>? listenStream;
  WASIPreview3TcpConnection? connection;
  String? terminalError;
  int listenerReferences = 0;
  int connectionReferences = 0;
  void Function()? cancelAbandonedSend;
  bool sendStarted = false;
  bool receiveStarted = false;
  BigInt listenBacklog = BigInt.from(128);
  bool keepAliveEnabled = false;
  BigInt keepAliveIdle = BigInt.from(7200000000000);
  BigInt keepAliveInterval = BigInt.from(75000000000);
  int keepAliveCount = 9;
  int hopLimit = 64;
  BigInt receiveBufferSize = BigInt.from(65536);
  BigInt sendBufferSize = BigInt.from(65536);
}

final class _UdpSocket {
  _UdpSocket(this.family);

  final WASIPreview3IpAddressFamily family;
  WASIPreview3IpSocketAddress? localAddress;
  WASIPreview3IpSocketAddress? reservedLocalAddress;
  WASIPreview3IpSocketAddress? remoteAddress;
  WASIPreview3SocketOperation<WASIPreview3UdpBinding>? pendingBind;
  Future<WASIPreview3UdpBinding?>? pendingBinding;
  WASIPreview3UdpBinding? binding;
  String? terminalError;
  bool closed = false;
  int hopLimit = 64;
  BigInt receiveBufferSize = BigInt.from(65536);
  BigInt sendBufferSize = BigInt.from(65536);
}

final class _OptionalSocketAddress {
  const _OptionalSocketAddress(this.value, {this.isInvalid = false});

  final WASIPreview3IpSocketAddress? value;
  final bool isInvalid;
}

WASIPreview3IpAddressFamily? _family(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.enumeration) {
    return null;
  }
  if (value.label == 'ipv4' || (value.label == null && value.index == 0)) {
    return WASIPreview3IpAddressFamily.ipv4;
  }
  if (value.label == 'ipv6' || (value.label == null && value.index == 1)) {
    return WASIPreview3IpAddressFamily.ipv6;
  }
  return null;
}

WASIPreview3IpSocketAddress? _socketAddress(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.variant ||
      value.associatedValue == null) {
    return null;
  }
  final record = value.associatedValue!;
  if (record.kind != WasmComponentValueDataKind.record) return null;
  if (value.label == 'ipv4' || (value.label == null && value.index == 0)) {
    if (record.items.length != 2) return null;
    final port = _int(record.items[0]);
    final parts = _tupleInts(record.items[1], 4, 0xff);
    if (port == null || port < 0 || port > 0xffff || parts == null) return null;
    return WASIPreview3IpSocketAddress.ipv4(
      port: port,
      a: parts[0],
      b: parts[1],
      c: parts[2],
      d: parts[3],
    );
  }
  if (value.label == 'ipv6' || (value.label == null && value.index == 1)) {
    if (record.items.length != 4) return null;
    final port = _int(record.items[0]);
    final flowInfo = _int(record.items[1]);
    final parts = _tupleInts(record.items[2], 8, 0xffff);
    final scopeId = _int(record.items[3]);
    if (port == null ||
        port < 0 ||
        port > 0xffff ||
        flowInfo == null ||
        flowInfo < 0 ||
        flowInfo > 0xffffffff ||
        parts == null ||
        scopeId == null ||
        scopeId < 0 ||
        scopeId > 0xffffffff) {
      return null;
    }
    return WASIPreview3IpSocketAddress.ipv6(
      port: port,
      a: parts[0],
      b: parts[1],
      c: parts[2],
      d: parts[3],
      e: parts[4],
      f: parts[5],
      g: parts[6],
      h: parts[7],
      flowInfo: flowInfo,
      scopeId: scopeId,
    );
  }
  return null;
}

_OptionalSocketAddress _optionalSocketAddress(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.option) {
    return const _OptionalSocketAddress(null, isInvalid: true);
  }
  final isSome = value.isSome ?? value.label == 'some' || value.index == 1;
  if (!isSome) return const _OptionalSocketAddress(null);
  final address = _socketAddress(value.associatedValue);
  return address == null
      ? const _OptionalSocketAddress(null, isInvalid: true)
      : _OptionalSocketAddress(address);
}

String? _addressError(
  WASIPreview3IpSocketAddress? address,
  WASIPreview3IpAddressFamily family, {
  required bool local,
  bool requireUnicast = false,
}) {
  if (address == null || address.family != family) return 'invalid-argument';
  if (_isIpv4Mapped(address.address)) return 'invalid-argument';
  if (requireUnicast &&
      !_isWildcard(address.address) &&
      !_isUnicast(address.address)) {
    return 'invalid-argument';
  }
  if (!local && (_isWildcard(address.address) || address.port == 0)) {
    return 'invalid-argument';
  }
  return null;
}

bool _isWildcard(WASIPreview3IpAddress address) =>
    address.parts.every((part) => part == 0);

bool _isLoopback(WASIPreview3IpAddress address) {
  final parts = address.parts;
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

bool _reservationInUse(
  Set<WASIPreview3IpSocketAddress> reservations,
  WASIPreview3IpSocketAddress address,
) {
  return reservations.any(
    (reserved) =>
        reserved.family == address.family &&
        reserved.port == address.port &&
        (reserved.address == address.address ||
            _isWildcard(reserved.address) ||
            _isWildcard(address.address)),
  );
}

bool _isUnicast(WASIPreview3IpAddress address) {
  final parts = address.parts;
  if (address.family == WASIPreview3IpAddressFamily.ipv4) {
    final first = parts[0];
    return first != 0 && first < 224 && !parts.every((part) => part == 0xff);
  }
  return (parts[0] & 0xff00) != 0xff00;
}

bool _isIpv4Mapped(WASIPreview3IpAddress address) {
  if (address.family != WASIPreview3IpAddressFamily.ipv6) return false;
  final parts = address.parts;
  return parts[0] == 0 &&
      parts[1] == 0 &&
      parts[2] == 0 &&
      parts[3] == 0 &&
      parts[4] == 0 &&
      parts[5] == 0xffff;
}

WASIPreview3IpSocketAddress _wildcard(WASIPreview3IpAddressFamily family) {
  return family == WASIPreview3IpAddressFamily.ipv4
      ? WASIPreview3IpSocketAddress.ipv4(port: 0, a: 0, b: 0, c: 0, d: 0)
      : WASIPreview3IpSocketAddress.ipv6(
          port: 0,
          a: 0,
          b: 0,
          c: 0,
          d: 0,
          e: 0,
          f: 0,
          g: 0,
          h: 0,
        );
}

WasmComponentValueData _familyData(WASIPreview3IpAddressFamily family) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.enumeration,
    rawBytes: Uint8List(0),
    index: family.index,
    label: family.name,
  );
}

WasmComponentValueData _ipAddressData(WASIPreview3IpAddress address) {
  return _variant(
    address.family.name,
    _tuple(<WasmComponentValueData>[
      for (final part in address.parts) _integer(part),
    ]),
  );
}

WasmComponentValueData _addressData(WASIPreview3IpSocketAddress address) {
  if (address.family == WASIPreview3IpAddressFamily.ipv4) {
    return _variant(
      'ipv4',
      _record(<WasmComponentValueData>[
        _integer(address.port),
        _tuple(<WasmComponentValueData>[
          for (final part in address.address.parts) _integer(part),
        ]),
      ]),
    );
  }
  return _variant(
    'ipv6',
    _record(<WasmComponentValueData>[
      _integer(address.port),
      _integer(address.flowInfo),
      _tuple(<WasmComponentValueData>[
        for (final part in address.address.parts) _integer(part),
      ]),
      _integer(address.scopeId),
    ]),
  );
}

WasmComponentValueData _ok([WasmComponentValueData? value]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: value,
  );
}

WasmComponentValueData _okPayload(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedPayload: value,
  );
}

WasmComponentValueData _error(String code) => _resultError(
  _socketErrorCodes.contains(code) ? code : 'other',
  otherMessage: _socketErrorCodes.contains(code) ? null : code,
);

WasmComponentValueData _dnsError(String code) => _resultError(
  _dnsErrorCodes.contains(code) ? code : 'other',
  otherMessage: _dnsErrorCodes.contains(code) ? null : code,
);

WasmComponentValueData _resultError(String code, {String? otherMessage}) {
  final payload = code == 'other'
      ? (otherMessage == null ? _none() : _some(_string(otherMessage)))
      : null;
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
    associatedValue: _variant(code, payload),
  );
}

WasmComponentValueData _variant(
  String label, [
  WasmComponentValueData? value,
]) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.variant,
  rawBytes: Uint8List(0),
  label: label,
  associatedValue: value,
);

WasmComponentValueData _record(List<WasmComponentValueData> items) =>
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.record,
      rawBytes: Uint8List(0),
      items: items,
    );

WasmComponentValueData _tuple(List<WasmComponentValueData> items) =>
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.tuple,
      rawBytes: Uint8List(0),
      items: items,
    );

WasmComponentValueData _list(List<WasmComponentValueData> items) =>
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.list,
      rawBytes: Uint8List(0),
      items: items,
    );

WasmComponentValueData _byteList(Iterable<int> bytes) =>
    _list(<WasmComponentValueData>[for (final byte in bytes) _integer(byte)]);

WasmComponentValueData _integer(Object value) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.integer,
  rawBytes: Uint8List(0),
  integer: value,
);

WasmComponentValueData _bool(bool value) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.boolean,
  rawBytes: Uint8List(0),
  boolean: value,
);

WasmComponentValueData _string(String value) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.string,
  rawBytes: Uint8List(0),
  string: value,
);

WasmComponentValueData _some(WasmComponentValueData value) =>
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.option,
      rawBytes: Uint8List(0),
      index: 1,
      label: 'some',
      isSome: true,
      associatedValue: value,
    );

WasmComponentValueData _none() => WasmComponentValueData(
  kind: WasmComponentValueDataKind.option,
  rawBytes: Uint8List(0),
  index: 0,
  label: 'none',
  isSome: false,
);

int _handle(Object? value) {
  final integer = value is WasmComponentValueData ? value.integer : value;
  if (integer is int && integer >= 0 && integer <= 0xffffffff) return integer;
  if (integer is BigInt &&
      integer >= BigInt.zero &&
      integer <= BigInt.from(0xffffffff)) {
    return integer.toInt();
  }
  throw StateError('WASI Preview3 socket handle must be u32.');
}

int _u8(Object? value) => _unsignedInt(value, 0xff, 'u8');
int _u32(Object? value) => _unsignedInt(value, 0xffffffff, 'u32');

int _unsignedInt(Object? value, int max, String type) {
  final parsed = _intValue(value);
  if (parsed is int && parsed >= 0 && parsed <= max) return parsed;
  if (parsed is BigInt && parsed >= BigInt.zero && parsed <= BigInt.from(max)) {
    return parsed.toInt();
  }
  throw StateError('WASI Preview3 socket value must be $type.');
}

BigInt _u64(Object? value) {
  final parsed = _intValue(value);
  final result = parsed is int ? BigInt.from(parsed) : parsed as BigInt?;
  if (result == null || result < BigInt.zero || result > _u64Max) {
    throw StateError('WASI Preview3 socket value must be u64.');
  }
  return result;
}

Object? _intValue(Object? value) =>
    value is WasmComponentValueData ? value.integer : value;

int? _int(Object? value) {
  final parsed = _intValue(value);
  if (parsed is int) return parsed;
  if (parsed is BigInt && parsed >= -_i64Max && parsed <= _i64Max) {
    return parsed.toInt();
  }
  return null;
}

List<int>? _tupleInts(Object? value, int count, int max) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.tuple ||
      value.items.length != count) {
    return null;
  }
  final result = <int>[];
  for (final item in value.items) {
    final part = _int(item);
    if (part == null || part < 0 || part > max) return null;
    result.add(part);
  }
  return result;
}

List<int>? _bytes(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.list) {
    return null;
  }
  final result = <int>[];
  for (final item in value.items) {
    final byte = _int(item);
    if (byte == null || byte < 0 || byte > 0xff) return null;
    result.add(byte);
  }
  return result;
}

int _part(int value, int max, String name) {
  if (value < 0 || value > max) {
    throw RangeError.range(value, 0, max, name);
  }
  return value;
}

int _boundedBacklog(BigInt backlog) {
  const max = 4096;
  return backlog > BigInt.from(max) ? max : backlog.toInt();
}

String? _toAsciiDnsName(String value) {
  if (value.isEmpty || value.contains('\u0000') || value.contains(':')) {
    return null;
  }
  final normalized = value
      .replaceAll('\u3002', '.')
      .replaceAll('\uff0e', '.')
      .replaceAll('\uff61', '.');
  final trailingDot = normalized.endsWith('.');
  final domain = trailingDot
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  if (domain.isEmpty) return null;
  final asciiLabels = <String>[];
  for (final label in domain.split('.')) {
    if (label.isEmpty) return null;
    final folded = label.toLowerCase();
    final runes = folded.runes.toList(growable: false);
    if (runes.isEmpty ||
        runes.first == 0x2d ||
        runes.last == 0x2d ||
        _isCombiningMark(runes.first)) {
      return null;
    }
    var hasNonAscii = false;
    for (final rune in runes) {
      if (rune <= 0x7f) {
        final valid =
            (rune >= 0x30 && rune <= 0x39) ||
            (rune >= 0x61 && rune <= 0x7a) ||
            rune == 0x2d;
        if (!valid) return null;
      } else {
        hasNonAscii = true;
        if (_invalidIdnaRune(rune)) return null;
      }
    }
    final ascii = hasNonAscii ? 'xn--${_punycodeEncode(runes)}' : folded;
    if (ascii.length > 63 ||
        (ascii.length >= 4 &&
            ascii[2] == '-' &&
            ascii[3] == '-' &&
            !ascii.startsWith('xn--'))) {
      return null;
    }
    asciiLabels.add(ascii);
  }
  final asciiDomain = asciiLabels.join('.');
  if (asciiDomain.length > 253) return null;
  return trailingDot ? '$asciiDomain.' : asciiDomain;
}

bool _invalidIdnaRune(int rune) {
  return rune > 0x10ffff ||
      (rune >= 0xd800 && rune <= 0xdfff) ||
      rune == 0x200b ||
      rune == 0x200c ||
      rune == 0x200d ||
      rune == 0x2060 ||
      rune == 0xfeff ||
      (rune >= 0x2000 && rune <= 0x200a) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202f ||
      rune == 0x205f ||
      rune == 0x3000;
}

bool _isCombiningMark(int rune) =>
    (rune >= 0x0300 && rune <= 0x036f) ||
    (rune >= 0x1ab0 && rune <= 0x1aff) ||
    (rune >= 0x1dc0 && rune <= 0x1dff) ||
    (rune >= 0x20d0 && rune <= 0x20ff) ||
    (rune >= 0xfe20 && rune <= 0xfe2f);

String _punycodeEncode(List<int> input) {
  const base = 36;
  const tMin = 1;
  const tMax = 26;
  const initialBias = 72;
  const initialCodePoint = 0x80;

  final output = StringBuffer();
  for (final codePoint in input) {
    if (codePoint < initialCodePoint) output.writeCharCode(codePoint);
  }
  final basicCount = output.length;
  var handled = basicCount;
  if (basicCount != 0) output.write('-');

  var codePoint = initialCodePoint;
  var delta = 0;
  var bias = initialBias;
  while (handled < input.length) {
    var next = 0x110000;
    for (final candidate in input) {
      if (candidate >= codePoint && candidate < next) next = candidate;
    }
    delta += (next - codePoint) * (handled + 1);
    codePoint = next;
    for (final candidate in input) {
      if (candidate < codePoint) delta++;
      if (candidate != codePoint) continue;
      var quotient = delta;
      for (var k = base; ; k += base) {
        final threshold = k <= bias
            ? tMin
            : k >= bias + tMax
            ? tMax
            : k - bias;
        if (quotient < threshold) break;
        output.write(
          _punycodeDigit(
            threshold + (quotient - threshold) % (base - threshold),
          ),
        );
        quotient = (quotient - threshold) ~/ (base - threshold);
      }
      output.write(_punycodeDigit(quotient));
      bias = _adaptPunycodeBias(delta, handled + 1, handled == basicCount);
      delta = 0;
      handled++;
    }
    delta++;
    codePoint++;
  }
  return output.toString();
}

int _adaptPunycodeBias(int delta, int codePointCount, bool firstTime) {
  const base = 36;
  const tMin = 1;
  const tMax = 26;
  const skew = 38;
  const damp = 700;

  var adapted = firstTime ? delta ~/ damp : delta ~/ 2;
  adapted += adapted ~/ codePointCount;
  var offset = 0;
  while (adapted > ((base - tMin) * tMax) ~/ 2) {
    adapted ~/= base - tMin;
    offset += base;
  }
  return offset + ((base - tMin + 1) * adapted) ~/ (adapted + skew);
}

String _punycodeDigit(int digit) =>
    String.fromCharCode(digit < 26 ? 0x61 + digit : 0x30 + digit - 26);

Iterable<WASIPreview3IpAddress> _defaultResolver(String name) {
  final literal = WASIPreview3IpAddress.parse(name);
  if (literal != null) return <WASIPreview3IpAddress>[literal];
  if (name.toLowerCase() == 'localhost') {
    return <WASIPreview3IpAddress>[
      WASIPreview3IpAddress.ipv6(0, 0, 0, 0, 0, 0, 0, 1),
      WASIPreview3IpAddress.ipv4(127, 0, 0, 1),
    ];
  }
  return const <WASIPreview3IpAddress>[];
}

WASIPreview3IpAddress? _parseIpv4(String value) {
  final fields = value.split('.');
  if (fields.length != 4) return null;
  final parts = <int>[];
  for (final field in fields) {
    if (field.isEmpty || !_decimal.hasMatch(field)) return null;
    final part = int.tryParse(field);
    if (part == null || part < 0 || part > 0xff) return null;
    parts.add(part);
  }
  return WASIPreview3IpAddress._(WASIPreview3IpAddressFamily.ipv4, parts);
}

WASIPreview3IpAddress? _parseIpv6(String value) {
  if (!value.contains(':') || value.contains('%') || value.contains(':::')) {
    return null;
  }
  final halves = value.split('::');
  if (halves.length > 2) return null;
  final compressed = halves.length == 2;
  final head = _ipv6Half(halves[0]);
  final tail = compressed ? _ipv6Half(halves[1]) : const <int>[];
  if (head == null || tail == null) return null;
  final zeros = 8 - head.length - tail.length;
  if ((!compressed && zeros != 0) || (compressed && zeros < 1)) return null;
  return WASIPreview3IpAddress._(WASIPreview3IpAddressFamily.ipv6, <int>[
    ...head,
    for (var i = 0; i < zeros; i++) 0,
    ...tail,
  ]);
}

List<int>? _ipv6Half(String value) {
  if (value.isEmpty) return const <int>[];
  final fields = value.split(':');
  final parts = <int>[];
  for (var index = 0; index < fields.length; index++) {
    final field = fields[index];
    if (field.isEmpty) return null;
    if (field.contains('.')) {
      if (index != fields.length - 1) return null;
      final ipv4 = _parseIpv4(field);
      if (ipv4 == null) return null;
      parts
        ..add((ipv4.parts[0] << 8) | ipv4.parts[1])
        ..add((ipv4.parts[2] << 8) | ipv4.parts[3]);
    } else {
      if (field.length > 4 || !_hex.hasMatch(field)) return null;
      parts.add(int.parse(field, radix: 16));
    }
  }
  return parts;
}

bool _listEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
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

const Set<String> _socketErrorCodes = <String>{
  'access-denied',
  'not-supported',
  'invalid-argument',
  'out-of-memory',
  'timeout',
  'invalid-state',
  'address-not-bindable',
  'address-in-use',
  'remote-unreachable',
  'connection-refused',
  'connection-broken',
  'connection-reset',
  'connection-aborted',
  'datagram-too-large',
  'other',
};

const Set<String> _dnsErrorCodes = <String>{
  'access-denied',
  'invalid-argument',
  'name-unresolvable',
  'temporary-resolver-failure',
  'permanent-resolver-failure',
  'other',
};

final BigInt _u64Max = (BigInt.one << 64) - BigInt.one;
final BigInt _i64Max = (BigInt.one << 63) - BigInt.one;
final RegExp _decimal = RegExp(r'^[0-9]+$');
final RegExp _hex = RegExp(r'^[0-9a-fA-F]+$');
