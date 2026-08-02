import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/resource_table.dart';
import '../component/wit_adapter.dart';
import 'io.dart';
import 'poll.dart';

/// Address family for WASI 0.2 sockets.
enum WASIPreview2IpAddressFamily {
  /// IPv4 socket/address family.
  ipv4,

  /// IPv6 socket/address family.
  ipv6,
}

/// IP address value returned by a Preview2 sockets resolver.
final class WASIPreview2IpAddress {
  /// Creates an IPv4 address.
  WASIPreview2IpAddress.ipv4(int a, int b, int c, int d)
    : family = WASIPreview2IpAddressFamily.ipv4,
      _parts = List<int>.unmodifiable(<int>[
        _validatePart(a, 0xff, 'a'),
        _validatePart(b, 0xff, 'b'),
        _validatePart(c, 0xff, 'c'),
        _validatePart(d, 0xff, 'd'),
      ]);

  /// Creates an IPv6 address from eight 16-bit segments.
  WASIPreview2IpAddress.ipv6(
    int a,
    int b,
    int c,
    int d,
    int e,
    int f,
    int g,
    int h,
  ) : family = WASIPreview2IpAddressFamily.ipv6,
      _parts = List<int>.unmodifiable(<int>[
        _validatePart(a, 0xffff, 'a'),
        _validatePart(b, 0xffff, 'b'),
        _validatePart(c, 0xffff, 'c'),
        _validatePart(d, 0xffff, 'd'),
        _validatePart(e, 0xffff, 'e'),
        _validatePart(f, 0xffff, 'f'),
        _validatePart(g, 0xffff, 'g'),
        _validatePart(h, 0xffff, 'h'),
      ]);

  WASIPreview2IpAddress._(this.family, Iterable<int> parts)
    : _parts = List<int>.unmodifiable(parts);

  /// Address family.
  final WASIPreview2IpAddressFamily family;

  final List<int> _parts;

  /// Address segments as 4 IPv4 octets or 8 IPv6 16-bit segments.
  List<int> get parts => _parts;

  WasmComponentValueData _toWit() {
    return _variantData(
      family == WASIPreview2IpAddressFamily.ipv4 ? 'ipv4' : 'ipv6',
      _tupleData([for (final part in _parts) _integerData(part)]),
    );
  }

  static WASIPreview2IpAddress? _parseLiteral(String name) {
    return _parseIpv4Literal(name) ?? _parseIpv6Literal(name);
  }
}

/// IP socket address used by WASI 0.2 sockets.
final class WASIPreview2IpSocketAddress {
  /// Creates an IPv4 socket address.
  WASIPreview2IpSocketAddress.ipv4({
    required int port,
    required int a,
    required int b,
    required int c,
    required int d,
  }) : this._(
         address: WASIPreview2IpAddress.ipv4(a, b, c, d),
         port: _validatePart(port, 0xffff, 'port'),
         flowInfo: 0,
         scopeId: 0,
       );

  /// Creates an IPv6 socket address.
  WASIPreview2IpSocketAddress.ipv6({
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
         address: WASIPreview2IpAddress.ipv6(a, b, c, d, e, f, g, h),
         port: _validatePart(port, 0xffff, 'port'),
         flowInfo: _validatePart(flowInfo, 0xffffffff, 'flowInfo'),
         scopeId: _validatePart(scopeId, 0xffffffff, 'scopeId'),
       );

  WASIPreview2IpSocketAddress._({
    required this.address,
    required this.port,
    required this.flowInfo,
    required this.scopeId,
  });

  /// IP address family.
  WASIPreview2IpAddressFamily get family => address.family;

  /// IP address.
  final WASIPreview2IpAddress address;

  /// TCP/UDP port.
  final int port;

  /// IPv6 flow information, or zero for IPv4.
  final int flowInfo;

  /// IPv6 scope id, or zero for IPv4.
  final int scopeId;

  /// Host string suitable for Dart networking APIs.
  String get host {
    final parts = address.parts;
    if (address.family == WASIPreview2IpAddressFamily.ipv4) {
      return parts.join('.');
    }
    return parts.map((part) => part.toRadixString(16)).join(':');
  }

  WasmComponentValueData _toWit() {
    final parts = address.parts;
    if (address.family == WASIPreview2IpAddressFamily.ipv4) {
      return _variantData(
        'ipv4',
        _recordData([
          _integerData(port),
          _tupleData([for (final part in parts) _integerData(part)]),
        ]),
      );
    }
    return _variantData(
      'ipv6',
      _recordData([
        _integerData(port),
        _integerData(flowInfo),
        _tupleData([for (final part in parts) _integerData(part)]),
        _integerData(scopeId),
      ]),
    );
  }

  static WASIPreview2IpSocketAddress? _fromWit(Object? value) {
    if (value is! WasmComponentValueData ||
        value.kind != WasmComponentValueDataKind.variant ||
        value.associatedValue == null) {
      return null;
    }
    final label = value.label;
    if (label == 'ipv4' || (label == null && value.index == 0)) {
      final record = value.associatedValue!;
      if (record.kind != WasmComponentValueDataKind.record ||
          record.items.length != 2) {
        return null;
      }
      final port = _u16Data(record.items[0]);
      final address = _u8Tuple(record.items[1], 4);
      if (port == null || address == null) {
        return null;
      }
      return WASIPreview2IpSocketAddress.ipv4(
        port: port,
        a: address[0],
        b: address[1],
        c: address[2],
        d: address[3],
      );
    }
    if (label == 'ipv6' || (label == null && value.index == 1)) {
      final record = value.associatedValue!;
      if (record.kind != WasmComponentValueDataKind.record ||
          record.items.length != 4) {
        return null;
      }
      final port = _u16Data(record.items[0]);
      final flowInfo = _u32Data(record.items[1]);
      final address = _u16Tuple(record.items[2], 8);
      final scopeId = _u32Data(record.items[3]);
      if (port == null ||
          flowInfo == null ||
          address == null ||
          scopeId == null) {
        return null;
      }
      return WASIPreview2IpSocketAddress.ipv6(
        port: port,
        a: address[0],
        b: address[1],
        c: address[2],
        d: address[3],
        e: address[4],
        f: address[5],
        g: address[6],
        h: address[7],
        flowInfo: flowInfo,
        scopeId: scopeId,
      );
    }
    return null;
  }
}

/// Resolves a WASI socket name to zero or more IP addresses.
typedef WASIPreview2AddressResolver =
    FutureOr<Iterable<WASIPreview2IpAddress>> Function(String name);

/// A standardized failure reported by a Preview2 address resolver.
final class WASIPreview2AddressResolverError implements Exception {
  /// Creates a resolver failure with a WASI sockets [errorCode].
  const WASIPreview2AddressResolverError(this.errorCode);

  /// WASI sockets error label returned by `resolve-next-address`.
  final String errorCode;
}

/// Result returned by a Preview2 sockets backend operation.
final class WASIPreview2SocketResult<T> {
  /// Successful socket operation.
  const WASIPreview2SocketResult.ok(this.value) : errorCode = null;

  /// Failed socket operation with a WASI `error-code` label.
  const WASIPreview2SocketResult.error(this.errorCode) : value = null;

  /// Success payload.
  final T? value;

  /// WASI `error-code` label on failure.
  final String? errorCode;

  /// Whether this result is successful.
  bool get isOk => errorCode == null;
}

/// Non-blocking operation used by Preview2 start/finish socket APIs.
final class WASIPreview2SocketOperation<T> {
  /// Creates an already-completed operation.
  WASIPreview2SocketOperation.completed(WASIPreview2SocketResult<T> result)
    : _result = result,
      _ready = null,
      _disposeValue = null;

  /// Creates an operation completed by [future].
  WASIPreview2SocketOperation.pending(
    Future<WASIPreview2SocketResult<T>> future, {
    void Function(T value)? disposeValue,
  }) : _ready = Completer<void>(),
       _disposeValue = disposeValue {
    future.then(
      (result) {
        if (_disposed) {
          _disposeResult(result);
        } else {
          _result = result;
        }
        _completeReady();
      },
      onError: (Object error) {
        if (!_disposed) {
          _result = WASIPreview2SocketResult<T>.error('unknown');
        }
        _completeReady();
      },
    );
  }

  WASIPreview2SocketResult<T>? _result;
  final Completer<void>? _ready;
  final void Function(T value)? _disposeValue;
  void Function(T value)? _fallbackDisposeValue;
  bool _disposed = false;

  /// Whether [resultOrNull] is available without blocking.
  bool get isReady => _result != null;

  /// Completed result, or null while pending.
  WASIPreview2SocketResult<T>? get resultOrNull => _result;

  /// Completes when the operation can be finished.
  Future<void> waitReady() {
    final ready = _ready;
    return ready == null || isReady ? Future<void>.value() : ready.future;
  }

  void _completeReady() {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }
  }

  /// Releases a pending result, using [disposeValue] as a fallback disposer.
  void dispose({void Function(T value)? disposeValue}) {
    if (_disposed) {
      return;
    }
    _fallbackDisposeValue = disposeValue;
    _disposed = true;
    final result = _result;
    _result = null;
    if (result != null) {
      _disposeResult(result);
    }
  }

  void _disposeResult(WASIPreview2SocketResult<T> result) {
    final value = result.value;
    if (value != null) {
      (_disposeValue ?? _fallbackDisposeValue)?.call(value);
    }
  }
}

/// Connected TCP streams returned by a sockets backend.
final class WASIPreview2TcpConnection {
  /// Creates a TCP connection model.
  const WASIPreview2TcpConnection({
    required this.inputStream,
    required this.outputStream,
    required this.localAddress,
    required this.remoteAddress,
    this.close,
    this.shutdown,
    this.dispose,
  });

  /// Input bytes received from the peer.
  final WASIPreview2InputStream inputStream;

  /// Output bytes written to the peer.
  final WASIPreview2OutputStream outputStream;

  /// Local socket address.
  final WASIPreview2IpSocketAddress localAddress;

  /// Remote socket address.
  final WASIPreview2IpSocketAddress remoteAddress;

  /// Optional close hook.
  final void Function(String shutdownType)? close;

  /// Optional shutdown hook which returns a WASI socket error label.
  final String? Function(String shutdownType)? shutdown;

  /// Optional hook used when the owning socket resource is dropped.
  final void Function()? dispose;
}

/// Optional backend capability marker for socket options.
///
/// Backends which implement this interface can explicitly reject options that
/// their underlying platform API cannot faithfully apply. Backends which do
/// not implement it retain the portable in-memory option model.
abstract interface class WASIPreview2SocketOptionsBackend {
  /// Whether TCP socket option getters and setters are implemented.
  bool get supportsTcpSocketOptions;

