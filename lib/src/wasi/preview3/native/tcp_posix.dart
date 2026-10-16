part of 'sockets.dart';

final class _PosixTcpBinding implements WASIPreview3TcpBinding {
  _PosixTcpBinding(this._endpoint) : localAddress = _endpoint!.localAddress;

  _PosixTcpEndpoint? _endpoint;

  @override
  final WASIPreview3IpSocketAddress localAddress;

  _PosixTcpEndpoint take() {
    final endpoint = _endpoint;
    if (endpoint == null) throw StateError('TCP binding was already consumed.');
    _endpoint = null;
    return endpoint;
  }

  @override
  void close() {
    _endpoint?.close();
    _endpoint = null;
  }
}

final class _PosixTcpEndpoint {
  _PosixTcpEndpoint(this.fd, this.family) : _poller = _SocketPoller.acquire() {
    try {
      _posix.check(_posix.fcntl(fd, 2, 1)); // FD_CLOEXEC
      final flags = _posix.check(_posix.fcntl(fd, 3, 0));
      _posix.check(_posix.fcntl(fd, 4, flags | (_posix.darwin ? 4 : 0x800)));
      if (_posix.darwin) setOption(0xffff, 0x1022, 1); // SO_NOSIGPIPE
    } on Object {
      close();
      rethrow;
    }
  }

  static _PosixTcpEndpoint bind(WASIPreview3IpSocketAddress address) {
    final family = address.family;
    final endpoint = _PosixTcpEndpoint(
      _posix.check(_posix.socket(_posix.addressFamily(family), 1, 6)),
      family,
    );
    try {
      endpoint.setOption(_posix.socketLevel, _posix.darwin ? 4 : 2, 1);
      if (family == WASIPreview3IpAddressFamily.ipv6) {
        endpoint.setOption(41, _posix.darwin ? 27 : 26, 1); // IPV6_V6ONLY
      }
      _withSockaddr(address, (pointer, length) {
        _posix.check(_posix.bind(endpoint.fd, pointer, length));
      });
      return endpoint;
    } on Object {
      endpoint.close();
      rethrow;
    }
  }

  final int fd;
  final WASIPreview3IpAddressFamily family;
  final _SocketPoller _poller;
  bool closed = false;

  WASIPreview3IpSocketAddress get localAddress => _address(peer: false);
  WASIPreview3IpSocketAddress get remoteAddress => _address(peer: true);

  WASIPreview3IpSocketAddress _address({required bool peer}) {
    final address = calloc<ffi.Uint8>(28);
    final length = calloc<ffi.Uint32>()..value = 28;
    try {
      _posix.check(
        peer
            ? _posix.getpeername(fd, address, length)
            : _posix.getsockname(fd, address, length),
      );
      final bytes = address.asTypedList(length.value);
      return _socketAddress(
        io.InternetAddress.fromRawAddress(
          Uint8List.fromList(
            family == WASIPreview3IpAddressFamily.ipv4
                ? bytes.sublist(4, 8)
                : bytes.sublist(8, 24),
          ),
        ),
        (bytes[2] << 8) | bytes[3],
      );
    } finally {
      calloc.free(length);
      calloc.free(address);
    }
  }

  Future<void> connect(WASIPreview3IpSocketAddress remote) async {
    _internetAddress(remote);
    final result = _withSockaddr(
      remote,
      (pointer, length) => _posix.connect(fd, pointer, length),
    );
    if (result < 0) {
      final error = _posix.errno;
      if (error != (_posix.darwin ? 36 : 115) && error != 4) {
        throw io.OSError('connect', error);
      }
      if (!await _poller.wait(fd, 4) || closed) {
        throw const io.SocketException('TCP connect cancelled');
      }
      final value = calloc<ffi.Int32>();
      final length = calloc<ffi.Uint32>()..value = 4;
      try {
        _posix.check(
          _posix.getsockopt(
            fd,
            _posix.socketLevel,
            _posix.darwin ? 0x1007 : 4, // SO_ERROR
            value.cast(),
            length,
          ),
        );
        if (value.value != 0) throw io.OSError('connect', value.value);
      } finally {
        calloc.free(length);
        calloc.free(value);
      }
    }
    if (closed) throw const io.SocketException('TCP connect cancelled');
  }

