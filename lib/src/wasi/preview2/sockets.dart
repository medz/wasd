import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/resource_table.dart';
import '../component/wit_adapter.dart';
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

/// Resolves a WASI socket name to zero or more IP addresses.
typedef WASIPreview2AddressResolver =
    Iterable<WASIPreview2IpAddress> Function(String name);

/// WASI 0.2 `wasi:sockets` host imports.
final class WASIPreview2SocketsHost {
  /// Creates a sockets host backed by [table] or [pollHost].
  factory WASIPreview2SocketsHost({
    WASIComponentResourceTable? table,
    WASIPreview2PollHost? pollHost,
    WASIPreview2AddressResolver? resolveAddresses,
  }) {
    final resolvedTable =
        table ?? pollHost?.table ?? WASIComponentResourceTable();
    if (pollHost != null && !identical(resolvedTable, pollHost.table)) {
      throw ArgumentError.value(
        pollHost,
        'pollHost',
        'must use the same component resource table as sockets',
      );
    }
    return WASIPreview2SocketsHost._(
      table: resolvedTable,
      pollHost: pollHost ?? WASIPreview2PollHost(table: resolvedTable),
      resolveAddresses: resolveAddresses ?? _defaultAddressResolver,
    );
  }

  WASIPreview2SocketsHost._({
    required this.table,
    required this.pollHost,
    required WASIPreview2AddressResolver resolveAddresses,
  }) : _resolveAddresses = resolveAddresses;

  /// Component resource table that owns sockets resources.
  final WASIComponentResourceTable table;

  /// Poll host used by sockets `subscribe` operations.
  final WASIPreview2PollHost pollHost;