  /// Whether UDP socket option getters and setters are implemented.
  bool get supportsUdpSocketOptions;
}

/// Listening TCP socket returned by a sockets backend.
abstract interface class WASIPreview2TcpListener {
  /// Bound local address.
  WASIPreview2IpSocketAddress get localAddress;

  /// Whether [accept] can return a connection without `would-block`.
  bool get canAccept;

  /// Completes when [accept] may make progress.
  Future<void> waitAccept();

  /// Attempts to accept a queued connection.
  WASIPreview2SocketResult<WASIPreview2TcpConnection> accept();

  /// Closes the listener.
  void close();
}

/// Incoming UDP datagram returned by a sockets backend.
final class WASIPreview2IncomingDatagram {
  /// Creates an incoming datagram.
  const WASIPreview2IncomingDatagram({
    required this.data,
    required this.remoteAddress,
  });

  /// Datagram payload.
  final Uint8List data;

  /// Sender address.
  final WASIPreview2IpSocketAddress remoteAddress;
}

/// Outgoing UDP datagram passed to a sockets backend.
final class WASIPreview2OutgoingDatagram {
  /// Creates an outgoing datagram.
  const WASIPreview2OutgoingDatagram({required this.data, this.remoteAddress});

  /// Datagram payload.
  final Uint8List data;

  /// Destination address, or null to use the connected peer.
  final WASIPreview2IpSocketAddress? remoteAddress;
}

/// Bound UDP socket returned by a sockets backend.
abstract interface class WASIPreview2UdpBinding {
  /// Bound local address.
  WASIPreview2IpSocketAddress get localAddress;

  /// Connected remote address, if the backend has one.
  WASIPreview2IpSocketAddress? get remoteAddress;

  /// Max datagrams accepted by one `send` call.
  BigInt get sendCapacity;

  /// Whether a receive operation can make progress.
  bool get canReceive;

  /// Whether a send operation can make progress.
  bool get canSend;

  /// Completes when receive may make progress.
  Future<void> waitReceive();

  /// Completes when send may make progress.
  Future<void> waitSend();

  /// Receives up to [maxResults] datagrams.
  WASIPreview2SocketResult<List<WASIPreview2IncomingDatagram>> receive(
    BigInt maxResults,
  );

  /// Sends [datagrams].
  WASIPreview2SocketResult<BigInt> send(
    List<WASIPreview2OutgoingDatagram> datagrams,
  );

  /// Closes the binding.
  void close();
}

/// Backend used by [WASIPreview2SocketsHost] for real socket I/O.
abstract interface class WASIPreview2SocketsBackend {
  /// Starts TCP bind.
  WASIPreview2SocketOperation<WASIPreview2IpSocketAddress> startTcpBind(
    WASIPreview2IpSocketAddress localAddress,
  );

  /// Starts TCP connect.
  WASIPreview2SocketOperation<WASIPreview2TcpConnection> startTcpConnect({
    required WASIPreview2IpSocketAddress remoteAddress,
    WASIPreview2IpSocketAddress? localAddress,
  });

  /// Starts TCP listen.
  WASIPreview2SocketOperation<WASIPreview2TcpListener> startTcpListen({
    required WASIPreview2IpSocketAddress localAddress,
    required BigInt backlog,
  });

  /// Starts UDP bind.
  WASIPreview2SocketOperation<WASIPreview2UdpBinding> startUdpBind(
    WASIPreview2IpSocketAddress localAddress,
  );
}