  void listen(int backlog) => _posix.check(_posix.listen(fd, backlog));

  void setOption(int level, int option, int value) {
    final pointer = calloc<ffi.Int32>()..value = value;
    try {
      _posix.check(_posix.setsockopt(fd, level, option, pointer.cast(), 4));
    } finally {
      calloc.free(pointer);
    }
  }

  void applyOptions(
    WASIPreview3TcpSocketOptions options,
    NativeSocketOptionAbi abi,
  ) {
    setOption(
      _posix.socketLevel,
      abi.socketKeepAlive,
      options.keepAliveEnabled ? 1 : 0,
    );
    setOption(6, abi.tcpKeepIdle!, _posixDuration(options.keepAliveIdle));
    setOption(
      6,
      abi.tcpKeepInterval!,
      _posixDuration(options.keepAliveInterval),
    );
    setOption(6, abi.tcpKeepCount!, options.keepAliveCount);
    setOption(
      family == WASIPreview3IpAddressFamily.ipv4 ? 0 : 41,
      family == WASIPreview3IpAddressFamily.ipv4
          ? abi.ipv4Ttl
          : abi.ipv6UnicastHops,
      options.hopLimit,
    );
    setOption(
      _posix.socketLevel,
      abi.socketReceiveBuffer,
      _posixBounded(options.receiveBufferSize),
    );
    setOption(
      _posix.socketLevel,
      abi.socketSendBuffer,
      _posixBounded(options.sendBufferSize),
    );
  }

  void close() {
    if (closed) return;
    closed = true;
    _poller.cancel(fd);
    _posix.close(fd);
    _poller.release();
  }
}

final class _PosixTcpListener implements WASIPreview3TcpListener {
  _PosixTcpListener(this._endpoint, this._createConnection)
    : localAddress = _endpoint.localAddress;

  final _PosixTcpEndpoint _endpoint;
  final WASIPreview3TcpConnection Function(_PosixTcpEndpoint) _createConnection;
  WASIPreview3TcpSocketOptions? _options;
  NativeSocketOptionAbi? _optionAbi;
  bool _ready = true;

  @override
  final WASIPreview3IpSocketAddress localAddress;

  void applyOptions(
    WASIPreview3TcpSocketOptions options,
    NativeSocketOptionAbi abi,
  ) {
    _endpoint.applyOptions(options, abi);
    _options = options;
    _optionAbi = abi;
  }

  @override
  bool get canAccept => _ready || _endpoint.closed;

  @override
  Future<void> waitAccept() async {
    if (!canAccept) {
      final ready = await _endpoint._poller.wait(_endpoint.fd, 1);
      if (!ready) _endpoint.close();
      _ready = true;
    }
  }

  @override
  WASIPreview3SocketResult<WASIPreview3TcpConnection> accept() {
    if (_endpoint.closed) {
      return const WASIPreview3SocketResult.error('connection-aborted');
    }
    while (true) {
      final fd = _posix.accept(_endpoint.fd, ffi.nullptr, ffi.nullptr);
      if (fd < 0) {
        final error = _posix.errno;
        if (error == 4) continue;
        _ready = false;
        return WASIPreview3SocketResult.error(
          _posix.wouldBlock(error)
              ? 'would-block'
              : _socketErrorCode(io.OSError('accept', error)),
        );
      }
      final connection = _PosixTcpEndpoint(fd, _endpoint.family);
      try {
        final options = _options;
        if (options != null) connection.applyOptions(options, _optionAbi!);
        return WASIPreview3SocketResult.ok(_createConnection(connection));
      } on Object catch (error) {
        connection.close();
        return WASIPreview3SocketResult.error(_socketErrorCode(error));
      }
    }
  }

