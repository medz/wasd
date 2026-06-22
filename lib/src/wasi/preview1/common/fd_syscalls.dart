import 'constants.dart';
import 'vfs.dart';

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