/// Backend that reports unsupported for OS socket operations.
final class WASIPreview2UnsupportedSocketsBackend
    implements WASIPreview2SocketsBackend {
  /// Creates the default unsupported sockets backend.
  const WASIPreview2UnsupportedSocketsBackend();

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
    return WASIPreview2SocketOperation<WASIPreview2TcpConnection>.completed(
      const WASIPreview2SocketResult<WASIPreview2TcpConnection>.error(
        'not-supported',
      ),
    );
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2TcpListener> startTcpListen({
    required WASIPreview2IpSocketAddress localAddress,
    required BigInt backlog,
  }) {
    return WASIPreview2SocketOperation<WASIPreview2TcpListener>.completed(
      const WASIPreview2SocketResult<WASIPreview2TcpListener>.error(
        'not-supported',
      ),
    );
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2UdpBinding> startUdpBind(
    WASIPreview2IpSocketAddress localAddress,
  ) {
    return WASIPreview2SocketOperation<WASIPreview2UdpBinding>.completed(
      const WASIPreview2SocketResult<WASIPreview2UdpBinding>.error(
        'not-supported',
      ),
    );
  }
}

/// WASI 0.2 `wasi:sockets` host imports.
base class WASIPreview2SocketsHost {
  /// Creates a sockets host backed by [table] or [pollHost].
  WASIPreview2SocketsHost({
    WASIComponentResourceTable? table,
    WASIPreview2PollHost? pollHost,
    WASIPreview2StreamsHost? streamsHost,
    WASIPreview2AddressResolver? resolveAddresses,
    WASIPreview2SocketsBackend? backend,
  }) : this._resolved(
         _resolveSocketsHostParts(table, pollHost, streamsHost),
         resolveAddresses: resolveAddresses,
         backend: backend,
       );

  WASIPreview2SocketsHost._resolved(
    _ResolvedSocketsHostParts parts, {
    WASIPreview2AddressResolver? resolveAddresses,
    WASIPreview2SocketsBackend? backend,
  }) : this._(
         table: parts.table,
         pollHost: parts.pollHost,
         streamsHost: parts.streamsHost,
         resolveAddresses: resolveAddresses ?? _defaultAddressResolver,
         backend: backend ?? const WASIPreview2UnsupportedSocketsBackend(),
       );

  WASIPreview2SocketsHost._({
    required this.table,
    required this.pollHost,
    required this.streamsHost,
    required WASIPreview2AddressResolver resolveAddresses,
    required WASIPreview2SocketsBackend backend,
  }) : _resolveAddresses = resolveAddresses,
       _backend = backend;

  /// Component resource table that owns sockets resources.
  final WASIComponentResourceTable table;

  /// Poll host used by sockets `subscribe` operations.
  final WASIPreview2PollHost pollHost;

  /// Streams host used by connected TCP streams.
  final WASIPreview2StreamsHost streamsHost;

  final WASIPreview2AddressResolver _resolveAddresses;
  final WASIPreview2SocketsBackend _backend;

  late final WASIComponentResourceType<_WASIPreview2Network> _networkType =
      table.defineType<_WASIPreview2Network>(
        'wasi:sockets/network@0.2.0.network',
      );

  late final WASIComponentResourceType<_WASIPreview2ResolveAddressStream>
  _resolveAddressStreamType = table
      .defineType<_WASIPreview2ResolveAddressStream>(
        'wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream',
      );

  late final WASIComponentResourceType<_WASIPreview2TcpSocket> _tcpSocketType =
      table.defineType<_WASIPreview2TcpSocket>(
        'wasi:sockets/tcp@0.2.0.tcp-socket',
        onDrop: _dropTcpSocket,
      );

  late final WASIComponentResourceType<_WASIPreview2UdpSocket> _udpSocketType =
      table.defineType<_WASIPreview2UdpSocket>(
        'wasi:sockets/udp@0.2.0.udp-socket',
        onDrop: _dropUdpSocket,
      );

  late final WASIComponentResourceType<_WASIPreview2IncomingDatagramStream>
  _incomingDatagramStreamType = table
      .defineType<_WASIPreview2IncomingDatagramStream>(
        'wasi:sockets/udp@0.2.0.incoming-datagram-stream',
        onDrop: (stream) => stream.generation.release(),
      );

  late final WASIComponentResourceType<_WASIPreview2OutgoingDatagramStream>
  _outgoingDatagramStreamType = table
      .defineType<_WASIPreview2OutgoingDatagramStream>(
        'wasi:sockets/udp@0.2.0.outgoing-datagram-stream',
        onDrop: (stream) => stream.generation.release(),
      );

  /// Standard `wasi:sockets@0.2.0` import callbacks.
  late final Map<String, WASIComponentWitAdapterCallback>
  imports = Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
    'wasi:sockets/instance-network@0.2.0.instance-network': (_) =>
        _instanceNetwork(),
    'wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses': (args) =>
        _resolve(_handle(args[0]), args[1] as String),
    'wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address':
        (args) => _resolveNextAddress(_handle(args[0])),
    'wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.subscribe':
        (args) => _subscribeResolveStream(_handle(args[0])),
    'wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket': (args) =>
        _createTcpSocket(args[0]),
    'wasi:sockets/tcp@0.2.0.tcp-socket.start-bind': (args) =>
        _tcpStartBind(_handle(args[0]), _handle(args[1]), args[2]),
    'wasi:sockets/tcp@0.2.0.tcp-socket.finish-bind': (args) =>
        _tcpFinishBind(_handle(args[0])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.start-connect': (args) =>
        _tcpStartConnect(_handle(args[0]), _handle(args[1]), args[2]),
    'wasi:sockets/tcp@0.2.0.tcp-socket.finish-connect': (args) =>
        _tcpFinishConnect(_handle(args[0])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.start-listen': (args) =>
        _tcpStartListen(_handle(args[0])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.finish-listen': (args) =>
        _tcpFinishListen(_handle(args[0])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.accept': (args) =>
        _tcpAccept(_handle(args[0])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.local-address': (args) =>
        _tcpLocalAddress(_handle(args[0])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.remote-address': (args) =>
        _tcpRemoteAddress(_handle(args[0])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.is-listening': (args) =>
        _tcpIsListening(_handle(args[0])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.address-family': (args) =>
        _tcpAddressFamily(_handle(args[0])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.set-listen-backlog-size': (args) =>
        _tcpSetPositiveU64(_handle(args[0]), _u64(args[1])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.keep-alive-enabled': (args) =>
        _tcpBoolOption(_handle(args[0]), (socket) => socket.keepAlive),
    'wasi:sockets/tcp@0.2.0.tcp-socket.set-keep-alive-enabled': (args) =>
        _tcpSetBoolOption(
          _handle(args[0]),
          args[1] as bool,
          (socket, value) => socket.keepAlive = value,
        ),
    'wasi:sockets/tcp@0.2.0.tcp-socket.keep-alive-idle-time': (args) =>
        _tcpU64Option(_handle(args[0]), (socket) => socket.keepAliveIdle),
    'wasi:sockets/tcp@0.2.0.tcp-socket.set-keep-alive-idle-time': (args) =>
        _tcpSetU64Option(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.keepAliveIdle = value,
        ),
    'wasi:sockets/tcp@0.2.0.tcp-socket.keep-alive-interval': (args) =>
        _tcpU64Option(_handle(args[0]), (socket) => socket.keepAliveInterval),
    'wasi:sockets/tcp@0.2.0.tcp-socket.set-keep-alive-interval': (args) =>
        _tcpSetU64Option(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.keepAliveInterval = value,
        ),
    'wasi:sockets/tcp@0.2.0.tcp-socket.keep-alive-count': (args) =>
        _tcpU32Option(_handle(args[0]), (socket) => socket.keepAliveCount),
    'wasi:sockets/tcp@0.2.0.tcp-socket.set-keep-alive-count': (args) =>
        _tcpSetU32Option(
          _handle(args[0]),
          _u32(args[1]),
          (socket, value) => socket.keepAliveCount = value,
        ),
    'wasi:sockets/tcp@0.2.0.tcp-socket.hop-limit': (args) =>
        _tcpU8Option(_handle(args[0]), (socket) => socket.hopLimit),
    'wasi:sockets/tcp@0.2.0.tcp-socket.set-hop-limit': (args) =>
        _tcpSetU8Option(
          _handle(args[0]),
          _u8(args[1]),
          (socket, value) => socket.hopLimit = value,
        ),
    'wasi:sockets/tcp@0.2.0.tcp-socket.receive-buffer-size': (args) =>
        _tcpU64Option(_handle(args[0]), (socket) => socket.receiveBuffer),
    'wasi:sockets/tcp@0.2.0.tcp-socket.set-receive-buffer-size': (args) =>
        _tcpSetU64Option(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.receiveBuffer = value,
        ),
    'wasi:sockets/tcp@0.2.0.tcp-socket.send-buffer-size': (args) =>
        _tcpU64Option(_handle(args[0]), (socket) => socket.sendBuffer),
    'wasi:sockets/tcp@0.2.0.tcp-socket.set-send-buffer-size': (args) =>
        _tcpSetU64Option(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.sendBuffer = value,
        ),
    'wasi:sockets/tcp@0.2.0.tcp-socket.subscribe': (args) =>
        _tcpSubscribe(_handle(args[0])),
    'wasi:sockets/tcp@0.2.0.tcp-socket.shutdown': (args) =>
        _tcpShutdown(_handle(args[0]), args[1]),
    'wasi:sockets/udp-create-socket@0.2.0.create-udp-socket': (args) =>
        _createUdpSocket(args[0]),
    'wasi:sockets/udp@0.2.0.udp-socket.start-bind': (args) =>
        _udpStartBind(_handle(args[0]), _handle(args[1]), args[2]),
    'wasi:sockets/udp@0.2.0.udp-socket.finish-bind': (args) =>
        _udpFinishBind(_handle(args[0])),
    'wasi:sockets/udp@0.2.0.udp-socket.stream': (args) =>
        _udpStream(_handle(args[0]), args[1]),
    'wasi:sockets/udp@0.2.0.udp-socket.local-address': (args) =>
        _udpLocalAddress(_handle(args[0])),
    'wasi:sockets/udp@0.2.0.udp-socket.remote-address': (args) =>
        _udpRemoteAddress(_handle(args[0])),
    'wasi:sockets/udp@0.2.0.udp-socket.address-family': (args) =>
        _udpAddressFamily(_handle(args[0])),
    'wasi:sockets/udp@0.2.0.udp-socket.unicast-hop-limit': (args) =>
        _udpU8Option(_handle(args[0]), (socket) => socket.hopLimit),
    'wasi:sockets/udp@0.2.0.udp-socket.set-unicast-hop-limit': (args) =>
        _udpSetU8Option(
          _handle(args[0]),
          _u8(args[1]),
          (socket, value) => socket.hopLimit = value,
        ),
    'wasi:sockets/udp@0.2.0.udp-socket.receive-buffer-size': (args) =>
        _udpU64Option(_handle(args[0]), (socket) => socket.receiveBuffer),
    'wasi:sockets/udp@0.2.0.udp-socket.set-receive-buffer-size': (args) =>
        _udpSetU64Option(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.receiveBuffer = value,
        ),
    'wasi:sockets/udp@0.2.0.udp-socket.send-buffer-size': (args) =>
        _udpU64Option(_handle(args[0]), (socket) => socket.sendBuffer),
    'wasi:sockets/udp@0.2.0.udp-socket.set-send-buffer-size': (args) =>
        _udpSetU64Option(
          _handle(args[0]),
          _u64(args[1]),
          (socket, value) => socket.sendBuffer = value,
        ),
    'wasi:sockets/udp@0.2.0.udp-socket.subscribe': (args) =>
        _udpSubscribe(_handle(args[0])),
    'wasi:sockets/udp@0.2.0.incoming-datagram-stream.receive': (args) =>
        _receiveDatagrams(_handle(args[0]), _u64(args[1])),
    'wasi:sockets/udp@0.2.0.incoming-datagram-stream.subscribe': (args) =>
        _incomingDatagramSubscribe(_handle(args[0])),
    'wasi:sockets/udp@0.2.0.outgoing-datagram-stream.check-send': (args) =>
        _checkDatagramSend(_handle(args[0])),
    'wasi:sockets/udp@0.2.0.outgoing-datagram-stream.send': (args) =>
        _sendDatagrams(_handle(args[0]), args[1]),
    'wasi:sockets/udp@0.2.0.outgoing-datagram-stream.subscribe': (args) =>
        _outgoingDatagramSubscribe(_handle(args[0])),
  });

  int _instanceNetwork() {
    return table.insert<_WASIPreview2Network>(
      _networkType,
      const _WASIPreview2Network(0),
    );
  }

  WasmComponentValueData _resolve(int networkHandle, String name) {
    if (_network(networkHandle) == null) {
      return _errorResult('invalid-argument');
    }
    final literal = WASIPreview2IpAddress._parseLiteral(name);
    final resolverName = literal == null ? _toAsciiDomainName(name) : null;
    if (literal == null && resolverName == null) {
      return _errorResult('invalid-argument');
    }
    _WASIPreview2ResolveAddressStream stream;
    try {
      stream = _WASIPreview2ResolveAddressStream(
        literal == null
            ? _resolveAddresses(resolverName!)
            : <WASIPreview2IpAddress>[literal],
      );
    } on Object catch (error) {
      stream = _WASIPreview2ResolveAddressStream.failed(
        _addressResolverErrorCode(error),
      );
    }
    final handle = table.insert<_WASIPreview2ResolveAddressStream>(
      _resolveAddressStreamType,
      stream,
    );
    return _ok(_integerData(handle));
  }

  WasmComponentValueData _resolveNextAddress(int handle) {
    final stream = _resolveAddressStream(handle);
    if (stream == null) {
      return _errorResult('invalid-argument');
    }
    final result = stream.next();
    if (!result.isOk) {
      return _errorResult(result.errorCode!);
    }
    final address = result.value;
    return _ok(address == null ? _none() : _some(address._toWit()));
  }

  int _subscribeResolveStream(int handle) {
    final stream = _requireResolveAddressStream(handle);
    final pollable = pollHost.insert(
      WASIPreview2Pollable(
        isReady: () => stream.isReady,
        waitReady: stream.waitReady,
      ),
    );
    table.attachChild(handle, pollable);
    return pollable;
  }

  WasmComponentValueData _createTcpSocket(Object? familyValue) {
    final family = _addressFamilyFromData(familyValue);
    if (family == null) {
      return _errorResult('invalid-argument');
    }
    final handle = table.insert<_WASIPreview2TcpSocket>(
      _tcpSocketType,
      _WASIPreview2TcpSocket(family),
    );
    return _ok(_integerData(handle));
  }

  WasmComponentValueData _createUdpSocket(Object? familyValue) {
    final family = _addressFamilyFromData(familyValue);
    if (family == null) {
      return _errorResult('invalid-argument');
    }
    final handle = table.insert<_WASIPreview2UdpSocket>(
      _udpSocketType,
      _WASIPreview2UdpSocket(family),
    );
    return _ok(_integerData(handle));
  }

  WasmComponentValueData _tcpStartBind(
    int handle,
    int networkHandle,
    Object? addressValue,
  ) {
    final socket = _tcpSocket(handle);
    final network = _network(networkHandle);
    if (socket == null || network == null) {
      return _errorResult('invalid-argument');
    }
    final address = _ipSocketAddressFromData(addressValue);
    if (address == null || address.family != socket.family) {
      return _errorResult('invalid-argument');
    }
    if (socket.state != _TcpSocketState.unbound) {
      return _errorResult('invalid-state');
    }
    final operation = _backend.startTcpBind(address);
    final immediate = operation.resultOrNull;
    if (immediate != null && !immediate.isOk) {
      operation.dispose();
      return _errorResult(immediate.errorCode!);
    }
    socket.pendingBind = operation;
    socket.pendingNetworkId = network.id;
    socket.state = _TcpSocketState.binding;
    return _ok();
  }

  WasmComponentValueData _tcpFinishBind(int handle) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    final operation = socket.pendingBind;
    if (operation == null) {
      return _errorResult('not-in-progress');
    }
    final result = operation.resultOrNull;
    if (result == null) {
      return _errorResult('would-block');
    }
    socket.pendingBind = null;
    if (!result.isOk) {
      socket.pendingNetworkId = null;
      socket.state = _TcpSocketState.unbound;
      return _errorResult(result.errorCode!);
    }
    socket.localAddress = result.value!._toWit();
    socket.networkId = socket.pendingNetworkId;
    socket.pendingNetworkId = null;
    socket.state = _TcpSocketState.bound;
    return _ok();
  }

  WasmComponentValueData _tcpStartConnect(
    int handle,
    int networkHandle,
    Object? addressValue,
  ) {
    final socket = _tcpSocket(handle);
    final network = _network(networkHandle);
    if (socket == null || network == null) {
      return _errorResult('invalid-argument');
    }
    final address = _ipSocketAddressFromData(addressValue);
    if (address == null ||
        address.family != socket.family ||
        !_isValidTcpRemoteAddress(address)) {
      return _errorResult('invalid-argument');
    }
    if (socket.state != _TcpSocketState.unbound &&
        socket.state != _TcpSocketState.bound) {
      return _errorResult('invalid-state');
    }
    if (socket.networkId case final networkId? when networkId != network.id) {
      return _errorResult('invalid-argument');
    }
    socket.pendingConnect = _backend.startTcpConnect(
      localAddress: socket.localAddressAddress,
      remoteAddress: address,
    );
    socket.pendingNetworkId = network.id;
    socket.state = _TcpSocketState.connecting;
    return _ok();
  }

  WasmComponentValueData _tcpFinishConnect(int handle) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    final operation = socket.pendingConnect;
    if (operation == null) {
      return _errorResult('not-in-progress');
    }
    final result = operation.resultOrNull;
    if (result == null) {
      return _errorResult('would-block');
    }
    socket.pendingConnect = null;
    if (!result.isOk) {
      socket.pendingNetworkId = null;
      socket.state = _TcpSocketState.closed;
      return _errorResult(result.errorCode!);
    }
    final connection = result.value!;
    final input = streamsHost.insertInputStream(connection.inputStream);
    final output = streamsHost.insertOutputStream(connection.outputStream);
    table.attachChild(handle, input);
    table.attachChild(handle, output);
    socket.connection = connection;
    socket.localAddress = connection.localAddress._toWit();
    socket.remoteAddress = connection.remoteAddress._toWit();
    socket.networkId = socket.pendingNetworkId;
    socket.pendingNetworkId = null;
    socket.state = _TcpSocketState.connected;
    return _ok(_tupleData([_integerData(input), _integerData(output)]));
  }

  WasmComponentValueData _tcpStartListen(int handle) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (socket.state != _TcpSocketState.bound) {
      return _errorResult('invalid-state');
    }
    final localAddress = socket.localAddressAddress;
    if (localAddress == null) {
      return _errorResult('invalid-state');
    }
    socket.pendingListen = _backend.startTcpListen(
      localAddress: localAddress,
      backlog: socket.listenBacklog,
    );
    socket.state = _TcpSocketState.listeningStarting;
    return _ok();
  }

  WasmComponentValueData _tcpFinishListen(int handle) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    final operation = socket.pendingListen;
    if (operation == null) {
      return _errorResult('not-in-progress');
    }
    final result = operation.resultOrNull;
    if (result == null) {
      return _errorResult('would-block');
    }
    socket.pendingListen = null;
    if (!result.isOk) {
      socket.state = _TcpSocketState.bound;
      return _errorResult(result.errorCode!);
    }
    socket.listener = result.value!;
    socket.localAddress = result.value!.localAddress._toWit();
    socket.state = _TcpSocketState.listening;
    return _ok();
  }

  WasmComponentValueData _tcpAccept(int handle) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (socket.state != _TcpSocketState.listening || socket.listener == null) {
      return _errorResult('invalid-state');
    }
    final result = socket.listener!.accept();
    if (!result.isOk) {
      return _errorResult(result.errorCode!);
    }
    final connection = result.value!;
    final acceptedSocket = table.insert<_WASIPreview2TcpSocket>(
      _tcpSocketType,
      _WASIPreview2TcpSocket.connected(socket.family, connection),
    );
    final input = streamsHost.insertInputStream(connection.inputStream);
    final output = streamsHost.insertOutputStream(connection.outputStream);
    table.attachChild(acceptedSocket, input);
    table.attachChild(acceptedSocket, output);
    return _ok(
      _tupleData([
        _integerData(acceptedSocket),
        _integerData(input),
        _integerData(output),
      ]),
    );
  }

  WasmComponentValueData _tcpLocalAddress(int handle) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    final address = socket.localAddress;
    return address == null ? _errorResult('invalid-state') : _ok(address);
  }

  WasmComponentValueData _tcpRemoteAddress(int handle) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    final address = socket.remoteAddress;
    return address == null ? _errorResult('invalid-state') : _ok(address);
  }

  WasmComponentValueData _tcpShutdown(int handle, Object? shutdownType) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (socket.state != _TcpSocketState.connected) {
      return _errorResult('invalid-state');
    }
    final type = _caseLabelFromData(shutdownType);
    if (type != 'receive' && type != 'send' && type != 'both') {
      return _errorResult('invalid-argument');
    }
    final connection = socket.connection;
    if (connection == null) {
      return _errorResult('invalid-state');
    }
    final shutdown = connection.shutdown;
    if (shutdown != null) {
      final error = shutdown(type);
      return error == null ? _ok() : _errorResult(error);
    }
    if (type != 'both') {
      return _errorResult('not-supported');
    }
    connection.close?.call(type);
    connection.inputStream.close();
    connection.outputStream.close();
    return _ok();
  }

  WasmComponentValueData _udpStartBind(
    int handle,
    int networkHandle,
    Object? addressValue,
  ) {
    final socket = _udpSocket(handle);
    final network = _network(networkHandle);
    if (socket == null || network == null) {
      return _errorResult('invalid-argument');
    }
    final address = _ipSocketAddressFromData(addressValue);
    if (address == null || address.family != socket.family) {
      return _errorResult('invalid-argument');
    }
    if (socket.bound || socket.pendingBind != null) {
      return _errorResult('invalid-state');
    }
    socket.pendingBind = _backend.startUdpBind(address);
    socket.pendingNetworkId = network.id;
    return _ok();
  }

  WasmComponentValueData _udpFinishBind(int handle) {
    final socket = _udpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    final operation = socket.pendingBind;
    if (operation == null) {
      return _errorResult('not-in-progress');
    }
    final result = operation.resultOrNull;
    if (result == null) {
      return _errorResult('would-block');
    }
    socket.pendingBind = null;
    if (!result.isOk) {
      socket.pendingNetworkId = null;
      return _errorResult(result.errorCode!);
    }
    socket.binding = result.value!;
    socket.bound = true;
    socket.networkId = socket.pendingNetworkId;
    socket.pendingNetworkId = null;
    socket.localAddress = result.value!.localAddress._toWit();
    return _ok();
  }

  WasmComponentValueData _udpStream(int handle, Object? remoteAddressValue) {
    final socket = _udpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    final binding = socket.binding;
    if (!socket.bound || binding == null) {
      return _errorResult('invalid-state');
    }
    final remoteAddressResult = _optionalIpSocketAddressFromData(
      remoteAddressValue,
    );
    final remoteAddress = remoteAddressResult.address;
    if (!remoteAddressResult.valid ||
        (remoteAddress != null &&
            (remoteAddress.family != socket.family ||
                !_isValidUdpRemoteAddress(remoteAddress)))) {
      return _errorResult('invalid-argument');
    }
    socket.remoteAddress = remoteAddress?._toWit();
    socket.streamGeneration?.invalidate();
    final generation = _WASIPreview2UdpStreamGeneration();
    socket.streamGeneration = generation;
    final incoming = table.insert<_WASIPreview2IncomingDatagramStream>(
      _incomingDatagramStreamType,
      _WASIPreview2IncomingDatagramStream(binding, remoteAddress, generation),
    );
    final outgoing = table.insert<_WASIPreview2OutgoingDatagramStream>(
      _outgoingDatagramStreamType,
      _WASIPreview2OutgoingDatagramStream(binding, remoteAddress, generation),
    );
    table.attachChild(handle, incoming);
    table.attachChild(handle, outgoing);
    return _ok(_tupleData([_integerData(incoming), _integerData(outgoing)]));
  }

  WasmComponentValueData _udpLocalAddress(int handle) {
    final socket = _udpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    final address = socket.localAddress;
    return address == null ? _errorResult('invalid-state') : _ok(address);
  }

  WasmComponentValueData _udpRemoteAddress(int handle) {
    final socket = _udpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    final address = socket.remoteAddress;
    return address == null ? _errorResult('invalid-state') : _ok(address);
  }

  WasmComponentValueData _receiveDatagrams(int handle, BigInt maxResults) {
    final stream = _incomingDatagramStream(handle);
    if (stream == null) {
      return _errorResult('invalid-argument');
    }
    if (!stream.generation.isActive) {
      return _errorResult('invalid-state');
    }
    final result = stream.binding.receive(maxResults);
    if (!result.isOk) {
      return _errorResult(result.errorCode!);
    }
    final remoteFilter = stream.remoteAddress;
    final datagrams = remoteFilter == null
        ? result.value!
        : result.value!
              .where(
                (datagram) =>
                    _sameAddress(datagram.remoteAddress, remoteFilter),
              )
              .toList(growable: false);
    return _ok(
      _listData([
        for (final datagram in datagrams)
          _recordData([
            _u8ListData(datagram.data),
            datagram.remoteAddress._toWit(),
          ]),
      ]),
    );
  }

  WasmComponentValueData _checkDatagramSend(int handle) {
    final stream = _outgoingDatagramStream(handle);
    if (stream == null) {
      return _errorResult('invalid-argument');
    }
    if (!stream.generation.isActive) {
      return _errorResult('invalid-state');
    }
    final permit = stream.binding.canSend
        ? stream.binding.sendCapacity
        : BigInt.zero;
    stream.sendPermit = permit;
    return _ok(_integerData(permit));
  }

  WasmComponentValueData _sendDatagrams(int handle, Object? value) {
    final stream = _outgoingDatagramStream(handle);
    if (stream == null) {
      return _errorResult('invalid-argument');
    }
    if (!stream.generation.isActive) {
      return _errorResult('invalid-state');
    }
    final permit = stream.sendPermit;
    if (permit == null) {
      throw StateError('send requires a preceding check-send');
    }
    stream.sendPermit = null;
    if (value is WasmComponentValueData &&
        value.kind == WasmComponentValueDataKind.list &&
        BigInt.from(value.items.length) > permit) {
      throw StateError('send exceeds the preceding check-send permit');
    }
    final datagrams = _outgoingDatagramsFromData(
      value,
      stream.remoteAddress,
      stream.binding.localAddress.family,
    );
    if (datagrams == null) {
      return _errorResult('invalid-argument');
    }
    var sent = BigInt.zero;
    for (final datagram in datagrams) {
      final result = stream.binding.send(<WASIPreview2OutgoingDatagram>[
        datagram,
      ]);
      if (!result.isOk) {
        return sent == BigInt.zero
            ? _errorResult(result.errorCode!)
            : _ok(_integerData(sent));
      }
      if (result.value == BigInt.zero) {
        break;
      }
      if (result.value != BigInt.one) {
        return sent == BigInt.zero
            ? _errorResult('unknown')
            : _ok(_integerData(sent));
      }
      sent += BigInt.one;
    }
    return _ok(_integerData(sent));
  }

  bool _tcpIsListening(int handle) {
    return _requireTcpSocket(handle).state == _TcpSocketState.listening;
  }

  WasmComponentValueData _tcpAddressFamily(int handle) {
    return _addressFamilyData(_requireTcpSocket(handle).family);
  }

  int _tcpSubscribe(int handle) {
    final socket = _requireTcpSocket(handle);
    final pollable = pollHost.insert(
      WASIPreview2Pollable(
        isReady: () => _tcpSocketReady(socket),
        waitReady: () => _waitTcpSocketReady(socket),
      ),
    );
    table.attachChild(handle, pollable);
    return pollable;
  }

  WasmComponentValueData _udpAddressFamily(int handle) {
    return _addressFamilyData(_requireUdpSocket(handle).family);
  }

  int _udpSubscribe(int handle) {
    final socket = _requireUdpSocket(handle);
    final pollable = pollHost.insert(
      WASIPreview2Pollable(
        isReady: () => _udpSocketReady(socket),
        waitReady: () => _waitUdpSocketReady(socket),
      ),
    );
    table.attachChild(handle, pollable);
    return pollable;
  }

  int _incomingDatagramSubscribe(int handle) {
    final stream = _requireIncomingDatagramStream(handle);
    final pollable = pollHost.insert(
      WASIPreview2Pollable(
        isReady: () => !stream.generation.isActive || stream.binding.canReceive,
        waitReady: () => stream.generation.isActive
            ? Future.any<void>([
                stream.binding.waitReceive(),
                stream.generation.waitInactive(),
              ])
            : Future<void>.value(),
      ),
    );
    table.attachChild(handle, pollable);
    return pollable;
  }

  int _outgoingDatagramSubscribe(int handle) {
    final stream = _requireOutgoingDatagramStream(handle);
    final pollable = pollHost.insert(
      WASIPreview2Pollable(
        isReady: () => !stream.generation.isActive || stream.binding.canSend,
        waitReady: () => stream.generation.isActive
            ? Future.any<void>([
                stream.binding.waitSend(),
                stream.generation.waitInactive(),
              ])
            : Future<void>.value(),
      ),
    );
    table.attachChild(handle, pollable);
    return pollable;
  }

  bool _tcpSocketReady(_WASIPreview2TcpSocket socket) {
    return switch (socket.state) {
      _TcpSocketState.binding => socket.pendingBind?.isReady ?? true,
      _TcpSocketState.connecting => socket.pendingConnect?.isReady ?? true,
      _TcpSocketState.listeningStarting =>
        socket.pendingListen?.isReady ?? true,
      _TcpSocketState.listening => socket.listener?.canAccept ?? true,
      _ => true,
    };
  }

  Future<void> _waitTcpSocketReady(_WASIPreview2TcpSocket socket) {
    return switch (socket.state) {
      _TcpSocketState.binding =>
        socket.pendingBind?.waitReady() ?? Future<void>.value(),
      _TcpSocketState.connecting =>
        socket.pendingConnect?.waitReady() ?? Future<void>.value(),
      _TcpSocketState.listeningStarting =>
        socket.pendingListen?.waitReady() ?? Future<void>.value(),
      _TcpSocketState.listening =>
        socket.listener?.waitAccept() ?? Future<void>.value(),
      _ => Future<void>.value(),
    };
  }

  bool _udpSocketReady(_WASIPreview2UdpSocket socket) {
    final operation = socket.pendingBind;
    if (operation != null) {
      return operation.isReady;
    }
    final binding = socket.binding;
    return binding == null || binding.canReceive || binding.canSend;
  }

  Future<void> _waitUdpSocketReady(_WASIPreview2UdpSocket socket) {
    final operation = socket.pendingBind;
    if (operation != null) {
      return operation.waitReady();
    }
    final binding = socket.binding;
    if (binding == null) {
      return Future<void>.value();
    }
    return Future.any<void>(<Future<void>>[
      binding.waitReceive(),
      binding.waitSend(),
    ]);
  }

  bool get _supportsTcpSocketOptions {
    final backend = _backend;
    return backend is! WASIPreview2SocketOptionsBackend ||
        (backend as WASIPreview2SocketOptionsBackend).supportsTcpSocketOptions;
  }

  bool get _supportsUdpSocketOptions {
    final backend = _backend;
    return backend is! WASIPreview2SocketOptionsBackend ||
        (backend as WASIPreview2SocketOptionsBackend).supportsUdpSocketOptions;
  }

  WasmComponentValueData _tcpBoolOption(
    int handle,
    bool Function(_WASIPreview2TcpSocket socket) read,
  ) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsTcpSocketOptions) {
      return _errorResult('not-supported');
    }
    return _ok(_boolData(read(socket)));
  }

  WasmComponentValueData _tcpSetBoolOption(
    int handle,
    bool value,
    void Function(_WASIPreview2TcpSocket socket, bool value) write,
  ) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsTcpSocketOptions) {
      return _errorResult('not-supported');
    }
    write(socket, value);
    return _ok();
  }

  WasmComponentValueData _tcpU8Option(
    int handle,
    int Function(_WASIPreview2TcpSocket socket) read,
  ) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsTcpSocketOptions) {
      return _errorResult('not-supported');
    }
    return _ok(_integerData(read(socket)));
  }

  WasmComponentValueData _tcpSetU8Option(
    int handle,
    int value,
    void Function(_WASIPreview2TcpSocket socket, int value) write,
  ) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsTcpSocketOptions) {
      return _errorResult('not-supported');
    }
    if (value == 0) {
      return _errorResult('invalid-argument');
    }
    write(socket, value);
    return _ok();
  }

  WasmComponentValueData _tcpU32Option(
    int handle,
    int Function(_WASIPreview2TcpSocket socket) read,
  ) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsTcpSocketOptions) {
      return _errorResult('not-supported');
    }
    return _ok(_integerData(read(socket)));
  }

  WasmComponentValueData _tcpSetU32Option(
    int handle,
    int value,
    void Function(_WASIPreview2TcpSocket socket, int value) write,
  ) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsTcpSocketOptions) {
      return _errorResult('not-supported');
    }
    if (value == 0) {
      return _errorResult('invalid-argument');
    }
    write(socket, value);
    return _ok();
  }

  WasmComponentValueData _tcpU64Option(
    int handle,
    BigInt Function(_WASIPreview2TcpSocket socket) read,
  ) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsTcpSocketOptions) {
      return _errorResult('not-supported');
    }
    return _ok(_integerData(read(socket)));
  }

  WasmComponentValueData _tcpSetU64Option(
    int handle,
    BigInt value,
    void Function(_WASIPreview2TcpSocket socket, BigInt value) write,
  ) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsTcpSocketOptions) {
      return _errorResult('not-supported');
    }
    if (value <= BigInt.zero) {
      return _errorResult('invalid-argument');
    }
    write(socket, value);
    return _ok();
  }

  WasmComponentValueData _tcpSetPositiveU64(int handle, BigInt value) {
    return _tcpSetU64Option(
      handle,
      value,
      (socket, next) => socket.listenBacklog = next,
    );
  }

  WasmComponentValueData _udpU8Option(
    int handle,
    int Function(_WASIPreview2UdpSocket socket) read,
  ) {
    final socket = _udpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsUdpSocketOptions) {
      return _errorResult('not-supported');
    }
    return _ok(_integerData(read(socket)));
  }

  WasmComponentValueData _udpSetU8Option(
    int handle,
    int value,
    void Function(_WASIPreview2UdpSocket socket, int value) write,
  ) {
    final socket = _udpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsUdpSocketOptions) {
      return _errorResult('not-supported');
    }
    if (value == 0) {
      return _errorResult('invalid-argument');
    }
    write(socket, value);
    return _ok();
  }

  WasmComponentValueData _udpU64Option(
    int handle,
    BigInt Function(_WASIPreview2UdpSocket socket) read,
  ) {
    final socket = _udpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsUdpSocketOptions) {
      return _errorResult('not-supported');
    }
    return _ok(_integerData(read(socket)));
  }

  WasmComponentValueData _udpSetU64Option(
    int handle,
    BigInt value,
    void Function(_WASIPreview2UdpSocket socket, BigInt value) write,
  ) {
    final socket = _udpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (!_supportsUdpSocketOptions) {
      return _errorResult('not-supported');
    }
    if (value <= BigInt.zero) {
      return _errorResult('invalid-argument');
    }
    write(socket, value);
    return _ok();
  }

  void _dropTcpSocket(_WASIPreview2TcpSocket socket) {
    socket.pendingBind?.dispose();
    socket.pendingConnect?.dispose(disposeValue: _disposeTcpConnection);
    socket.pendingListen?.dispose(disposeValue: (listener) => listener.close());
    socket.listener?.close();
    final connection = socket.connection;
    if (connection != null) {
      _disposeTcpConnection(connection);
    }
    socket.state = _TcpSocketState.closed;
  }

  void _dropUdpSocket(_WASIPreview2UdpSocket socket) {
    socket.pendingBind?.dispose(disposeValue: (binding) => binding.close());
    socket.streamGeneration?.invalidate();
    socket.binding?.close();
  }

  void _disposeTcpConnection(WASIPreview2TcpConnection connection) {
    final dispose = connection.dispose;
    if (dispose != null) {
      dispose();
    } else {
      connection.close?.call('both');
      connection.inputStream.close();
      connection.outputStream.close();
    }
  }

  _WASIPreview2Network? _network(int handle) {
    try {
      return table.get<_WASIPreview2Network>(_networkType, handle);
    } on StateError {
      return null;
    }
  }

  _WASIPreview2ResolveAddressStream? _resolveAddressStream(int handle) {
    try {
      return table.get<_WASIPreview2ResolveAddressStream>(
        _resolveAddressStreamType,
        handle,
      );
    } on StateError {
      return null;
    }
  }

  _WASIPreview2ResolveAddressStream _requireResolveAddressStream(int handle) {
    return table.get<_WASIPreview2ResolveAddressStream>(
      _resolveAddressStreamType,
      handle,
    );
  }

  _WASIPreview2TcpSocket? _tcpSocket(int handle) {
    try {
      return table.get<_WASIPreview2TcpSocket>(_tcpSocketType, handle);
    } on StateError {
      return null;
    }
  }

  _WASIPreview2TcpSocket _requireTcpSocket(int handle) {
    return table.get<_WASIPreview2TcpSocket>(_tcpSocketType, handle);
  }

  _WASIPreview2UdpSocket? _udpSocket(int handle) {
    try {
      return table.get<_WASIPreview2UdpSocket>(_udpSocketType, handle);
    } on StateError {
      return null;
    }
  }

  _WASIPreview2UdpSocket _requireUdpSocket(int handle) {
    return table.get<_WASIPreview2UdpSocket>(_udpSocketType, handle);
  }

  _WASIPreview2IncomingDatagramStream? _incomingDatagramStream(int handle) {
    try {
      return table.get<_WASIPreview2IncomingDatagramStream>(
        _incomingDatagramStreamType,
        handle,
      );
    } on StateError {
      return null;
    }
  }

  _WASIPreview2IncomingDatagramStream _requireIncomingDatagramStream(
    int handle,
  ) {
    return table.get<_WASIPreview2IncomingDatagramStream>(
      _incomingDatagramStreamType,
      handle,
    );
  }

  _WASIPreview2OutgoingDatagramStream? _outgoingDatagramStream(int handle) {
    try {
      return table.get<_WASIPreview2OutgoingDatagramStream>(
        _outgoingDatagramStreamType,
        handle,
      );
    } on StateError {
      return null;
    }
  }

  _WASIPreview2OutgoingDatagramStream _requireOutgoingDatagramStream(
    int handle,
  ) {
    return table.get<_WASIPreview2OutgoingDatagramStream>(
      _outgoingDatagramStreamType,
      handle,
    );
  }
}

