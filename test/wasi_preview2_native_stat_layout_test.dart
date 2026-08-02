@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/preview2/native/stat_layout.dart';

void main() {
  group('Preview2 native stat layouts', () {
    test('supports only verified 64-bit POSIX ABIs', () {
      const supported = <Abi>{
        Abi.androidArm64,
        Abi.androidX64,
        Abi.iosArm64,
        Abi.iosX64,
        Abi.linuxArm64,
        Abi.linuxX64,
        Abi.macosArm64,
        Abi.macosX64,
      };

      for (final abi in Abi.values) {
        expect(
          WASIPreview2NativeStatLayout.forAbi(abi),
          supported.contains(abi) ? isNotNull : isNull,
          reason: '$abi',
        );
      }
    });

    test('decodes Darwin x64 and arm64 fields', () {
      for (final abi in const <Abi>[
        Abi.macosX64,
        Abi.macosArm64,
        Abi.iosX64,
        Abi.iosArm64,
      ]) {
        _expectDecoded(
          abi: abi,
          byteLength: 104,
          deviceOffset: 0,
          deviceWidth: 4,
          inodeOffset: 8,
          linkCountOffset: 6,
          linkCountWidth: 2,
          sizeOffset: 96,
          accessTimeOffset: 32,
          modificationTimeOffset: 48,
          statusChangeTimeOffset: 64,
        );
      }
    });

    test('decodes Linux and Android x64 fields', () {
      for (final abi in const <Abi>[Abi.linuxX64, Abi.androidX64]) {
        _expectDecoded(
          abi: abi,
          byteLength: 120,
          deviceOffset: 0,
          deviceWidth: 8,
          inodeOffset: 8,
          linkCountOffset: 16,
          linkCountWidth: 8,
          sizeOffset: 48,
          accessTimeOffset: 72,
          modificationTimeOffset: 88,
          statusChangeTimeOffset: 104,
        );
      }
    });

    test('decodes the Linux arm64 glibc fields', () {
      _expectDecoded(
        abi: Abi.linuxArm64,
        byteLength: 136,
        deviceOffset: 0,
        deviceWidth: 8,
        inodeOffset: 8,
        linkCountOffset: 24,
        linkCountWidth: 8,
        sizeOffset: 56,
        accessTimeOffset: 88,
        modificationTimeOffset: 104,
        statusChangeTimeOffset: 120,
      );
    });

    test('decodes the Android arm64 bionic fields', () {
      _expectDecoded(
        abi: Abi.androidArm64,
        byteLength: 120,
        deviceOffset: 0,
        deviceWidth: 8,
        inodeOffset: 8,
        linkCountOffset: 20,
        linkCountWidth: 4,
        sizeOffset: 48,
        accessTimeOffset: 72,
        modificationTimeOffset: 88,
        statusChangeTimeOffset: 104,
      );
    });

    test('rejects truncated snapshots', () {
      final layout = WASIPreview2NativeStatLayout.forAbi(Abi.linuxArm64)!;

      expect(layout.read(Uint8List(135)), isNull);
    });

    test('clamps negative size and preserves the full u64 link count', () {
      final bytes = Uint8List(120);
      ByteData.sublistView(bytes)
        ..setUint64(0, -1, Endian.little)
        ..setUint64(8, -1, Endian.little)
        ..setUint64(16, -1, Endian.little)
        ..setInt64(48, -1, Endian.little);

      final metadata = WASIPreview2NativeStatLayout.forAbi(
        Abi.linuxX64,
      )!.read(bytes)!;

      final u64Max = (BigInt.one << 64) - BigInt.one;
      expect(metadata.objectIdentity, '$u64Max:$u64Max');
      expect(metadata.linkCount, u64Max);
      expect(metadata.size, isNull);

      ByteData.sublistView(
        bytes,
      ).setInt64(48, 0x7fffffffffffffff, Endian.little);
      final maximumSize = WASIPreview2NativeStatLayout.forAbi(
        Abi.linuxX64,
      )!.read(bytes)!.size;
      expect(maximumSize, (BigInt.one << 63) - BigInt.one);
    });
  });
}

void _expectDecoded({
  required Abi abi,
  required int byteLength,
  required int deviceOffset,
  required int deviceWidth,
  required int inodeOffset,
  required int linkCountOffset,
  required int linkCountWidth,
  required int sizeOffset,
  required int accessTimeOffset,
  required int modificationTimeOffset,
  required int statusChangeTimeOffset,
}) {
  const device = 0x01020304;
  const inode = 0x0102030405060708;
  final linkCount = linkCountWidth == 2
      ? 0x1234
      : linkCountWidth == 4
      ? 0x12345678
      : 0x1122334455667788;
  const size = 0x0102030405060708;
  final bytes = Uint8List(byteLength);
  final data = ByteData.sublistView(bytes);
  _writeUnsigned(data, deviceOffset, deviceWidth, device);
  _writeUnsigned(data, inodeOffset, 8, inode);
  _writeUnsigned(data, linkCountOffset, linkCountWidth, linkCount);
  data.setInt64(sizeOffset, size, Endian.little);
  _writeTimespec(data, accessTimeOffset, 11, 12);
  _writeTimespec(data, modificationTimeOffset, 21, 22);
  _writeTimespec(data, statusChangeTimeOffset, 31, 32);

  final metadata = WASIPreview2NativeStatLayout.forAbi(abi)!.read(bytes)!;

  expect(metadata.objectIdentity, '$device:$inode', reason: '$abi');
  expect(metadata.linkCount, BigInt.from(linkCount), reason: '$abi');
  expect(metadata.size, BigInt.from(size), reason: '$abi');
  expect(metadata.accessTimeNanos, BigInt.from(11000000012), reason: '$abi');
  expect(
    metadata.modificationTimeNanos,
    BigInt.from(21000000022),
    reason: '$abi',
  );
  expect(
    metadata.statusChangeTimeNanos,
    BigInt.from(31000000032),
    reason: '$abi',
  );
}

void _writeUnsigned(ByteData data, int offset, int width, int value) {
  switch (width) {
    case 2:
      data.setUint16(offset, value, Endian.little);
    case 4:
      data.setUint32(offset, value, Endian.little);
    case 8:
      data.setUint64(offset, value, Endian.little);
    default:
      throw ArgumentError.value(width, 'width');
  }
}

void _writeTimespec(ByteData data, int offset, int seconds, int nanoseconds) {
  data
    ..setInt64(offset, seconds, Endian.little)
    ..setInt64(offset + 8, nanoseconds, Endian.little);
}
