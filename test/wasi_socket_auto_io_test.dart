@TestOn('vm')
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi_socket_auto_io.dart' as auto_io;
import 'package:wasd/src/wasi_socket_transport.dart';

void main() {
  group('wasi_socket_auto_io', () {
    test('accept maps pending connection into dynamic stream fd', () async {
      final listener = await RawServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final transport = auto_io.createAutoWasiSocketTransport(
        preopenedSockets: {3: listener},
      );

      addTearDown(() {
        transport.close?.call(fd: 3);
      });

      final peer = await Socket.connect(
        InternetAddress.loopbackIPv4,
        listener.port,
      );
      addTearDown(() async {
        await peer.close();
      });

      var nextFd = 10;
      final accepted = await _acceptEventually(
        transport: transport,
        listenerFd: 3,
        allocateFd: () => nextFd++,
      );

      expect(accepted.errno, _errnoSuccess);
      expect(accepted.acceptedFd, 10);
      expect(transport.containsFd?.call(fd: 10), isTrue);
      expect(transport.close?.call(fd: 10), _errnoSuccess);
    });

    test('recv/send use host socket bytes with errno semantics', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final rawClient = await RawSocket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final peer = await server.first;
      final transport = auto_io.createAutoWasiSocketTransport(
        preopenedSockets: {5: rawClient},
      );

      addTearDown(() async {
        transport.close?.call(fd: 5);
        await peer.close();
        await server.close();
      });

      final noData = transport.recv?.call(fd: 5, flags: 0, maxBytes: 16);
      expect(noData?.errno, _errnoAgain);

      peer.add(const [1, 2, 3, 4]);
      await peer.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final received = transport.recv?.call(fd: 5, flags: 0, maxBytes: 3);
      expect(received?.errno, _errnoSuccess);
      expect(received?.data, [1, 2, 3]);

      final sent = transport.send?.call(
        fd: 5,
        flags: 0,
        data: Uint8List.fromList(const [9, 8, 7]),
      );
      expect(sent?.errno, anyOf(_errnoSuccess, _errnoAgain));
      if (sent?.errno == _errnoSuccess) {
        expect(sent?.bytesWritten, 3);
        final echoed = await peer.first.timeout(const Duration(seconds: 2));
        expect(echoed.take(3), [9, 8, 7]);
      }

      expect(transport.shutdown?.call(fd: 5, how: 99), _errnoInval);
      expect(transport.shutdown?.call(fd: 5, how: 1), _errnoSuccess);
      expect(transport.close?.call(fd: 5), _errnoSuccess);
      expect(transport.close?.call(fd: 999), isNull);
    });
  });
}

Future<WasiSockAcceptResult> _acceptEventually({
  required WasiSocketTransport transport,
  required int listenerFd,
  required WasiSockAllocateFd allocateFd,
}) async {
  WasiSockAcceptResult result = const WasiSockAcceptResult.error(_errnoAgain);
  for (var i = 0; i < 120; i++) {
    result =
        transport.accept?.call(
          fd: listenerFd,
          flags: 0,
          allocateFd: allocateFd,
        ) ??
        const WasiSockAcceptResult.error(_errnoBadf);
    if (result.errno == _errnoSuccess) {
      return result;
    }
    if (result.errno != _errnoAgain) {
      return result;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return result;
}

const int _errnoSuccess = 0;
const int _errnoAgain = 6;
const int _errnoBadf = 8;
const int _errnoInval = 28;