final class _ResolvedSocketsHostParts {
  const _ResolvedSocketsHostParts({
    required this.table,
    required this.pollHost,
    required this.streamsHost,
  });

  final WASIComponentResourceTable table;
  final WASIPreview2PollHost pollHost;
  final WASIPreview2StreamsHost streamsHost;
}

_ResolvedSocketsHostParts _resolveSocketsHostParts(
  WASIComponentResourceTable? table,
  WASIPreview2PollHost? pollHost,
  WASIPreview2StreamsHost? streamsHost,
) {
  final resolvedTable =
      table ??
      pollHost?.table ??
      streamsHost?.table ??
      WASIComponentResourceTable();
  if (pollHost != null && !identical(resolvedTable, pollHost.table)) {
    throw ArgumentError.value(
      pollHost,
      'pollHost',
      'must use the same component resource table as sockets',
    );
  }
  if (streamsHost != null && !identical(resolvedTable, streamsHost.table)) {
    throw ArgumentError.value(
      streamsHost,
      'streamsHost',
      'must use the same component resource table as sockets',
    );
  }
  final resolvedPollHost =
      pollHost ??
      streamsHost?.pollHost ??
      WASIPreview2PollHost(table: resolvedTable);
  if (streamsHost != null &&
      !identical(resolvedPollHost, streamsHost.pollHost)) {
    throw ArgumentError.value(
      streamsHost,
      'streamsHost',
      'must use the same Preview2 poll host as sockets',
    );
  }
  return _ResolvedSocketsHostParts(
    table: resolvedTable,
    pollHost: resolvedPollHost,
    streamsHost:
        streamsHost ??
        WASIPreview2StreamsHost(
          table: resolvedTable,
          pollHost: resolvedPollHost,
        ),
  );
}

