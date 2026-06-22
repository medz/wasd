import 'dart:collection';
import 'dart:typed_data';

const int _receiveCompactionThreshold = 64 * 1024;

/// Supplies stream bytes for a host-backed Preview1 socket.
///
/// The provider should return at most [maxBytes] bytes that can be consumed by
/// a future `sock_recv` call. Returning an empty list means no host bytes were
/// available at the time of the call.
typedef WASIPreview1SocketReceiveDataProvider =
    List<int> Function(int maxBytes);

/// Handles stream bytes written through a host-backed Preview1 socket.
///
/// Return the number of bytes accepted by the host. Returning fewer than
/// [length] bytes makes the current `sock_send` stop at that partial write.
typedef WASIPreview1SocketSendHandler =
    int Function(Uint8List source, int sourceStart, int length);

/// Supplies one datagram message for a host-backed Preview1 socket.
///
/// Return `null` when no message is available. Return an empty list for a
/// queued zero-length datagram.
typedef WASIPreview1SocketReceiveMessageProvider = List<int>? Function();

/// Handles one datagram message written through a host-backed Preview1 socket.
///
/// Return the number of bytes accepted by the host.
typedef WASIPreview1SocketSendMessageHandler = int Function(Uint8List message);

/// Host-side socket state for WASI Preview1 descriptors.
///
/// The in-repo native and browser Preview1 shims use this object for inherited
/// socket descriptors supplied through [WASI]. It models the descriptor-level
/// `sock_accept`, `sock_recv`, `sock_send`, and `sock_shutdown` behavior that
/// Preview1 standardizes, without claiming that Preview1 can create network
/// connections itself.
final class WASIPreview1Socket {
  /// Creates a byte-stream socket with optional receive data and queued accepts.
  WASIPreview1Socket({
    List<int> receiveData = const <int>[],
    Iterable<WASIPreview1Socket> pendingAccepted = const <WASIPreview1Socket>[],
    int? readReadyBytes,
    WASIPreview1SocketReceiveDataProvider? receiveDataProvider,
    WASIPreview1SocketSendHandler? sendHandler,
    this.writeReady,
  }) : _kind = _WASIPreview1SocketKind.stream,
       _receiveBytes = List<int>.of(receiveData, growable: true),
       _receiveMessages = ListQueue<Uint8List>(),
       _receiveDataProvider = receiveDataProvider,
       _sendHandler = sendHandler,
       _receiveMessageProvider = null,
       _sendMessageHandler = null,
       _pendingAccepted = ListQueue<WASIPreview1Socket>.of(pendingAccepted) {
    this.readReadyBytes = readReadyBytes;
    for (final socket in _pendingAccepted) {
      _validateAcceptedSocket(socket);
    }
  }

  /// Creates a datagram socket with optional queued receive messages.
  WASIPreview1Socket.datagram({
    Iterable<List<int>> receiveMessages = const <List<int>>[],
    WASIPreview1SocketReceiveMessageProvider? receiveMessageProvider,
    WASIPreview1SocketSendMessageHandler? sendMessageHandler,
    int? readReadyBytes,
    this.writeReady,
  }) : _kind = _WASIPreview1SocketKind.datagram,
       _receiveBytes = <int>[],
       _receiveMessages = ListQueue<Uint8List>.of(
         receiveMessages.map(Uint8List.fromList),
       ),
       _receiveDataProvider = null,
       _sendHandler = null,
       _receiveMessageProvider = receiveMessageProvider,
       _sendMessageHandler = sendMessageHandler,
       _pendingAccepted = ListQueue<WASIPreview1Socket>() {
    this.readReadyBytes = readReadyBytes;
  }

  final _WASIPreview1SocketKind _kind;
  final List<int> _receiveBytes;
  final BytesBuilder _sentBytes = BytesBuilder(copy: true);
  final ListQueue<Uint8List> _receiveMessages;
  final List<Uint8List> _sentMessages = <Uint8List>[];
  final WASIPreview1SocketReceiveDataProvider? _receiveDataProvider;
  final WASIPreview1SocketSendHandler? _sendHandler;
  final WASIPreview1SocketReceiveMessageProvider? _receiveMessageProvider;
  final WASIPreview1SocketSendMessageHandler? _sendMessageHandler;
  final ListQueue<WASIPreview1Socket> _pendingAccepted;
  int? _readReadyBytes;
  int _receiveOffset = 0;

  /// Whether further receive operations have been shut down.
  bool receiveShutdown = false;

  /// Whether further send operations have been shut down.
  bool sendShutdown = false;

  /// Host-supplied read readiness when no receive data is buffered.
  ///
  /// Leave this as `null` to derive readiness from queued bytes, queued
  /// datagrams, queued accepts, and receive shutdown state.
  int? get readReadyBytes => _readReadyBytes;

