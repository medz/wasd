import 'dart:ffi' as ffi;
import 'dart:typed_data';

import '../filesystem.dart';

/// A verified 64-bit POSIX `struct stat` layout used by the native host.
final class WASIPreview3NativeStatLayout {
  const WASIPreview3NativeStatLayout._({
    required int minimumByteLength,
    required int deviceOffset,
    required _UnsignedWidth deviceWidth,
    required int inodeOffset,
    required _UnsignedWidth inodeWidth,
    required int linkCountOffset,
    required _UnsignedWidth linkCountWidth,
    required int sizeOffset,
    required int accessTimeOffset,
    required int modificationTimeOffset,
    required int statusChangeTimeOffset,
  }) : _minimumByteLength = minimumByteLength,
       _deviceOffset = deviceOffset,
       _deviceWidth = deviceWidth,
       _inodeOffset = inodeOffset,
       _inodeWidth = inodeWidth,
       _linkCountOffset = linkCountOffset,
       _linkCountWidth = linkCountWidth,
       _sizeOffset = sizeOffset,
       _accessTimeOffset = accessTimeOffset,
       _modificationTimeOffset = modificationTimeOffset,
       _statusChangeTimeOffset = statusChangeTimeOffset;

  final int _minimumByteLength;
  final int _deviceOffset;
  final _UnsignedWidth _deviceWidth;
  final int _inodeOffset;
  final _UnsignedWidth _inodeWidth;
  final int _linkCountOffset;
  final _UnsignedWidth _linkCountWidth;
  final int _sizeOffset;
  final int _accessTimeOffset;
  final int _modificationTimeOffset;
  final int _statusChangeTimeOffset;

  /// Returns the verified layout for [abi], or null for unknown and 32-bit ABIs.
  static WASIPreview3NativeStatLayout? forAbi(ffi.Abi abi) {
    if (abi == ffi.Abi.macosX64 ||
        abi == ffi.Abi.macosArm64 ||
        abi == ffi.Abi.iosX64 ||
        abi == ffi.Abi.iosArm64) {
      return _darwin64;
    }
    if (abi == ffi.Abi.linuxX64 || abi == ffi.Abi.androidX64) {
      return _linuxX64;
    }
    if (abi == ffi.Abi.linuxArm64 || abi == ffi.Abi.androidArm64) {
      return _linuxArm64;
    }
    return null;
  }

  /// Returns the `lstat` symbol whose output matches [forAbi].
  static String lstatSymbolForAbi(ffi.Abi abi) =>
      abi == ffi.Abi.macosX64 ? r'lstat$INODE64' : 'lstat';

  /// Returns the `fstat` symbol whose output matches [forAbi].
  static String fstatSymbolForAbi(ffi.Abi abi) =>
      abi == ffi.Abi.macosX64 ? r'fstat$INODE64' : 'fstat';

  /// Decodes one native stat snapshot, or null when [bytes] is truncated.
  WASIPreview3FilesystemMetadata? read(Uint8List bytes) {
    if (bytes.lengthInBytes < _minimumByteLength) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    final device = _readUnsigned(data, _deviceOffset, _deviceWidth);
    final inode = _readUnsigned(data, _inodeOffset, _inodeWidth);
    final linkCount = _readUnsigned(data, _linkCountOffset, _linkCountWidth);
    final size = data.getInt64(_sizeOffset, Endian.little);
    return WASIPreview3FilesystemMetadata(
      linkCount: linkCount,
      size: size < 0 ? null : BigInt.from(size),
      objectIdentity: '$device:$inode',
      accessTimeNanos: _readTimespecNanos(data, _accessTimeOffset),
      modificationTimeNanos: _readTimespecNanos(data, _modificationTimeOffset),
      statusChangeTimeNanos: _readTimespecNanos(data, _statusChangeTimeOffset),
    );
  }
}

enum _UnsignedWidth { uint16, uint32, uint64 }

const WASIPreview3NativeStatLayout _darwin64 = WASIPreview3NativeStatLayout._(
  minimumByteLength: 104,
  deviceOffset: 0,
  deviceWidth: _UnsignedWidth.uint32,
  inodeOffset: 8,
  inodeWidth: _UnsignedWidth.uint64,
  linkCountOffset: 6,
  linkCountWidth: _UnsignedWidth.uint16,
  sizeOffset: 96,
  accessTimeOffset: 32,
  modificationTimeOffset: 48,
  statusChangeTimeOffset: 64,
);

const WASIPreview3NativeStatLayout _linuxX64 = WASIPreview3NativeStatLayout._(
  minimumByteLength: 120,
  deviceOffset: 0,
  deviceWidth: _UnsignedWidth.uint64,
  inodeOffset: 8,
  inodeWidth: _UnsignedWidth.uint64,
  linkCountOffset: 16,
  linkCountWidth: _UnsignedWidth.uint64,
  sizeOffset: 48,
  accessTimeOffset: 72,
  modificationTimeOffset: 88,
  statusChangeTimeOffset: 104,
);

// glibc and bionic use a 32-bit nlink_t in the generic aarch64 LP64 layout.
const WASIPreview3NativeStatLayout _linuxArm64 = WASIPreview3NativeStatLayout._(
  minimumByteLength: 120,
  deviceOffset: 0,
  deviceWidth: _UnsignedWidth.uint64,
  inodeOffset: 8,
  inodeWidth: _UnsignedWidth.uint64,
  linkCountOffset: 20,
  linkCountWidth: _UnsignedWidth.uint32,
  sizeOffset: 48,
  accessTimeOffset: 72,
  modificationTimeOffset: 88,
  statusChangeTimeOffset: 104,
);

BigInt _readUnsigned(
  ByteData data,
  int offset,
  _UnsignedWidth width,
) => switch (width) {
  _UnsignedWidth.uint16 => BigInt.from(data.getUint16(offset, Endian.little)),
  _UnsignedWidth.uint32 => BigInt.from(data.getUint32(offset, Endian.little)),
  _UnsignedWidth.uint64 =>
    BigInt.from(data.getUint64(offset, Endian.little)) & _u64Mask,
};

BigInt _readTimespecNanos(ByteData data, int offset) {
  final seconds = BigInt.from(data.getInt64(offset, Endian.little));
  final nanos = BigInt.from(data.getInt64(offset + 8, Endian.little));
  return seconds * _nanosPerSecond + nanos;
}

final BigInt _nanosPerSecond = BigInt.from(1000000000);
final BigInt _u64Mask = (BigInt.one << 64) - BigInt.one;