final class _WASIPreview2Network {
  const _WASIPreview2Network(this.id);

  final int id;
}

final class _WASIPreview2ResolveAddressStream {
  _WASIPreview2ResolveAddressStream(
    FutureOr<Iterable<WASIPreview2IpAddress>> addresses,
  ) {
    if (addresses is Future<Iterable<WASIPreview2IpAddress>>) {
      addresses.then(_complete, onError: _fail);
    } else {
      _complete(addresses);
    }
  }

  _WASIPreview2ResolveAddressStream.failed(String errorCode) {
    _errorCode = errorCode;
    _ready.complete();
  }

  final Completer<void> _ready = Completer<void>();
  List<WASIPreview2IpAddress> _addresses = const [];
  String? _errorCode;
  int _offset = 0;

  bool get isReady => _ready.isCompleted;

  Future<void> waitReady() => isReady ? Future<void>.value() : _ready.future;

  WASIPreview2SocketResult<WASIPreview2IpAddress?> next() {
    if (!isReady) {
      return const WASIPreview2SocketResult<WASIPreview2IpAddress?>.error(
        'would-block',
      );
    }
    final errorCode = _errorCode;
    if (errorCode != null) {
      return WASIPreview2SocketResult<WASIPreview2IpAddress?>.error(errorCode);
    }
    if (_offset >= _addresses.length) {
      return const WASIPreview2SocketResult<WASIPreview2IpAddress?>.ok(null);
    }
    return WASIPreview2SocketResult<WASIPreview2IpAddress?>.ok(
      _addresses[_offset++],
    );
  }