  set readReadyBytes(int? value) {
    if (value != null && value < 0) {
      throw ArgumentError.value(
        value,
        'readReadyBytes',
        'must not be negative',
      );
    }
    _readReadyBytes = value;
  }

  /// Host-supplied write readiness.
  ///
  /// Leave this as `null` to use the default Preview1 descriptor behavior:
  /// writable unless the send side has been shut down. Set this to `false` to
  /// make polling report the descriptor as not writable and `sock_send` return
  /// `EAGAIN` without recording sent bytes.
  bool? writeReady;

  /// Returns a copy of the bytes sent through `sock_send`.
  Uint8List get sentData => _sentBytes.toBytes();

  /// Returns copies of datagram messages sent through `sock_send`.
  List<Uint8List> get sentMessages => <Uint8List>[
    for (final message in _sentMessages) Uint8List.fromList(message),
  ];

  /// Returns a copy of currently unread receive bytes.
  Uint8List get remainingReceiveData {
    final length = _receiveBytes.length - _receiveOffset;
    final result = Uint8List(length);
    if (length > 0) {
      result.setRange(0, length, _receiveBytes, _receiveOffset);
    }
    return result;
  }

  /// Number of currently unread receive bytes.
  int get remainingReceiveLength => _receiveBytes.length - _receiveOffset;

  /// Returns copies of queued datagram receive messages.
  List<Uint8List> get remainingReceiveMessages => <Uint8List>[
    for (final message in _receiveMessages) Uint8List.fromList(message),
  ];

  /// Whether this descriptor is a datagram socket.
  bool get isDatagram => _kind == _WASIPreview1SocketKind.datagram;

  /// Whether this descriptor is a byte-stream socket.
  bool get isStream => _kind == _WASIPreview1SocketKind.stream;

  /// Whether a datagram message is queued for receive.
  bool get hasReceiveMessage {
    ensureReceiveMessage();
    return _receiveMessages.isNotEmpty;
  }

  /// Whether a future `sock_accept` call can return an accepted stream.
  bool get hasPendingAccept => _pendingAccepted.isNotEmpty;

  /// Length of the next queued datagram receive message.
  int get nextReceiveMessageLength {
    ensureReceiveMessage();
    return _receiveMessages.isEmpty ? 0 : _receiveMessages.first.length;
  }

  /// Appends bytes that future `sock_recv` calls can consume.
  ///
  /// For datagram sockets, [data] is queued as one receive message.
  void addReceiveData(List<int> data) {
    if (receiveShutdown) {
      return;
    }
    if (isDatagram) {
      _receiveMessages.add(Uint8List.fromList(data));
      return;
    }
    _appendReceiveBytes(data);
  }

  /// Pulls host-backed stream bytes until at least [minUnreadBytes] are queued.
  ///
  /// Most callers should use `sock_recv` rather than calling this directly.
  /// The shared Preview1 host uses it to make `RECV_WAITALL` observe the same
  /// host-backed stream data as normal reads.
  int ensureReceiveData(int minUnreadBytes) {
    final provider = _receiveDataProvider;
    if (!isStream ||
        receiveShutdown ||
        provider == null ||
        minUnreadBytes <= remainingReceiveLength) {
      return 0;
    }
    final data = provider(minUnreadBytes - remainingReceiveLength);
    if (data.isEmpty) {
      return 0;
    }
    _appendReceiveBytes(data);
    final readyBytes = _readReadyBytes;
    if (readyBytes != null) {
      _readReadyBytes = data.length >= readyBytes
          ? null
          : readyBytes - data.length;
    }
    return data.length;
  }

  /// Pulls one host-backed datagram message when no message is queued.
  bool ensureReceiveMessage() {
    final provider = _receiveMessageProvider;
    if (!isDatagram ||
        receiveShutdown ||
        provider == null ||
        _receiveMessages.isNotEmpty) {
      return false;
    }
    final message = provider();
    if (message == null) {
      return false;
    }
    _receiveMessages.add(Uint8List.fromList(message));
    final readyBytes = _readReadyBytes;
    if (readyBytes != null) {
      _readReadyBytes = message.length >= readyBytes
          ? null
          : readyBytes - message.length;
    }
    return true;
  }

  /// Queues an accepted stream returned by a future `sock_accept` call.
  void queueAccepted(WASIPreview1Socket socket) {
    if (!isStream) {
      throw StateError('Datagram sockets cannot accept connections.');
    }
    _validateAcceptedSocket(socket);
    _pendingAccepted.add(socket);
  }

  static void _validateAcceptedSocket(WASIPreview1Socket socket) {
    if (!socket.isStream) {
      throw StateError('Accepted sockets must be stream sockets.');
    }
  }

  /// Removes all bytes recorded from prior `sock_send` calls.
  void clearSentData() {
    _sentBytes.clear();
    _sentMessages.clear();
  }