  @override
  void close() => _endpoint.close();
}

WASIPreview3TcpConnection _posixTcpConnection(_PosixTcpEndpoint endpoint) {
  final done = Completer<WASIPreview3SocketResult<void>>();
  var receiveClosed = false;
  var sendClosed = false;
  late final WASIComponentStream<int> incoming;

  void finishIncoming(WASIPreview3SocketResult<void> result) {
    if (!incoming.writable.isClosed) incoming.writable.close();
    if (!done.isCompleted) done.complete(result);
  }

  void closeReceive() {
    if (receiveClosed || endpoint.closed) return;
    receiveClosed = true;
    _posix.shutdown(endpoint.fd, 0);
    endpoint._poller.cancel(endpoint.fd, events: 1);
    finishIncoming(const WASIPreview3SocketResult.ok());
  }

  incoming = WASIComponentStream<int>(
    'native-tcp-fd-${endpoint.fd}',
    maxBufferedElements: 65536,
    onDrop: closeReceive,
  );

  Future<void> receive() async {
    final buffer = malloc<ffi.Uint8>(65536);
    var bytesSinceYield = 0;
    try {
      while (!endpoint.closed && !receiveClosed) {
        final count = _posix.recv(endpoint.fd, buffer.cast(), 65536, 0);
        if (count > 0) {
          await _writeAll(incoming.writable, buffer.asTypedList(count));
          bytesSinceYield += count;
          if (bytesSinceYield >= 1024 * 1024) {
            bytesSinceYield = 0;
            // Completed stream futures only yield to microtasks. Bound each
            // receive burst so timers and cancellation can run as well.
            await Future<void>.delayed(Duration.zero);
          }
          continue;
        }
        if (count == 0) {
          finishIncoming(const WASIPreview3SocketResult.ok());
          return;
        }
        final error = _posix.errno;
        if (error == 4) continue;
        if (!_posix.wouldBlock(error)) throw io.OSError('recv', error);
        bytesSinceYield = 0;
        if (!await endpoint._poller.wait(endpoint.fd, 1)) {
          if (!endpoint.closed && !receiveClosed) {
            finishIncoming(
              const WASIPreview3SocketResult.error('connection-aborted'),
            );
          }
          return;
        }
      }
    } on Object catch (error) {
      if (!receiveClosed && !endpoint.closed) {
        finishIncoming(WASIPreview3SocketResult.error(_socketErrorCode(error)));
      }
    } finally {
      malloc.free(buffer);
    }
  }

  Future<WASIPreview3SocketResult<void>> write(Uint8List bytes) async {
    if (endpoint.closed || sendClosed) {
      return const WASIPreview3SocketResult.error('connection-broken');
    }
    final buffer = malloc<ffi.Uint8>(bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    try {
      var offset = 0;
      while (offset < bytes.length) {
        if (endpoint.closed) {
          return const WASIPreview3SocketResult.error('connection-aborted');
        }
        final count = _posix.send(
          endpoint.fd,
          (buffer + offset).cast(),
          bytes.length - offset,
          _posix.darwin ? 0 : 0x4000, // MSG_NOSIGNAL
        );
        if (count > 0) {
          offset += count;
          continue;
        }
        final error = _posix.errno;
        if (error == 4) continue;
        if (count == 0 || !_posix.wouldBlock(error)) {
          throw io.OSError('send', count == 0 ? 32 : error);
        }
        if (!await endpoint._poller.wait(endpoint.fd, 4)) {
          return const WASIPreview3SocketResult.error('connection-aborted');
        }
      }
      return const WASIPreview3SocketResult.ok();
    } on Object catch (error) {
      return WASIPreview3SocketResult.error(_socketErrorCode(error));
    } finally {
      malloc.free(buffer);
    }
  }

  final connection = WASIPreview3TcpConnection(
    incoming: incoming,
    incomingDone: done.future,
    write: write,
    finishSend: () {
      if (endpoint.closed || sendClosed) {
        return const WASIPreview3SocketResult.error('invalid-state');
      }
      sendClosed = true;
      try {
        _posix.check(_posix.shutdown(endpoint.fd, 1));
        return const WASIPreview3SocketResult.ok();
      } on Object catch (error) {
        return WASIPreview3SocketResult.error(_socketErrorCode(error));
      }
    },
    closeReceive: closeReceive,
    localAddress: endpoint.localAddress,
    remoteAddress: endpoint.remoteAddress,
    close: () {
      if (endpoint.closed) return;
      endpoint.close();
      finishIncoming(
        const WASIPreview3SocketResult.error('connection-aborted'),
      );
    },
  );
  unawaited(receive());
  return connection;
}

int _posixDuration(BigInt nanoseconds) => _posixBounded(
  (nanoseconds + BigInt.from(999999999)) ~/ BigInt.from(1000000000),
);

int _posixBounded(BigInt value) =>
    value > BigInt.from(0x7fffffff) ? 0x7fffffff : value.toInt();

T _withSockaddr<T>(
  WASIPreview3IpSocketAddress address,
  T Function(ffi.Pointer<ffi.Uint8>, int) use,
) {
  final ipv4 = address.family == WASIPreview3IpAddressFamily.ipv4;
  final length = ipv4 ? 16 : 28;
  final pointer = calloc<ffi.Uint8>(length);
  try {
    final bytes = pointer.asTypedList(length);
    final family = _posix.addressFamily(address.family);
    if (_posix.darwin) {
      bytes[0] = length;
      bytes[1] = family;
    } else {
      ByteData.sublistView(bytes).setUint16(0, family, Endian.host);
    }
    bytes[2] = address.port >> 8;
    bytes[3] = address.port & 0xff;
    bytes.setAll(ipv4 ? 4 : 8, _internetAddress(address).rawAddress);
    return use(pointer, length);
  } finally {
    calloc.free(pointer);
  }
}

// One sleeping poll isolate serves all explicitly bound endpoints. Watch IDs
// are never reused while pending, so a closed/reused FD cannot wake a new wait.
final class _SocketPoller {
  _SocketPoller();

  static _SocketPoller? _shared;
  static _SocketPoller acquire() {
    final poller = _shared ??= _SocketPoller();
    poller._references++;
    return poller;
  }

  int _references = 0;
  int _nextId = 0;
  int _writeFd = -1;
  bool _closed = false;
  bool _failed = false;
  ReceivePort? _port;
  Future<void>? _starting;
  final Map<int, ({int fd, int events, Completer<bool> done})> _waiters = {};

  Future<void> _start() async {
    final pipe = calloc<ffi.Int32>(2);
    try {
      _posix.check(_posix.pipe(pipe));
      final readFd = pipe[0];
      _writeFd = pipe[1];
      final port = _port = ReceivePort();
      port.listen((message) {
        if (message is! List<int>) {
          _fail();
          return;
        }
        for (final id in message) {
          _waiters.remove(id)?.done.complete(true);
        }
      });
      try {
        _posix.check(_posix.fcntl(readFd, 2, 1));
        _posix.check(_posix.fcntl(_writeFd, 2, 1));
        await Isolate.spawn(
          _pollSockets,
          <Object>[readFd, port.sendPort],
          onError: port.sendPort,
          onExit: port.sendPort,
        );
      } on Object {
        _posix.close(readFd);
        rethrow;
      }
      if (_closed || _failed) _stop();
    } finally {
      calloc.free(pipe);
    }
  }

  Future<bool> wait(int fd, int events) async {
    if (_closed || _failed) return false;
    do {
      _nextId = (_nextId + 1) & 0x7fffffff;
    } while (_nextId == 0 || _waiters.containsKey(_nextId));
    final id = _nextId;
    final done = Completer<bool>();
    _waiters[id] = (fd: fd, events: events, done: done);
    try {
      await (_starting ??= _start());
      if (_waiters.containsKey(id)) _command(id, fd, events);
    } on Object {
      _fail();
    }
    return done.future;
  }

  void cancel(int fd, {int? events}) {
    final ids = <int>[
      for (final entry in _waiters.entries)
        if (entry.value.fd == fd &&
            (events == null || entry.value.events == events))
          entry.key,
    ];
    for (final id in ids) {
      final waiter = _waiters.remove(id);
      if (waiter == null) continue;
      waiter.done.complete(false);
      if (_writeFd >= 0 && !_closed && !_failed) {
        try {
          _command(id, -1, 0);
        } on Object {
          _fail();
        }
      }
    }
  }

  void _command(int id, int fd, int events) {
    final command = calloc<ffi.Int32>(3);
    try {
      command[0] = id;
      command[1] = fd;
      command[2] = events;
      while (_posix.write(_writeFd, command.cast(), 12) < 0) {
        if (_posix.errno != 4) throw io.OSError('poll wake', _posix.errno);
      }
    } finally {
      calloc.free(command);
    }
  }

  void release() {
    if (--_references != 0) return;
    _closed = true;
    if (identical(_shared, this)) _shared = null;
    for (final waiter in _waiters.values) {
      waiter.done.complete(false);
    }
    _waiters.clear();
    _stop();
  }

  void _fail() {
    _failed = true;
    if (identical(_shared, this)) _shared = null;
    for (final waiter in _waiters.values) {
      waiter.done.complete(false);
    }
    _waiters.clear();
    _stop();
  }

  void _stop() {
    _port?.close();
    if (_writeFd < 0) return;
    _posix.close(_writeFd);
    _writeFd = -1;
  }
}

void _pollSockets(List<Object> args) {
  final readFd = args[0] as int;
  final port = args[1] as SendPort;
  final watches = <int, ({int fd, int events})>{};
  final commands = calloc<ffi.Int32>(768);
  try {
    while (true) {
      final entries = watches.entries.toList();
      final count = entries.length + 1;
      final pollFds = calloc<ffi.Uint8>(count * 8);
      try {
        final data = ByteData.sublistView(pollFds.asTypedList(count * 8));
        data.setInt32(0, readFd, Endian.host);
        data.setInt16(4, 1, Endian.host);
        for (var index = 0; index < entries.length; index++) {
          data.setInt32((index + 1) * 8, entries[index].value.fd, Endian.host);
          data.setInt16(
            (index + 1) * 8 + 4,
            entries[index].value.events,
            Endian.host,
          );
        }
        final result = _posix.poll(pollFds.cast(), count, -1);
        if (result < 0) {
          if (_posix.errno == 4) continue;
          throw io.OSError('poll', _posix.errno);
        }
        if (data.getInt16(6, Endian.host) != 0) {
          final bytes = _posix.read(readFd, commands.cast(), 3072);
          if (bytes == 0) return;
          if (bytes < 0) {
            if (_posix.errno == 4) continue;
            throw io.OSError('poll commands', _posix.errno);
          }
          for (var index = 0; index < bytes ~/ 4; index += 3) {
            final id = commands[index];
            final fd = commands[index + 1];
            if (fd < 0) {
              watches.remove(id);
            } else {
              watches[id] = (fd: fd, events: commands[index + 2]);
            }
          }
        }
        final ready = <int>[];
        for (var index = 0; index < entries.length; index++) {
          if (data.getInt16((index + 1) * 8 + 6, Endian.host) != 0 &&
              watches.remove(entries[index].key) != null) {
            ready.add(entries[index].key);
          }
        }
        if (ready.isNotEmpty) port.send(ready);
      } finally {
        calloc.free(pollFds);
      }
    }
  } finally {
    calloc.free(commands);
    _posix.close(readFd);
  }
}

final _posix = _PosixSockets();

final class _PosixSockets {
  _PosixSockets()
    : _library = io.Platform.isLinux
          ? ffi.DynamicLibrary.open('libc.so.6')
          : ffi.DynamicLibrary.process();

  final ffi.DynamicLibrary _library;
  bool get darwin => io.Platform.isMacOS;
  int get socketLevel => darwin ? 0xffff : 1;
  int addressFamily(WASIPreview3IpAddressFamily family) =>
      family == WASIPreview3IpAddressFamily.ipv4 ? 2 : (darwin ? 30 : 10);
  bool wouldBlock(int error) => error == (darwin ? 35 : 11);
  int get errno => _errno().value;
  int check(int result) {
    if (result < 0) throw io.OSError('POSIX socket', errno);
    return result;
  }

  late final _errno = _library
      .lookupFunction<
        ffi.Pointer<ffi.Int32> Function(),
        ffi.Pointer<ffi.Int32> Function()
      >(darwin ? '__error' : '__errno_location');
  late final socket = _library
      .lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Int32, ffi.Int32),
        int Function(int, int, int)
      >('socket');
  late final bind = _library
      .lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Uint32),
        int Function(int, ffi.Pointer<ffi.Uint8>, int)
      >('bind');
  late final connect = _library
      .lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Uint32),
        int Function(int, ffi.Pointer<ffi.Uint8>, int)
      >('connect');
  late final listen = _library
      .lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Int32),
        int Function(int, int)
      >('listen');
  late final accept = _library
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Int32,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint32>,
        ),
        int Function(int, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint32>)
      >('accept');
  late final getsockname = _library
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Int32,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint32>,
        ),
        int Function(int, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint32>)
      >('getsockname');
  late final getpeername = _library
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Int32,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint32>,
        ),
        int Function(int, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint32>)
      >('getpeername');
  late final setsockopt = _library
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Int32,
          ffi.Int32,
          ffi.Int32,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
        ),
        int Function(int, int, int, ffi.Pointer<ffi.Void>, int)
      >('setsockopt');
  late final getsockopt = _library
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Int32,
          ffi.Int32,
          ffi.Int32,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint32>,
        ),
        int Function(
          int,
          int,
          int,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint32>,
        )
      >('getsockopt');
  late final fcntl = _library
      .lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Int32, ffi.VarArgs<(ffi.Int32,)>),
        int Function(int, int, int)
      >('fcntl');
  late final close = _library
      .lookupFunction<ffi.Int32 Function(ffi.Int32), int Function(int)>(
        'close',
      );
  late final shutdown = _library
      .lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Int32),
        int Function(int, int)
      >('shutdown');
  late final recv = _library
      .lookupFunction<
        ffi.IntPtr Function(
          ffi.Int32,
          ffi.Pointer<ffi.Void>,
          ffi.UintPtr,
          ffi.Int32,
        ),
        int Function(int, ffi.Pointer<ffi.Void>, int, int)
      >('recv');
  late final send = _library
      .lookupFunction<
        ffi.IntPtr Function(
          ffi.Int32,
          ffi.Pointer<ffi.Void>,
          ffi.UintPtr,
          ffi.Int32,
        ),
        int Function(int, ffi.Pointer<ffi.Void>, int, int)
      >('send');
  late final pipe = _library
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Int32>),
        int Function(ffi.Pointer<ffi.Int32>)
      >('pipe');
  late final poll = darwin
      ? _library.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Int32),
          int Function(ffi.Pointer<ffi.Void>, int, int)
        >('poll')
      : _library.lookupFunction<
          ffi.Int32 Function(
            ffi.Pointer<ffi.Void>,
            ffi.UnsignedLong,
            ffi.Int32,
          ),
          int Function(ffi.Pointer<ffi.Void>, int, int)
        >('poll');
  late final read = _library
      .lookupFunction<
        ffi.IntPtr Function(ffi.Int32, ffi.Pointer<ffi.Void>, ffi.UintPtr),
        int Function(int, ffi.Pointer<ffi.Void>, int)
      >('read');
  late final write = _library
      .lookupFunction<
        ffi.IntPtr Function(ffi.Int32, ffi.Pointer<ffi.Void>, ffi.UintPtr),
        int Function(int, ffi.Pointer<ffi.Void>, int)
      >('write');
}