  void _complete(Iterable<WASIPreview2IpAddress> addresses) {
    if (isReady) {
      return;
    }
    try {
      _addresses = <WASIPreview2IpAddress>[
        for (final address in addresses)
          if (!_isIpv4MappedIpv6(address)) address,
      ];
      if (_addresses.isEmpty) {
        _errorCode = 'name-unresolvable';
      }
    } on Object catch (error) {
      _errorCode = _addressResolverErrorCode(error);
    }
    _ready.complete();
  }

  void _fail(Object error, [StackTrace? _]) {
    if (isReady) {
      return;
    }
    _errorCode = _addressResolverErrorCode(error);
    _ready.complete();
  }
}

enum _TcpSocketState {
  unbound,
  binding,
  bound,
  connecting,
  listeningStarting,
  listening,
  connected,
  closed,
}

final class _WASIPreview2TcpSocket {
  _WASIPreview2TcpSocket(this.family);

  _WASIPreview2TcpSocket.connected(
    this.family,
    WASIPreview2TcpConnection connection,
  ) : state = _TcpSocketState.connected,
      connection = connection,
      localAddress = connection.localAddress._toWit(),
      remoteAddress = connection.remoteAddress._toWit();

  final WASIPreview2IpAddressFamily family;
  _TcpSocketState state = _TcpSocketState.unbound;
  WasmComponentValueData? localAddress;
  WasmComponentValueData? remoteAddress;
  WASIPreview2SocketOperation<WASIPreview2IpSocketAddress>? pendingBind;
  WASIPreview2SocketOperation<WASIPreview2TcpConnection>? pendingConnect;
  WASIPreview2SocketOperation<WASIPreview2TcpListener>? pendingListen;
  WASIPreview2TcpListener? listener;
  WASIPreview2TcpConnection? connection;
  int? networkId;
  int? pendingNetworkId;
  BigInt listenBacklog = BigInt.from(128);
  bool keepAlive = false;
  BigInt keepAliveIdle = BigInt.from(7200000000000);
  BigInt keepAliveInterval = BigInt.from(75000000000);
  int keepAliveCount = 9;
  int hopLimit = 64;
  BigInt receiveBuffer = BigInt.from(65536);
  BigInt sendBuffer = BigInt.from(65536);

  WASIPreview2IpSocketAddress? get localAddressAddress =>
      WASIPreview2IpSocketAddress._fromWit(localAddress);
}

final class _WASIPreview2UdpSocket {
  _WASIPreview2UdpSocket(this.family);

  final WASIPreview2IpAddressFamily family;
  bool bound = false;
  WasmComponentValueData? localAddress;
  WasmComponentValueData? remoteAddress;
  WASIPreview2SocketOperation<WASIPreview2UdpBinding>? pendingBind;
  WASIPreview2UdpBinding? binding;
  int? networkId;
  int? pendingNetworkId;
  _WASIPreview2UdpStreamGeneration? streamGeneration;
  int hopLimit = 64;
  BigInt receiveBuffer = BigInt.from(65536);
  BigInt sendBuffer = BigInt.from(65536);
}

final class _WASIPreview2IncomingDatagramStream {
  const _WASIPreview2IncomingDatagramStream(
    this.binding,
    this.remoteAddress,
    this.generation,
  );

  final WASIPreview2UdpBinding binding;
  final WASIPreview2IpSocketAddress? remoteAddress;
  final _WASIPreview2UdpStreamGeneration generation;
}

final class _WASIPreview2OutgoingDatagramStream {
  _WASIPreview2OutgoingDatagramStream(
    this.binding,
    this.remoteAddress,
    this.generation,
  );

  final WASIPreview2UdpBinding binding;
  final WASIPreview2IpSocketAddress? remoteAddress;
  final _WASIPreview2UdpStreamGeneration generation;
  BigInt? sendPermit;
}

final class _WASIPreview2UdpStreamGeneration {
  bool _active = true;
  int _references = 2;
  final Completer<void> _inactive = Completer<void>();

  bool get isActive => _active;

  Future<void> waitInactive() =>
      _active ? _inactive.future : Future<void>.value();

  void invalidate() {
    if (!_active) {
      return;
    }
    _active = false;
    _inactive.complete();
  }

  void release() {
    if (_references == 0) {
      return;
    }
    _references--;
    if (_references == 0) {
      invalidate();
    }
  }
}

Iterable<WASIPreview2IpAddress> _defaultAddressResolver(String name) {
  final literal = WASIPreview2IpAddress._parseLiteral(name);
  if (literal != null) {
    return <WASIPreview2IpAddress>[literal];
  }
  if (name == 'localhost') {
    return <WASIPreview2IpAddress>[
      WASIPreview2IpAddress.ipv6(0, 0, 0, 0, 0, 0, 0, 1),
      WASIPreview2IpAddress.ipv4(127, 0, 0, 1),
    ];
  }
  return const <WASIPreview2IpAddress>[];
}

WASIPreview2IpAddress? _parseIpv4Literal(String name) {
  final parts = name.split('.');
  if (parts.length != 4) {
    return null;
  }
  final parsed = <int>[];
  for (final part in parts) {
    if (part.isEmpty || !_decimalDigits.hasMatch(part)) {
      return null;
    }
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 0xff) {
      return null;
    }
    parsed.add(value);
  }
  return WASIPreview2IpAddress._(WASIPreview2IpAddressFamily.ipv4, parsed);
}

WASIPreview2IpAddress? _parseIpv6Literal(String name) {
  if (!name.contains(':') || name.contains('%') || name.contains(':::')) {
    return null;
  }
  final halves = name.split('::');
  if (halves.length > 2) {
    return null;
  }
  final hasCompression = halves.length == 2;
  if (hasCompression && halves[0].contains('.')) {
    return null;
  }
  final head = _parseIpv6Half(halves[0]);
  final tail = halves.length == 1 ? const <int>[] : _parseIpv6Half(halves[1]);
  if (head == null || tail == null) {
    return null;
  }
  final zeroFill = 8 - head.length - tail.length;
  if ((!hasCompression && zeroFill != 0) || (hasCompression && zeroFill < 1)) {
    return null;
  }
  final parts = <int>[...head, for (var i = 0; i < zeroFill; i++) 0, ...tail];
  if (parts.length != 8) {
    return null;
  }
  return WASIPreview2IpAddress._(WASIPreview2IpAddressFamily.ipv6, parts);
}