  /// Reads up to [length] bytes into [target].
  ///
  /// When [peek] is true, bytes are copied without advancing the receive queue.
  int readInto(
    Uint8List target,
    int targetStart,
    int length, {
    bool peek = false,
    int socketOffset = 0,
  }) {
    if (length <= 0 || receiveShutdown) {
      return 0;
    }
    ensureReceiveData(socketOffset + length);
    final readOffset = _receiveOffset + socketOffset;
    final available = _receiveBytes.length - readOffset;
    if (available <= 0) {
      return 0;
    }
    final count = length < available ? length : available;
    target.setRange(
      targetStart,
      targetStart + count,
      _receiveBytes,
      readOffset,
    );
    if (!peek) {
      _receiveOffset += count;
      _compactReceiveBuffer();
    }
    return count;
  }

  /// Reads bytes from the next queued datagram without consuming it.
  int readMessageInto(
    Uint8List target,
    int targetStart,
    int length, {
    int messageOffset = 0,
  }) {
    if (length <= 0 || receiveShutdown || _receiveMessages.isEmpty) {
      return 0;
    }
    final message = _receiveMessages.first;
    final available = message.length - messageOffset;
    if (available <= 0) {
      return 0;
    }
    final count = length < available ? length : available;
    target.setRange(targetStart, targetStart + count, message, messageOffset);
    return count;
  }

  /// Removes the next queued datagram receive message.
  void consumeReceiveMessage() {
    if (_receiveMessages.isNotEmpty) {
      _receiveMessages.removeFirst();
    }
  }

  /// Appends [length] bytes from [source] to the sent-data buffer.
  int writeFrom(Uint8List source, int sourceStart, int length) {
    if (length <= 0 || sendShutdown) {
      return 0;
    }
    final sendHandler = _sendHandler;
    if (sendHandler != null) {
      final written = sendHandler(source, sourceStart, length);
      if (written < 0 || written > length) {
        throw RangeError.range(written, 0, length, 'written');
      }
      return written;
    }
    final end = sourceStart + length;
    _sentBytes.add(Uint8List.sublistView(source, sourceStart, end));
    return length;
  }

  /// Records one datagram message sent through `sock_send`.
  int writeMessage(List<int> data) {
    if (sendShutdown) {
      return 0;
    }
    final message = data is Uint8List ? data : Uint8List.fromList(data);
    final sendMessageHandler = _sendMessageHandler;
    if (sendMessageHandler != null) {
      final written = sendMessageHandler(message);
      if (written < 0 || written > message.length) {
        throw RangeError.range(written, 0, message.length, 'written');
      }
      return written;
    }
    _sentMessages.add(Uint8List.fromList(message));
    return data.length;
  }

  /// Returns the next queued accepted socket, if one is available.
  WASIPreview1Socket? accept() {
    if (!isStream || _pendingAccepted.isEmpty) {
      return null;
    }
    return _pendingAccepted.removeFirst();
  }

  /// Shuts down future receive and/or send operations.
  void shutdown({required bool receive, required bool send}) {
    if (receive) {
      _receiveBytes.clear();
      _receiveOffset = 0;
      _receiveMessages.clear();
      _readReadyBytes = null;
    }
    receiveShutdown = receiveShutdown || receive;
    sendShutdown = sendShutdown || send;
  }

  void _appendReceiveBytes(List<int> data) {
    if (data.isEmpty || receiveShutdown) {
      return;
    }
    _compactReceiveBuffer();
    _receiveBytes.addAll(data);
  }

  void _compactReceiveBuffer() {
    if (_receiveOffset == 0) {
      return;
    }
    if (_receiveOffset >= _receiveBytes.length) {
      _receiveBytes.clear();
      _receiveOffset = 0;
      return;
    }
    if (_receiveOffset < _receiveCompactionThreshold &&
        _receiveOffset * 2 < _receiveBytes.length) {
      return;
    }
    _receiveBytes.removeRange(0, _receiveOffset);
    _receiveOffset = 0;
  }
}

enum _WASIPreview1SocketKind { stream, datagram }

/// Internal VFS hook for recording an owned datagram message.
///
/// This is hidden from the public `package:wasd/wasi.dart` export. The caller
/// transfers [message] to [socket] and must not mutate it after the call.
int writeWASIPreview1SocketOwnedMessage(
  WASIPreview1Socket socket,
  Uint8List message,
) {
  if (socket.sendShutdown) {
    return 0;
  }
  final sendMessageHandler = socket._sendMessageHandler;
  if (sendMessageHandler != null) {
    final written = sendMessageHandler(message);
    if (written < 0 || written > message.length) {
      throw RangeError.range(written, 0, message.length, 'written');
    }
    return written;
  }
  socket._sentMessages.add(message);
  return message.length;
}
