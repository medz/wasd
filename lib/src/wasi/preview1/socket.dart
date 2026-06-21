import 'dart:collection';
import 'dart:typed_data';

/// Host-side byte-stream socket state for WASI Preview1 descriptors.
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
  }) : _receiveBytes = List<int>.of(receiveData, growable: true),
       _pendingAccepted = ListQueue<WASIPreview1Socket>.of(pendingAccepted);

  final List<int> _receiveBytes;
  final List<int> _sentBytes = <int>[];
  final ListQueue<WASIPreview1Socket> _pendingAccepted;
  int _receiveOffset = 0;

  /// Whether further receive operations have been shut down.
  bool receiveShutdown = false;

  /// Whether further send operations have been shut down.
  bool sendShutdown = false;

  /// Returns a copy of the bytes sent through `sock_send`.
  Uint8List get sentData => Uint8List.fromList(_sentBytes);

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

  /// Appends bytes that future `sock_recv` calls can consume.
  void addReceiveData(List<int> data) {
    if (data.isEmpty) {
      return;
    }
    _compactReceiveBuffer();
    _receiveBytes.addAll(data);
    receiveShutdown = false;
  }

  /// Queues an accepted stream returned by a future `sock_accept` call.
  void queueAccepted(WASIPreview1Socket socket) {
    _pendingAccepted.add(socket);
  }

  /// Removes all bytes recorded from prior `sock_send` calls.
  void clearSentData() {
    _sentBytes.clear();
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

  /// Appends [length] bytes from [source] to the sent-data buffer.
  int writeFrom(Uint8List source, int sourceStart, int length) {
    if (length <= 0 || sendShutdown) {
      return 0;
    }
    final end = sourceStart + length;
    for (var index = sourceStart; index < end; index++) {
      _sentBytes.add(source[index]);
    }
    return length;
  }

  /// Returns the next queued accepted socket, if one is available.
  WASIPreview1Socket? accept() {
    if (_pendingAccepted.isEmpty) {
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
    if (_receiveOffset < 4096 && _receiveOffset * 2 < _receiveBytes.length) {
      return;
    }
    _receiveBytes.removeRange(0, _receiveOffset);
    _receiveOffset = 0;
  }
}