List<int>? _parseIpv6Half(String half) {
  if (half.isEmpty) {
    return const <int>[];
  }
  final segments = half.split(':');
  final parts = <int>[];
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    if (segment.isEmpty) {
      return null;
    }
    if (segment.contains('.')) {
      if (index != segments.length - 1) {
        return null;
      }
      final ipv4 = _parseIpv4Literal(segment);
      if (ipv4 == null) {
        return null;
      }
      final octets = ipv4.parts;
      parts
        ..add((octets[0] << 8) | octets[1])
        ..add((octets[2] << 8) | octets[3]);
      continue;
    }
    if (segment.length > 4 || !_hexDigits.hasMatch(segment)) {
      return null;
    }
    parts.add(int.parse(segment, radix: 16));
  }
  return parts;
}

// A dependency-free ToASCII path: normalize IDNA dot variants, case-fold,
// validate conservatively, then apply RFC 3492 per non-ASCII label. Without
// Unicode normalization tables, decomposed LTR labels are rejected instead of
// producing a non-canonical A-label.
String? _toAsciiDomainName(String name) {
  if (name.isEmpty || name.contains('\u0000')) {
    return null;
  }
  if (name.contains(':') || name.startsWith('[') || name.endsWith(']')) {
    return null;
  }
  final normalized = name
      .replaceAll('\u3002', '.')
      .replaceAll('\uff0e', '.')
      .replaceAll('\uff61', '.');
  if (_invalidIpv4Candidate.hasMatch(normalized)) {
    return null;
  }
  final trailingDot = normalized.endsWith('.');
  final domain = normalized.endsWith('.')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  if (domain.isEmpty) {
    return null;
  }
  final asciiLabels = <String>[];
  for (final label in domain.split('.')) {
    final asciiLabel = _toAsciiDomainLabel(label);
    if (asciiLabel == null) {
      return null;
    }
    asciiLabels.add(asciiLabel);
  }
  final asciiDomain = asciiLabels.join('.');
  if (asciiDomain.length > 253) {
    return null;
  }
  return trailingDot ? '$asciiDomain.' : asciiDomain;
}

String? _toAsciiDomainLabel(String label) {
  if (label.isEmpty) {
    return null;
  }
  final folded = label.toLowerCase();
  if (folded.startsWith('-') || folded.endsWith('-')) {
    return null;
  }
  final runes = folded.runes.toList(growable: false);
  if (_isCombiningMark(runes.first) ||
      !_hasSupportedCombiningMarks(runes) ||
      !_hasValidMinimalBidi(runes)) {
    return null;
  }
  var hasNonAscii = false;
  for (final rune in runes) {
    if (rune <= 0x7f) {
      if (!_asciiDomainRune(rune)) {
        return null;
      }
    } else {
      hasNonAscii = true;
      if (!_isConservativeIdnaRune(rune)) {
        return null;
      }
    }
  }
  if (hasNonAscii && folded.startsWith('xn--')) {
    return null;
  }
  final ascii = hasNonAscii ? 'xn--${_punycodeEncode(runes)}' : folded;
  if (ascii.isEmpty || ascii.length > 63) {
    return null;
  }
  if (ascii.length >= 4 &&
      ascii[2] == '-' &&
      ascii[3] == '-' &&
      !ascii.startsWith('xn--')) {
    return null;
  }
  return ascii;
}

bool _asciiDomainRune(int rune) {
  return (rune >= 0x30 && rune <= 0x39) ||
      (rune >= 0x41 && rune <= 0x5a) ||
      (rune >= 0x61 && rune <= 0x7a) ||
      rune == 0x2d;
}

bool _isConservativeIdnaRune(int rune) {
  if (rune < 0xa0 ||
      rune == 0xa0 ||
      rune == 0xfffd ||
      (rune >= 0xd800 && rune <= 0xdfff) ||
      (rune >= 0xfdd0 && rune <= 0xfdef) ||
      (rune & 0xffff) == 0xfffe ||
      (rune & 0xffff) == 0xffff) {
    return false;
  }
  if (rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x206f) ||
      (rune >= 0x2600 && rune <= 0x27bf) ||
      (rune >= 0x3000 && rune <= 0x303f) ||
      (rune >= 0xfb1d && rune <= 0xfdff) ||
      (rune >= 0xfe70 && rune <= 0xfeff) ||
      (rune >= 0xe000 && rune <= 0xf8ff) ||
      (rune >= 0xf0000 && rune <= 0xffffd) ||
      (rune >= 0x100000 && rune <= 0x10fffd) ||
      (rune >= 0xfe00 && rune <= 0xfe0f) ||
      (rune >= 0x1f000 && rune <= 0x1faff) ||
      (rune >= 0xe0100 && rune <= 0xe01ef) ||
      (rune >= 0xe0000 && rune <= 0xe007f) ||
      (rune >= 0xff00 && rune <= 0xffef) ||
      rune == 0x00ad ||
      rune == 0x034f ||
      rune == 0x00b7 ||
      rune == 0x0375 ||
      rune == 0x05f3 ||
      rune == 0x05f4 ||
      rune == 0x30fb) {
    return false;
  }
  return true;
}

bool _isCombiningMark(int rune) {
  return (rune >= 0x0300 && rune <= 0x036f) ||
      (rune >= 0x0483 && rune <= 0x0489) ||
      (rune >= 0x0591 && rune <= 0x05bd) ||
      rune == 0x05bf ||
      (rune >= 0x05c1 && rune <= 0x05c2) ||
      (rune >= 0x05c4 && rune <= 0x05c5) ||
      rune == 0x05c7 ||
      (rune >= 0x0610 && rune <= 0x061a) ||
      (rune >= 0x064b && rune <= 0x065f) ||
      rune == 0x0670 ||
      (rune >= 0x06d6 && rune <= 0x06ed) ||
      (rune >= 0x1ab0 && rune <= 0x1aff) ||
      (rune >= 0x1dc0 && rune <= 0x1dff) ||
      (rune >= 0x20d0 && rune <= 0x20ff) ||
      (rune >= 0xfe20 && rune <= 0xfe2f);
}

bool _hasSupportedCombiningMarks(List<int> runes) {
  final rtl = runes.any(_isRtlRune);
  var previousWasMark = false;
  for (final rune in runes) {
    final mark = _isCombiningMark(rune);
    if (mark &&
        (!rtl || previousWasMark || (rune >= 0x0653 && rune <= 0x0655))) {
      return false;
    }
    previousWasMark = mark;
  }
  return true;
}

bool _hasValidMinimalBidi(List<int> runes) {
  if (!runes.any(_isRtlRune)) {
    return true;
  }
  if (!_isRtlLetter(runes.first)) {
    return false;
  }
  var last = runes.last;
  for (
    var index = runes.length - 1;
    index >= 0 && _isCombiningMark(last);
    index--
  ) {
    if (index == 0) {
      return false;
    }
    last = runes[index - 1];
  }
  if (!_isRtlLetter(last) && !_isIdnaDigit(last)) {
    return false;
  }
  if (runes.any(_isLtrLetter)) {
    return false;
  }
  final hasArabicIndic = runes.any((rune) => rune >= 0x0660 && rune <= 0x0669);
  final hasExtendedArabicIndic = runes.any(
    (rune) => rune >= 0x06f0 && rune <= 0x06f9,
  );
  return !(hasArabicIndic && hasExtendedArabicIndic);
}

bool _isRtlRune(int rune) {
  return (rune >= 0x0590 && rune <= 0x08ff) ||
      (rune >= 0xfb1d && rune <= 0xfdff) ||
      (rune >= 0xfe70 && rune <= 0xfeff) ||
      (rune >= 0x1ee00 && rune <= 0x1eeff);
}

bool _isRtlLetter(int rune) {
  return _isRtlRune(rune) &&
      !_isCombiningMark(rune) &&
      !_isIdnaDigit(rune) &&
      rune != 0x060c &&
      rune != 0x061b &&
      rune != 0x061f;
}

bool _isLtrLetter(int rune) {
  return (rune >= 0x41 && rune <= 0x5a) ||
      (rune >= 0x61 && rune <= 0x7a) ||
      (rune >= 0x00c0 && rune <= 0x02af) ||
      (rune >= 0x0370 && rune <= 0x058f);
}

bool _isIdnaDigit(int rune) {
  return (rune >= 0x30 && rune <= 0x39) ||
      (rune >= 0x0660 && rune <= 0x0669) ||
      (rune >= 0x06f0 && rune <= 0x06f9);
}