  final WASIPreview2AddressResolver _resolveAddresses;

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
      );

  late final WASIComponentResourceType<_WASIPreview2UdpSocket> _udpSocketType =
      table.defineType<_WASIPreview2UdpSocket>(
        'wasi:sockets/udp@0.2.0.udp-socket',
      );

  late final WASIComponentResourceType<_WASIPreview2IncomingDatagramStream>
  _incomingDatagramStreamType = table
      .defineType<_WASIPreview2IncomingDatagramStream>(
        'wasi:sockets/udp@0.2.0.incoming-datagram-stream',
      );

  late final WASIComponentResourceType<_WASIPreview2OutgoingDatagramStream>
  _outgoingDatagramStreamType = table
      .defineType<_WASIPreview2OutgoingDatagramStream>(
        'wasi:sockets/udp@0.2.0.outgoing-datagram-stream',
      );

  int _nextNetworkId = 1;

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
        _tcpShutdown(_handle(args[0])),
    'wasi:sockets/udp-create-socket@0.2.0.create-udp-socket': (args) =>
        _createUdpSocket(args[0]),
    'wasi:sockets/udp@0.2.0.udp-socket.start-bind': (args) =>
        _udpStartBind(_handle(args[0]), _handle(args[1]), args[2]),
    'wasi:sockets/udp@0.2.0.udp-socket.finish-bind': (args) =>
        _udpFinishBind(_handle(args[0])),
    'wasi:sockets/udp@0.2.0.udp-socket.stream': (args) =>
        _udpStream(_handle(args[0])),
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
        _receiveDatagrams(_handle(args[0])),
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
      _WASIPreview2Network(_nextNetworkId++),
    );
  }

  WasmComponentValueData _resolve(int networkHandle, String name) {
    if (_network(networkHandle) == null) {
      return _errorResult('invalid-argument');
    }
    final addresses = _resolveAddresses(name).toList(growable: false);
    if (addresses.isEmpty) {
      return _errorResult('name-unresolvable');
    }
    final handle = table.insert<_WASIPreview2ResolveAddressStream>(
      _resolveAddressStreamType,
      _WASIPreview2ResolveAddressStream(addresses),
    );
    return _ok(_integerData(handle));
  }

  WasmComponentValueData _resolveNextAddress(int handle) {
    final stream = _resolveAddressStream(handle);
    if (stream == null) {
      return _errorResult('invalid-argument');
    }
    final address = stream.next();
    return _ok(address == null ? _none() : _some(address._toWit()));
  }

  int _subscribeResolveStream(int handle) {
    _requireResolveAddressStream(handle);
    return pollHost.insert(
      WASIPreview2Pollable(isReady: () => true, waitReady: () async {}),
    );
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
    if (socket == null || _network(networkHandle) == null) {
      return _errorResult('invalid-argument');
    }
    final address = _ipSocketAddressFromData(addressValue);
    if (address == null || address.family != socket.family) {
      return _errorResult('invalid-argument');
    }
    if (socket.state != _TcpSocketState.unbound) {
      return _errorResult('invalid-state');
    }
    return _errorResult('not-supported');
  }

  WasmComponentValueData _tcpFinishBind(int handle) {
    return _tcpSocket(handle) == null
        ? _errorResult('invalid-argument')
        : _errorResult('not-in-progress');
  }

  WasmComponentValueData _tcpStartConnect(
    int handle,
    int networkHandle,
    Object? addressValue,
  ) {
    final socket = _tcpSocket(handle);
    if (socket == null || _network(networkHandle) == null) {
      return _errorResult('invalid-argument');
    }
    final address = _ipSocketAddressFromData(addressValue);
    if (address == null || address.family != socket.family) {
      return _errorResult('invalid-argument');
    }
    if (socket.state != _TcpSocketState.unbound &&
        socket.state != _TcpSocketState.bound) {
      return _errorResult('invalid-state');
    }
    return _errorResult('not-supported');
  }

  WasmComponentValueData _tcpFinishConnect(int handle) {
    return _tcpSocket(handle) == null
        ? _errorResult('invalid-argument')
        : _errorResult('not-in-progress');
  }

  WasmComponentValueData _tcpStartListen(int handle) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    if (socket.state != _TcpSocketState.bound) {
      return _errorResult('invalid-state');
    }
    return _errorResult('not-supported');
  }

  WasmComponentValueData _tcpFinishListen(int handle) {
    return _tcpSocket(handle) == null
        ? _errorResult('invalid-argument')
        : _errorResult('not-in-progress');
  }

  WasmComponentValueData _tcpAccept(int handle) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    return socket.state == _TcpSocketState.listening
        ? _errorResult('would-block')
        : _errorResult('invalid-state');
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

  WasmComponentValueData _tcpShutdown(int handle) {
    final socket = _tcpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    return socket.state == _TcpSocketState.connected
        ? _ok()
        : _errorResult('invalid-state');
  }

  WasmComponentValueData _udpStartBind(
    int handle,
    int networkHandle,
    Object? addressValue,
  ) {
    final socket = _udpSocket(handle);
    if (socket == null || _network(networkHandle) == null) {
      return _errorResult('invalid-argument');
    }
    final address = _ipSocketAddressFromData(addressValue);
    if (address == null || address.family != socket.family) {
      return _errorResult('invalid-argument');
    }
    if (socket.bound) {
      return _errorResult('invalid-state');
    }
    return _errorResult('not-supported');
  }

  WasmComponentValueData _udpFinishBind(int handle) {
    return _udpSocket(handle) == null
        ? _errorResult('invalid-argument')
        : _errorResult('not-in-progress');
  }

  WasmComponentValueData _udpStream(int handle) {
    final socket = _udpSocket(handle);
    if (socket == null) {
      return _errorResult('invalid-argument');
    }
    return socket.bound
        ? _errorResult('not-supported')
        : _errorResult('invalid-state');
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

  WasmComponentValueData _receiveDatagrams(int handle) {
    return _incomingDatagramStream(handle) == null
        ? _errorResult('invalid-argument')
        : _ok(_listData(const <WasmComponentValueData>[]));
  }

  WasmComponentValueData _checkDatagramSend(int handle) {
    return _outgoingDatagramStream(handle) == null
        ? _errorResult('invalid-argument')
        : _ok(_integerData(BigInt.zero));
  }

  WasmComponentValueData _sendDatagrams(int handle, Object? value) {
    if (_outgoingDatagramStream(handle) == null) {
      return _errorResult('invalid-argument');
    }
    if (value is WasmComponentValueData &&
        value.kind == WasmComponentValueDataKind.list &&
        value.items.isEmpty) {
      return _ok(_integerData(BigInt.zero));
    }
    return _errorResult('not-supported');
  }

  bool _tcpIsListening(int handle) {
    return _requireTcpSocket(handle).state == _TcpSocketState.listening;
  }

  WasmComponentValueData _tcpAddressFamily(int handle) {
    return _addressFamilyData(_requireTcpSocket(handle).family);
  }

  int _tcpSubscribe(int handle) {
    _requireTcpSocket(handle);
    return _readyPollable();
  }

  WasmComponentValueData _udpAddressFamily(int handle) {
    return _addressFamilyData(_requireUdpSocket(handle).family);
  }

  int _udpSubscribe(int handle) {
    _requireUdpSocket(handle);
    return _readyPollable();
  }

  int _incomingDatagramSubscribe(int handle) {
    _requireIncomingDatagramStream(handle);
    return _readyPollable();
  }

  int _outgoingDatagramSubscribe(int handle) {
    _requireOutgoingDatagramStream(handle);
    return _readyPollable();
  }

  int _readyPollable() {
    return pollHost.insert(
      WASIPreview2Pollable(isReady: () => true, waitReady: () async {}),
    );
  }

  WasmComponentValueData _tcpBoolOption(
    int handle,
    bool Function(_WASIPreview2TcpSocket socket) read,
  ) {
    final socket = _tcpSocket(handle);
    return socket == null
        ? _errorResult('invalid-argument')
        : _ok(_boolData(read(socket)));
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
    write(socket, value);
    return _ok();
  }

  WasmComponentValueData _tcpU8Option(
    int handle,
    int Function(_WASIPreview2TcpSocket socket) read,
  ) {
    final socket = _tcpSocket(handle);
    return socket == null
        ? _errorResult('invalid-argument')
        : _ok(_integerData(read(socket)));
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
    return socket == null
        ? _errorResult('invalid-argument')
        : _ok(_integerData(read(socket)));
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
    return socket == null
        ? _errorResult('invalid-argument')
        : _ok(_integerData(read(socket)));
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
    return socket == null
        ? _errorResult('invalid-argument')
        : _ok(_integerData(read(socket)));
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
    return socket == null
        ? _errorResult('invalid-argument')
        : _ok(_integerData(read(socket)));
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
    if (value <= BigInt.zero) {
      return _errorResult('invalid-argument');
    }
    write(socket, value);
    return _ok();
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

final class _WASIPreview2Network {
  const _WASIPreview2Network(this.id);

  final int id;
}

final class _WASIPreview2ResolveAddressStream {
  _WASIPreview2ResolveAddressStream(Iterable<WASIPreview2IpAddress> addresses)
    : _addresses = List<WASIPreview2IpAddress>.of(addresses);

  final List<WASIPreview2IpAddress> _addresses;
  int _offset = 0;

  WASIPreview2IpAddress? next() {
    if (_offset >= _addresses.length) {
      return null;
    }
    return _addresses[_offset++];
  }
}

enum _TcpSocketState { unbound, bound, listening, connected }

final class _WASIPreview2TcpSocket {
  _WASIPreview2TcpSocket(this.family);

  final WASIPreview2IpAddressFamily family;
  _TcpSocketState state = _TcpSocketState.unbound;
  WasmComponentValueData? localAddress;
  WasmComponentValueData? remoteAddress;
  BigInt listenBacklog = BigInt.from(128);
  bool keepAlive = false;
  BigInt keepAliveIdle = BigInt.from(7200000000000);
  BigInt keepAliveInterval = BigInt.from(75000000000);
  int keepAliveCount = 9;
  int hopLimit = 64;
  BigInt receiveBuffer = BigInt.from(65536);
  BigInt sendBuffer = BigInt.from(65536);
}

final class _WASIPreview2UdpSocket {
  _WASIPreview2UdpSocket(this.family);

  final WASIPreview2IpAddressFamily family;
  bool bound = false;
  WasmComponentValueData? localAddress;
  WasmComponentValueData? remoteAddress;
  int hopLimit = 64;
  BigInt receiveBuffer = BigInt.from(65536);
  BigInt sendBuffer = BigInt.from(65536);
}

final class _WASIPreview2IncomingDatagramStream {
  const _WASIPreview2IncomingDatagramStream();
}

final class _WASIPreview2OutgoingDatagramStream {
  const _WASIPreview2OutgoingDatagramStream();
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
    if (part.isEmpty) {
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
  if (name == '::') {
    return WASIPreview2IpAddress._(
      WASIPreview2IpAddressFamily.ipv6,
      List<int>.filled(8, 0),
    );
  }
  if (name == '::1') {
    return WASIPreview2IpAddress.ipv6(0, 0, 0, 0, 0, 0, 0, 1);
  }
  if (!name.contains(':') || name.contains(':::')) {
    return null;
  }
  final halves = name.split('::');
  if (halves.length > 2) {
    return null;
  }
  final head = halves[0].isEmpty ? <String>[] : halves[0].split(':');
  final tail = halves.length == 1 || halves[1].isEmpty
      ? <String>[]
      : halves[1].split(':');
  if (halves.length == 1 && head.length != 8) {
    return null;
  }
  final zeroFill = 8 - head.length - tail.length;
  if (zeroFill < 0 || (halves.length == 1 && zeroFill != 0)) {
    return null;
  }
  final parts = <int>[];
  for (final segment in <String>[
    ...head,
    for (var i = 0; i < zeroFill; i++) '0',
    ...tail,
  ]) {
    if (segment.isEmpty || segment.length > 4) {
      return null;
    }
    final value = int.tryParse(segment, radix: 16);
    if (value == null || value < 0 || value > 0xffff) {
      return null;
    }
    parts.add(value);
  }
  if (parts.length != 8) {
    return null;
  }
  return WASIPreview2IpAddress._(WASIPreview2IpAddressFamily.ipv6, parts);
}

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

WasmComponentValueData? _ipSocketAddressFromData(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.variant) {
    return null;
  }
  final label = value.label;
  if (label == 'ipv4' || (label == null && value.index == 0)) {
    return value;
  }
  if (label == 'ipv6' || (label == null && value.index == 1)) {
    return value;
  }
  return null;
}

WASIPreview2IpAddressFamily? _ipSocketAddressFamily(
  WasmComponentValueData address,
) {
  if (address.label == 'ipv4' ||
      (address.label == null && address.index == 0)) {
    return WASIPreview2IpAddressFamily.ipv4;
  }
  if (address.label == 'ipv6' ||
      (address.label == null && address.index == 1)) {
    return WASIPreview2IpAddressFamily.ipv6;
  }
  return null;
}

extension on WasmComponentValueData? {
  WASIPreview2IpAddressFamily? get family {
    final value = this;
    return value == null ? null : _ipSocketAddressFamily(value);
  }
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

WasmComponentValueData _listData(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: items,
  );
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
