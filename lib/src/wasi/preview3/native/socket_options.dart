import 'dart:io' as io;

import '../sockets.dart';

/// Platform socket-option numbers consumed by `dart:io` raw option APIs.
final class NativeSocketOptionAbi {
  const NativeSocketOptionAbi._({
    required this.socketKeepAlive,
    required this.socketReceiveBuffer,
    required this.socketSendBuffer,
    required this.ipv4Ttl,
    required this.ipv6UnicastHops,
    required this.tcpKeepIdle,
    required this.tcpKeepInterval,
    required this.tcpKeepCount,
  });

  /// Resolves constants for an injectable Dart operating-system label.
  static NativeSocketOptionAbi? forOperatingSystem(String operatingSystem) {
    return switch (operatingSystem) {
      'linux' || 'android' => linux,
      'macos' || 'ios' => darwin,
      'windows' => windows,
      _ => null,
    };
  }

  /// Constants for Linux-compatible socket ABIs, including Android.
  static const linux = NativeSocketOptionAbi._(
    socketKeepAlive: 9,
    socketReceiveBuffer: 8,
    socketSendBuffer: 7,
    ipv4Ttl: 2,
    ipv6UnicastHops: 4,
    tcpKeepIdle: 4,
    tcpKeepInterval: 5,
    tcpKeepCount: 6,
  );

  /// Constants for Darwin-compatible socket ABIs, including iOS.
  static const darwin = NativeSocketOptionAbi._(
    socketKeepAlive: 0x0008,
    socketReceiveBuffer: 0x1002,
    socketSendBuffer: 0x1001,
    ipv4Ttl: 4,
    ipv6UnicastHops: 4,
    tcpKeepIdle: 0x10,
    tcpKeepInterval: 0x101,
    tcpKeepCount: 0x102,
  );

  /// Constants used by the supported Windows raw socket options.
  static const windows = NativeSocketOptionAbi._(
    socketKeepAlive: 0x0008,
    socketReceiveBuffer: 0x1002,
    socketSendBuffer: 0x1001,
    ipv4Ttl: 4,
    ipv6UnicastHops: 4,
    tcpKeepIdle: 3,
    tcpKeepInterval: 17,
    tcpKeepCount: 16,
  );

  /// `SO_KEEPALIVE`.
  final int socketKeepAlive;

  /// `SO_RCVBUF`.
  final int socketReceiveBuffer;

  /// `SO_SNDBUF`.
  final int socketSendBuffer;

  /// `IP_TTL`.
  final int ipv4Ttl;

  /// `IPV6_UNICAST_HOPS`.
  final int ipv6UnicastHops;

  /// `TCP_KEEPIDLE` or Darwin `TCP_KEEPALIVE`, when supported.
  final int? tcpKeepIdle;

  /// `TCP_KEEPINTVL`, when supported.
  final int? tcpKeepInterval;

  /// `TCP_KEEPCNT`, when supported.
  final int? tcpKeepCount;
}

/// Applies [options] to a connected native TCP [socket].
void applyNativeTcpSocketOptions(
  io.Socket socket,
  WASIPreview3IpAddressFamily family,
  WASIPreview3TcpSocketOptions options,
  NativeSocketOptionAbi abi,
) {
  void set(int level, int option, int value) {
    socket.setRawOption(io.RawSocketOption.fromInt(level, option, value));
  }

  set(
    io.RawSocketOption.levelSocket,
    abi.socketKeepAlive,
    options.keepAliveEnabled ? 1 : 0,
  );
  final keepIdle = abi.tcpKeepIdle;
  final keepInterval = abi.tcpKeepInterval;
  final keepCount = abi.tcpKeepCount;
  if (keepIdle != null && keepInterval != null && keepCount != null) {
    set(
      io.RawSocketOption.levelTcp,
      keepIdle,
      _durationSeconds(options.keepAliveIdle),
    );
    set(
      io.RawSocketOption.levelTcp,
      keepInterval,
      _durationSeconds(options.keepAliveInterval),
    );
    set(io.RawSocketOption.levelTcp, keepCount, options.keepAliveCount);
  }
  _applyIpHopLimit(set, family, options.hopLimit, abi);
  set(
    io.RawSocketOption.levelSocket,
    abi.socketReceiveBuffer,
    _boundedSocketOption(options.receiveBufferSize),
  );
  set(
    io.RawSocketOption.levelSocket,
    abi.socketSendBuffer,
    _boundedSocketOption(options.sendBufferSize),
  );
}

/// Applies [options] to a bound native UDP [socket].
void applyNativeUdpSocketOptions(
  io.RawDatagramSocket socket,
  WASIPreview3IpAddressFamily family,
  WASIPreview3UdpSocketOptions options,
  NativeSocketOptionAbi abi,
) {
  void set(int level, int option, int value) {
    socket.setRawOption(io.RawSocketOption.fromInt(level, option, value));
  }

  _applyIpHopLimit(set, family, options.hopLimit, abi);
  set(
    io.RawSocketOption.levelSocket,
    abi.socketReceiveBuffer,
    _boundedSocketOption(options.receiveBufferSize),
  );
  set(
    io.RawSocketOption.levelSocket,
    abi.socketSendBuffer,
    _boundedSocketOption(options.sendBufferSize),
  );
}

void _applyIpHopLimit(
  void Function(int level, int option, int value) set,
  WASIPreview3IpAddressFamily family,
  int value,
  NativeSocketOptionAbi abi,
) {
  if (family == WASIPreview3IpAddressFamily.ipv4) {
    set(io.RawSocketOption.levelIPv4, abi.ipv4Ttl, value);
  } else {
    set(io.RawSocketOption.levelIPv6, abi.ipv6UnicastHops, value);
  }
}

int _durationSeconds(BigInt nanoseconds) {
  final seconds = (nanoseconds + BigInt.from(999999999)) ~/ BigInt.from(1e9);
  return _boundedSocketOption(seconds);
}

int _boundedSocketOption(BigInt value) {
  const max = 0x7fffffff;
  return value > BigInt.from(max) ? max : value.toInt();
}