String _punycodeEncode(List<int> input) {
  const base = 36;
  const tMin = 1;
  const tMax = 26;
  const initialBias = 72;
  const initialCodePoint = 0x80;

  final output = StringBuffer();
  for (final codePoint in input) {
    if (codePoint < initialCodePoint) {
      output.writeCharCode(codePoint);
    }
  }
  final basicCount = output.length;
  var handled = basicCount;
  if (basicCount != 0) {
    output.write('-');
  }

  var codePoint = initialCodePoint;
  var delta = 0;
  var bias = initialBias;
  while (handled < input.length) {
    var next = 0x110000;
    for (final candidate in input) {
      if (candidate >= codePoint && candidate < next) {
        next = candidate;
      }
    }
    delta += (next - codePoint) * (handled + 1);
    codePoint = next;
    for (final candidate in input) {
      if (candidate < codePoint) {
        delta++;
      }
      if (candidate != codePoint) {
        continue;
      }
      var quotient = delta;
      for (var k = base; ; k += base) {
        final threshold = k <= bias
            ? tMin
            : k >= bias + tMax
            ? tMax
            : k - bias;
        if (quotient < threshold) {
          break;
        }
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

String _punycodeDigit(int digit) {
  return String.fromCharCode(digit < 26 ? 0x61 + digit : 0x30 + digit - 26);
}

bool _isIpv4MappedIpv6(WASIPreview2IpAddress address) {
  if (address.family != WASIPreview2IpAddressFamily.ipv6) {
    return false;
  }
  final parts = address.parts;
  return parts[0] == 0 &&
      parts[1] == 0 &&
      parts[2] == 0 &&
      parts[3] == 0 &&
      parts[4] == 0 &&
      parts[5] == 0xffff;
}

String _addressResolverErrorCode(Object error) {
  if (error is WASIPreview2AddressResolverError &&
      _resolverErrorCodes.contains(error.errorCode)) {
    return error.errorCode;
  }
  return 'name-unresolvable';
}

const Set<String> _resolverErrorCodes = <String>{
  'name-unresolvable',
  'temporary-resolver-failure',
  'permanent-resolver-failure',
};

final RegExp _decimalDigits = RegExp(r'^[0-9]+$');
final RegExp _hexDigits = RegExp(r'^[0-9a-fA-F]+$');
final RegExp _invalidIpv4Candidate = RegExp(
  r'^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$',
);

WASIPreview2IpAddressFamily? _addressFamilyFromData(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.enumeration) {
    return null;
  }
  final label = value.label;
  final index = value.index;
  if (label == 'ipv4' || (label == null && index == 0)) {
    return WASIPreview2IpAddressFamily.ipv4;
  }
  if (label == 'ipv6' || (label == null && index == 1)) {
    return WASIPreview2IpAddressFamily.ipv6;
  }
  return null;
}

WASIPreview2IpSocketAddress? _ipSocketAddressFromData(Object? value) {
  return WASIPreview2IpSocketAddress._fromWit(value);
}

({bool valid, WASIPreview2IpSocketAddress? address})
_optionalIpSocketAddressFromData(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.option) {
    return (valid: false, address: null);
  }
  final isSome = value.isSome ?? value.label == 'some' || value.index == 1;
  if (!isSome) {
    return (valid: true, address: null);
  }
  final address = WASIPreview2IpSocketAddress._fromWit(value.associatedValue);
  return address == null
      ? (valid: false, address: null)
      : (valid: true, address: address);
}

int _validatePart(int value, int max, String name) {
  if (value < 0 || value > max) {
    throw RangeError.range(value, 0, max, name);
  }
  return value;
}

int _handle(Object? value) {
  return switch (value) {
    int() when value >= 0 => value,
    BigInt() when value >= BigInt.zero => value.toInt(),
    _ => throw StateError('Expected WASI sockets resource handle, got $value.'),
  };
}

int _u8(Object? value) {
  return switch (value) {
    int() when value >= 0 && value <= 0xff => value,
    BigInt() when value >= BigInt.zero && value <= BigInt.from(0xff) =>
      value.toInt(),
    _ => throw StateError('Expected u8 value, got $value.'),
  };
}

int _u32(Object? value) {
  return switch (value) {
    int() when value >= 0 => value,
    BigInt() when value >= BigInt.zero && value <= BigInt.from(0xffffffff) =>
      value.toInt(),
    _ => throw StateError('Expected u32 value, got $value.'),
  };
}

BigInt _u64(Object? value) {
  return switch (value) {
    BigInt() when value >= BigInt.zero => value,
    int() when value >= 0 => BigInt.from(value),
    _ => throw StateError('Expected u64 value, got $value.'),
  };
}

int? _u16Data(WasmComponentValueData value) {
  final integer = value.kind == WasmComponentValueDataKind.integer
      ? value.integer
      : null;
  return switch (integer) {
    int() when integer >= 0 && integer <= 0xffff => integer,
    BigInt() when integer >= BigInt.zero && integer <= BigInt.from(0xffff) =>
      integer.toInt(),
    _ => null,
  };
}

int? _u32Data(WasmComponentValueData value) {
  final integer = value.kind == WasmComponentValueDataKind.integer
      ? value.integer
      : null;
  return switch (integer) {
    int() when integer >= 0 && integer <= 0xffffffff => integer,
    BigInt()
        when integer >= BigInt.zero && integer <= BigInt.from(0xffffffff) =>
      integer.toInt(),
    _ => null,
  };
}

List<int>? _u8Tuple(WasmComponentValueData value, int length) {
  if (value.kind != WasmComponentValueDataKind.tuple ||
      value.items.length != length) {
    return null;
  }
  final parts = <int>[];
  for (final item in value.items) {
    final integer = item.kind == WasmComponentValueDataKind.integer
        ? item.integer
        : null;
    final part = switch (integer) {
      int() when integer >= 0 && integer <= 0xff => integer,
      BigInt() when integer >= BigInt.zero && integer <= BigInt.from(0xff) =>
        integer.toInt(),
      _ => null,
    };
    if (part == null) {
      return null;
    }
    parts.add(part);
  }
  return parts;
}

List<int>? _u16Tuple(WasmComponentValueData value, int length) {
  if (value.kind != WasmComponentValueDataKind.tuple ||
      value.items.length != length) {
    return null;
  }
  final parts = <int>[];
  for (final item in value.items) {
    final part = _u16Data(item);
    if (part == null) {
      return null;
    }
    parts.add(part);
  }
  return parts;
}

List<WASIPreview2OutgoingDatagram>? _outgoingDatagramsFromData(
  Object? value,
  WASIPreview2IpSocketAddress? streamRemoteAddress,
  WASIPreview2IpAddressFamily family,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.list) {
    return null;
  }
  final datagrams = <WASIPreview2OutgoingDatagram>[];
  for (final item in value.items) {
    if (item.kind != WasmComponentValueDataKind.record ||
        item.items.length != 2) {
      return null;
    }
    final data = _u8ListFromData(item.items[0]);
    final remoteResult = _optionalIpSocketAddressFromData(item.items[1]);
    if (data == null || !remoteResult.valid) {
      return null;
    }
    final providedRemoteAddress = remoteResult.address;
    final WASIPreview2IpSocketAddress remoteAddress;
    if (streamRemoteAddress == null) {
      if (providedRemoteAddress == null) {
        return null;
      }
      remoteAddress = providedRemoteAddress;
    } else {
      if (providedRemoteAddress != null &&
          !_sameAddress(providedRemoteAddress, streamRemoteAddress)) {
        return null;
      }
      remoteAddress = streamRemoteAddress;
    }
    if (remoteAddress.family != family ||
        !_isValidUdpRemoteAddress(remoteAddress)) {
      return null;
    }
    datagrams.add(
      WASIPreview2OutgoingDatagram(
        data: Uint8List.fromList(data),
        remoteAddress: remoteAddress,
      ),
    );
  }
  return datagrams;
}

List<int>? _u8ListFromData(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    return null;
  }
  final bytes = <int>[];
  for (final item in value.items) {
    final integer = item.kind == WasmComponentValueDataKind.integer
        ? item.integer
        : null;
    final byte = switch (integer) {
      int() when integer >= 0 && integer <= 0xff => integer,
      BigInt() when integer >= BigInt.zero && integer <= BigInt.from(0xff) =>
        integer.toInt(),
      _ => null,
    };
    if (byte == null) {
      return null;
    }
    bytes.add(byte);
  }
  return bytes;
}

bool _sameAddress(
  WASIPreview2IpSocketAddress a,
  WASIPreview2IpSocketAddress b,
) {
  if (a.family != b.family ||
      a.port != b.port ||
      a.flowInfo != b.flowInfo ||
      a.scopeId != b.scopeId) {
    return false;
  }
  final left = a.address.parts;
  final right = b.address.parts;
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

bool _isValidUdpRemoteAddress(WASIPreview2IpSocketAddress address) {
  return address.port != 0 && !_isAnyAddress(address.address);
}

bool _isValidTcpRemoteAddress(WASIPreview2IpSocketAddress address) {
  if (!_isValidUdpRemoteAddress(address)) {
    return false;
  }
  final parts = address.address.parts;
  if (address.family == WASIPreview2IpAddressFamily.ipv4) {
    final multicast = parts[0] >= 224 && parts[0] <= 239;
    final limitedBroadcast = parts.every((part) => part == 0xff);
    return !multicast && !limitedBroadcast;
  }
  final multicast = parts[0] & 0xff00 == 0xff00;
  final ipv4Mapped =
      parts.take(5).every((part) => part == 0) && parts[5] == 0xffff;
  return !multicast && !ipv4Mapped;
}

bool _isAnyAddress(WASIPreview2IpAddress address) {
  return address.parts.every((part) => part == 0);
}

String _caseLabelFromData(Object? value) {
  if (value is WasmComponentValueData &&
      (value.kind == WasmComponentValueDataKind.enumeration ||
          value.kind == WasmComponentValueDataKind.variant)) {
    return value.label ?? 'case-${value.index}';
  }
  return 'unknown';
}

WasmComponentValueData _addressFamilyData(WASIPreview2IpAddressFamily? family) {
  return _enumData(
    family == WASIPreview2IpAddressFamily.ipv6 ? 'ipv6' : 'ipv4',
  );
}

WasmComponentValueData _ok([WasmComponentValueData? associatedValue]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _errorResult(String code) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
    associatedValue: _enumData(code),
  );
}

WasmComponentValueData _enumData(String label) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.enumeration,
    rawBytes: Uint8List(0),
    index: _caseIndex(label),
    label: label,
  );
}

WasmComponentValueData _variantData(
  String label, [
  WasmComponentValueData? associatedValue,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: _caseIndex(label),
    label: label,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _some(WasmComponentValueData value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: true,
    associatedValue: value,
  );
}

WasmComponentValueData _none() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
    isSome: false,
  );
}

WasmComponentValueData _tupleData(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _recordData(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _listData(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _u8ListData(List<int> bytes) {
  return _listData([for (final byte in bytes) _integerData(byte)]);
}

WasmComponentValueData _integerData(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}

WasmComponentValueData _boolData(bool value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.boolean,
    rawBytes: Uint8List(0),
    boolean: value,
  );
}

int _caseIndex(String label) {
  return _networkErrorCodeIndexes[label] ??
      _addressFamilyIndexes[label] ??
      _ipAddressVariantIndexes[label] ??
      0;
}

const Map<String, int> _addressFamilyIndexes = <String, int>{
  'ipv4': 0,
  'ipv6': 1,
};

const Map<String, int> _ipAddressVariantIndexes = <String, int>{
  'ipv4': 0,
  'ipv6': 1,
};

const Map<String, int> _networkErrorCodeIndexes = <String, int>{
  'unknown': 0,
  'access-denied': 1,
  'not-supported': 2,
  'invalid-argument': 3,
  'out-of-memory': 4,
  'timeout': 5,
  'concurrency-conflict': 6,
  'not-in-progress': 7,
  'would-block': 8,
  'invalid-state': 9,
  'new-socket-limit': 10,
  'address-not-bindable': 11,
  'address-in-use': 12,
  'remote-unreachable': 13,
  'connection-refused': 14,
  'connection-reset': 15,
  'connection-aborted': 16,
  'datagram-too-large': 17,
  'name-unresolvable': 18,
  'temporary-resolver-failure': 19,
  'permanent-resolver-failure': 20,
};
