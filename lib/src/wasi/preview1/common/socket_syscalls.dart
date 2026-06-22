import 'dart:typed_data';

import 'constants.dart';
import 'vfs.dart';

int preview1SockAccept({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required int flags,
  required int acceptedFdPtr,
  required Uint8List? bytes,
  required ByteData? data,
}) {
  if ((flags & ~fdflagKnownMask) != 0) {
    return errnoInval;
  }
  final socket = vfs.socketForFd(fd);
  if (socket == null) {
    return _errnoForMissingSocket(vfs, fd);
  }
  if ((flags & ~socketFdflagKnownMask) != 0) {
    return errnoNotsup;
  }
  final right = _checkDescriptorRight(vfs, fd, rightSockAccept);
  if (right != errnoSuccess) {
    return right;
  }
  if (!socket.isStream) {
    return errnoNotsup;
  }
  if (!socket.canAccept) {
    return errnoNotsup;
  }
  if (bytes == null || data == null) {
    return errnoInval;
  }
  if (acceptedFdPtr < 0 || acceptedFdPtr + 4 > bytes.length) {
    return errnoInval;
  }

  final acceptedFd = vfs.acceptSocket(fd: fd, descriptorFlags: flags);
  if (acceptedFd < 0) {
    return errnoAgain;
  }
  data.setUint32(acceptedFdPtr, acceptedFd, Endian.little);
  return errnoSuccess;
}

int preview1SockRecv({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required int iovs,
  required int iovsLen,
  required int flags,
  required int nreadPtr,
  required int roFlagsPtr,
  required Uint8List? bytes,
  required ByteData? data,
}) {
  if ((flags & ~riflagKnownMask) != 0) {
    return errnoInval;
  }
  final socket = vfs.socketForFd(fd);
  if (socket == null) {
    return _errnoForMissingSocket(vfs, fd);
  }
  final right = _checkDescriptorRight(vfs, fd, rightFdRead);
  if (right != errnoSuccess) {
    return right;
  }
  if (bytes == null || data == null) {
    return errnoInval;
  }
  return readSocketIntoIov(
    socket: socket,
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
    flags: flags,
    nreadPtr: nreadPtr,
    roFlagsPtr: roFlagsPtr,
  );
}

int preview1SockSend({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required int iovs,
  required int iovsLen,
  required int flags,
  required int nwrittenPtr,
  required Uint8List? bytes,
  required ByteData? data,
}) {
  if (flags != 0) {
    return errnoInval;
  }
  final socket = vfs.socketForFd(fd);
  if (socket == null) {
    return _errnoForMissingSocket(vfs, fd);
  }
  final right = _checkDescriptorRight(vfs, fd, rightFdWrite);
  if (right != errnoSuccess) {
    return right;
  }
  if (bytes == null || data == null) {
    return errnoInval;
  }
  return writeSocketFromIov(
    socket: socket,
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
    nwrittenPtr: nwrittenPtr,
  );
}

int preview1SockShutdown({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required int how,
}) {
  if (how == 0 || (how & ~sdflagKnownMask) != 0) {
    return errnoInval;
  }
  final socket = vfs.socketForFd(fd);
  if (socket == null) {
    return _errnoForMissingSocket(vfs, fd);
  }
  final right = _checkDescriptorRight(vfs, fd, rightSockShutdown);
  if (right != errnoSuccess) {
    return right;
  }
  socket.shutdown(receive: (how & sdflagRd) != 0, send: (how & sdflagWr) != 0);
  return errnoSuccess;
}

bool _isOpenDescriptor(Preview1VirtualFileSystem vfs, int fd) =>
    vfs.descriptorKindForFd(fd) != null;

int _errnoForMissingSocket(Preview1VirtualFileSystem vfs, int fd) =>
    _isOpenDescriptor(vfs, fd) ? errnoNotsock : errnoBadf;

int _checkDescriptorRight(Preview1VirtualFileSystem vfs, int fd, int right) {
  if (!_isOpenDescriptor(vfs, fd)) {
    return errnoBadf;
  }
  return vfs.descriptorHasRight(fd, right) ? errnoSuccess : errnoNotcapable;
}
