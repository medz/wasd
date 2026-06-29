import 'dart:typed_data';

import 'constants.dart';
import 'vfs.dart';

typedef _OpenFilePreflight = ({int errno, Preview1OpenFile? opened});

_OpenFilePreflight _openFileForDescriptor({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required int rights,
}) {
  final descriptorKind = vfs.descriptorKindForFd(fd);
  if (descriptorKind == null) {
    return (errno: errnoBadf, opened: null);
  }
  if (!vfs.descriptorHasRight(fd, rights)) {
    return (errno: errnoNotcapable, opened: null);
  }
  final opened = vfs.openFileForFd(fd);
  if (opened == null || vfs.isOpenDirectoryFd(fd)) {
    return (errno: errnoBadf, opened: null);
  }
  return (errno: errnoSuccess, opened: opened);
}

void _setUint64(ByteData data, int offset, int value) {
  if (value >= 0 && value <= _u32Max) {
    data.setUint32(offset, value, Endian.little);
    data.setUint32(offset + 4, 0, Endian.little);
    return;
  }
  final normalized = BigInt.from(value).toUnsigned(64);
  data.setUint32(offset, (normalized & _u32Mask).toInt(), Endian.little);
  data.setUint32(
    offset + 4,
    ((normalized >> 32) & _u32Mask).toInt(),
    Endian.little,
  );
}

const int _u32Max = 0xffffffff;
final BigInt _u32Mask = BigInt.from(_u32Max);

int _filetypeForDescriptor(
  Preview1VirtualFileSystem vfs,
  int fd,
  Preview1DescriptorKind descriptorKind,
) {
  return switch (descriptorKind) {
    Preview1DescriptorKind.file => filetypeRegularFile,
    Preview1DescriptorKind.socket => vfs.socketForFd(fd)?.fileType ?? -1,
    Preview1DescriptorKind.openDirectory ||
    Preview1DescriptorKind.preopenDirectory => filetypeDirectory,
    Preview1DescriptorKind.stdin ||
    Preview1DescriptorKind.stdout ||
    Preview1DescriptorKind.stderr => filetypeCharacterDevice,
  };
}

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

int preview1FdFilestatGet({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required Uint8List? bytes,
  required ByteData? data,
  required int filestatPtr,
}) {
  final descriptorKind = vfs.descriptorKindForFd(fd);
  if (descriptorKind == null) {
    return errnoBadf;
  }
  if (!vfs.descriptorHasRight(fd, rightFdFilestatGet)) {
    return errnoNotcapable;
  }
  if (bytes == null || data == null) {
    return errnoInval;
  }
  if (filestatPtr < 0 || filestatPtr + filestatSize > bytes.length) {
    return errnoInval;
  }

  final filetype = _filetypeForDescriptor(vfs, fd, descriptorKind);
  if (filetype < 0) {
    return errnoBadf;
  }

  bytes.fillRange(filestatPtr, filestatPtr + filestatSize, 0);
  bytes[filestatPtr + filestatFiletypeOffset] = filetype;
  final opened = descriptorKind == Preview1DescriptorKind.file
      ? vfs.openFileForFd(fd)
      : null;
  if (opened != null) {
    _setUint64(data, filestatPtr + filestatSizeOffset, opened.length);
  }
  final metadata = vfs.metadataForFd(fd);
  if (metadata != null) {
    writeFilestatMetadata(
      data: data,
      filestatPtr: filestatPtr,
      metadata: metadata,
    );
  }
  return errnoSuccess;
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

int preview1FdPread({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required Uint8List? bytes,
  required ByteData? data,
  required int iovs,
  required int iovsLen,
  required int offset,
  required int nreadPtr,
}) {
  final preflight = _openFileForDescriptor(
    vfs: vfs,
    fd: fd,
    rights: rightFdRead | rightFdSeek,
  );
  if (preflight.errno != errnoSuccess) {
    return preflight.errno;
  }
  if (bytes == null || data == null) {
    return errnoInval;
  }

  return readOpenFileIntoIov(
    opened: preflight.opened!,
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
    nreadPtr: nreadPtr,
    fileOffset: offset,
  );
}

int preview1FdPwrite({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required Uint8List? bytes,
  required ByteData? data,
  required int iovs,
  required int iovsLen,
  required int offset,
  required int nwrittenPtr,
}) {
  final preflight = _openFileForDescriptor(
    vfs: vfs,
    fd: fd,
    rights: rightFdWrite | rightFdSeek,
  );
  if (preflight.errno != errnoSuccess) {
    return preflight.errno;
  }
  if (bytes == null || data == null) {
    return errnoInval;
  }

  return writeOpenFileFromIov(
    opened: preflight.opened!,
    bytes: bytes,
    data: data,
    iovs: iovs,
    iovsLen: iovsLen,
    nwrittenPtr: nwrittenPtr,
    fileOffset: offset,
  );
}

int preview1FdSeek({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required int offset,
  required int whence,
  required Uint8List? bytes,
  required ByteData? data,
  required int newOffsetPtr,
}) {
  final preflight = _openFileForDescriptor(
    vfs: vfs,
    fd: fd,
    rights: rightFdSeek,
  );
  if (preflight.errno != errnoSuccess) {
    return preflight.errno;
  }
  if (bytes == null || data == null) {
    return errnoInval;
  }

  if (newOffsetPtr < 0 || newOffsetPtr + 8 > bytes.length) {
    return errnoInval;
  }

  final opened = preflight.opened!;
  final base = switch (whence) {
    0 => 0,
    1 => opened.offset,
    2 => opened.length,
    _ => -1,
  };
  if (base < 0) {
    return errnoInval;
  }
  final next = base + offset;
  if (next < 0) {
    return errnoInval;
  }
  opened.offset = next;
  _setUint64(data, newOffsetPtr, next);
  return errnoSuccess;
}

int preview1FdTell({
  required Preview1VirtualFileSystem vfs,
  required int fd,
  required Uint8List? bytes,
  required ByteData? data,
  required int offsetPtr,
}) {
  final preflight = _openFileForDescriptor(
    vfs: vfs,
    fd: fd,
    rights: rightFdTell,
  );
  if (preflight.errno != errnoSuccess) {
    return preflight.errno;
  }
  if (bytes == null || data == null) {
    return errnoInval;
  }

  if (offsetPtr < 0 || offsetPtr + 8 > bytes.length) {
    return errnoInval;
  }

  _setUint64(data, offsetPtr, preflight.opened!.offset);
  return errnoSuccess;
}
