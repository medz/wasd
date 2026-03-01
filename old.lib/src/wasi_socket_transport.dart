import 'dart:typed_data';

typedef WasiSockAllocateFd = int Function();
typedef WasiSockAcceptHandler =
    WasiSockAcceptResult Function({
      required int fd,
      required int flags,
      required WasiSockAllocateFd allocateFd,
    });
typedef WasiSockRecvHandler =
    WasiSockRecvResult Function({
      required int fd,
      required int flags,
      required int maxBytes,
    });
typedef WasiSockSendHandler =
    WasiSockSendResult Function({
      required int fd,
      required int flags,
      required Uint8List data,
    });
typedef WasiSockShutdownHandler =
    int Function({required int fd, required int how});
typedef WasiSockCloseHandler = int Function({required int fd});
typedef WasiSockContainsFdHandler = bool Function({required int fd});

final class WasiSocketTransport {
  const WasiSocketTransport({
    this.accept,
    this.recv,
    this.send,
    this.shutdown,
    this.close,
    this.containsFd,
  });

  final WasiSockAcceptHandler? accept;
  final WasiSockRecvHandler? recv;
  final WasiSockSendHandler? send;
  final WasiSockShutdownHandler? shutdown;
  final WasiSockCloseHandler? close;
  final WasiSockContainsFdHandler? containsFd;
}

final class WasiSockAcceptResult {
  const WasiSockAcceptResult.accepted(this.acceptedFd) : errno = 0;

  const WasiSockAcceptResult.error(this.errno) : acceptedFd = null;

  final int errno;
  final int? acceptedFd;
}

final class WasiSockRecvResult {
  const WasiSockRecvResult.received(this.data, {this.flags = 0}) : errno = 0;

  const WasiSockRecvResult.error(this.errno) : data = null, flags = 0;

  final int errno;
  final Uint8List? data;
  final int flags;
}

final class WasiSockSendResult {
  const WasiSockSendResult.sent(this.bytesWritten) : errno = 0;

  const WasiSockSendResult.error(this.errno) : bytesWritten = 0;

  final int errno;
  final int bytesWritten;
}
