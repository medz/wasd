import 'dart:collection';
import 'dart:typed_data';

const int _receiveCompactionThreshold = 64 * 1024;

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
    this.writeReady,
  }) : _kind = _WASIPreview1SocketKind.stream,
       _receiveBytes = List<int>.of(receiveData, growable: true),
       _receiveMessages = ListQueue<Uint8List>(),
       _pendingAccepted = ListQueue<WASIPreview1Socket>.of(pendingAccepted) {
    this.readReadyBytes = readReadyBytes;
  }

  /// Creates a datagram socket with optional queued receive messages.
  WASIPreview1Socket.datagram({
    Iterable<List<int>> receiveMessages = const <List<int>>[],
    int? readReadyBytes,
    this.writeReady,
  }) : _kind = _WASIPreview1SocketKind.datagram,
       _receiveBytes = <int>[],
       _receiveMessages = ListQueue<Uint8List>.of(
         receiveMessages.map(Uint8List.fromList),
       ),
       _pendingAccepted = ListQueue<WASIPreview1Socket>() {
    this.readReadyBytes = readReadyBytes;
  }

  final _WASIPreview1SocketKind _kind;
  final List<int> _receiveBytes;
  final BytesBuilder _sentBytes = BytesBuilder(copy: true);
  final ListQueue<Uint8List> _receiveMessages;
  final List<Uint8List> _sentMessages = <Uint8List>[];
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
  /// writable unless the send side has been shut down.
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
  bool get hasReceiveMessage => _receiveMessages.isNotEmpty;

  /// Whether a future `sock_accept` call can return an accepted stream.
  bool get hasPendingAccept => _pendingAccepted.isNotEmpty;

  /// Length of the next queued datagram receive message.
  int get nextReceiveMessageLength =>
      _receiveMessages.isEmpty ? 0 : _receiveMessages.first.length;

  /// Appends bytes that future `sock_recv` calls can consume.
  ///
  /// For datagram sockets, [data] is queued as one receive message.
  void addReceiveData(List<int> data) {
    if (isDatagram) {
      _receiveMessages.add(Uint8List.fromList(data));
      receiveShutdown = false;
      return;
    }
    if (data.isEmpty) {
      return;
    }
    _compactReceiveBuffer();
    _receiveBytes.addAll(data);
    receiveShutdown = false;
  }

  /// Queues an accepted stream returned by a future `sock_accept` call.
  void queueAccepted(WASIPreview1Socket socket) {
    if (!isStream) {
      throw StateError('Datagram sockets cannot accept connections.');
    }
    _pendingAccepted.add(socket);
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
    final end = sourceStart + length;
    _sentBytes.add(Uint8List.sublistView(source, sourceStart, end));
    return length;
  }

  /// Records one datagram message sent through `sock_send`.
  int writeMessage(List<int> data) {
    if (sendShutdown) {
      return 0;
    }
    _sentMessages.add(Uint8List.fromList(data));
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
    receiveShutdown = receiveShutdown || receive;
    sendShutdown = sendShutdown || send;
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
