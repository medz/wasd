import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'doom_runtime.dart';

const String _nativeInputHostKey = 'host';
const String _nativeInputPortKey = 'port';
const int _nativeInputPacketSize = 8;

final class DoomNativeInputClient {
  DoomNativeInputClient._({
    required RawDatagramSocket socket,
    required InternetAddress address,
    required int port,
  }) : _socket = socket,
       _address = address,
       _port = port {
    _socket.readEventsEnabled = false;
    _socket.writeEventsEnabled = false;
  }

  final RawDatagramSocket _socket;
  final InternetAddress _address;
  final int _port;

  static Future<DoomNativeInputClient?> connect(Object? handle) async {
    if (handle is! Map) {
      return null;
    }
    final host = handle[_nativeInputHostKey];
    final port = asIntOrNull(handle[_nativeInputPortKey]);
    if (host is! String || host.isEmpty || port == null || port <= 0) {
      return null;
    }
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return DoomNativeInputClient._(
      socket: socket,
      address: InternetAddress(host),
      port: port,
    );
  }

  void send(DoomInputEvent event) {
    final bytes = Uint8List(_nativeInputPacketSize);
    final data = ByteData.sublistView(bytes);
    data.setInt32(0, event.type, Endian.little);
    data.setInt32(4, event.code, Endian.little);
    _socket.send(bytes, _address, _port);
  }

  Future<void> close() async {
    _socket.close();
  }
}

final class DoomNativeInputServer {
  DoomNativeInputServer._(this._socket);

  final RawDatagramSocket _socket;

  static Future<DoomNativeInputServer?> bind() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    socket.readEventsEnabled = false;
    socket.writeEventsEnabled = false;
    return DoomNativeInputServer._(socket);
  }

  Map<String, Object?> get handle => <String, Object?>{
    _nativeInputHostKey: InternetAddress.loopbackIPv4.address,
    _nativeInputPortKey: _socket.port,
  };

  void drainInto(Queue<DoomInputEvent> queue) {
    while (true) {
      final datagram = _socket.receive();
      if (datagram == null) {
        return;
      }
      if (datagram.data.lengthInBytes < _nativeInputPacketSize) {
        continue;
      }
      final data = ByteData.sublistView(datagram.data);
      queue.add(
        DoomInputEvent(
          type: data.getInt32(0, Endian.little),
          code: data.getInt32(4, Endian.little),
        ),
      );
    }
  }

  Future<void> close() async {
    _socket.close();
  }
}
