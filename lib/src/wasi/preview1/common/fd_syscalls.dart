import 'constants.dart';
import 'vfs.dart';

int preview1FdAllocate({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required int offset,
  required int length,
}) {
  final descriptorKind = vfs.descriptorKindForFd(fd);
  if (descriptorKind == null) {
    return errnoBadf;
  }
  if (!vfs.descriptorHasRight(fd, rightFdAllocate)) {
    return errnoNotcapable;
  }
  final opened = vfs.openFileForFd(fd);
  if (opened == null || vfs.isOpenDirectoryFd(fd)) {
    return errnoBadf;
  }
  if (offset < 0 || length < 0 || offset + length < offset) {
    return errnoInval;
  }

  opened.allocate(offset, length);
  return errnoSuccess;
}

int preview1FdFdstatSetFlags({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required int flags,
}) {
  if ((flags & ~fdflagKnownMask) != 0) {
    return errnoInval;
  }
  final socket = vfs.socketForFd(fd);
  if (socket != null && (flags & ~socketFdflagKnownMask) != 0) {
    return errnoNotsup;
  }
  if (vfs.descriptorKindForFd(fd) == null) {
    return errnoBadf;
  }
  if (!vfs.descriptorHasRight(fd, rightFdFdstatSetFlags)) {
    return errnoNotcapable;
  }
  return vfs.setDescriptorFlags(fd, flags) ? errnoSuccess : errnoBadf;
}

int preview1FdFilestatSetSize({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required int size,
}) {
  final descriptorKind = vfs.descriptorKindForFd(fd);
  if (descriptorKind == null) {
    return errnoBadf;
  }
  if (!vfs.descriptorHasRight(fd, rightFdFilestatSetSize)) {
    return errnoNotcapable;
  }
  final opened = vfs.openFileForFd(fd);
  if (opened == null || vfs.isOpenDirectoryFd(fd)) {
    return errnoBadf;
  }
  if (size < 0) {
    return errnoInval;
  }

  opened.setLength(size);
  return errnoSuccess;
}
