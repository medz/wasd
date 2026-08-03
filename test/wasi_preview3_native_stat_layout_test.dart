@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:wasd/src/wasi/preview3/native/stat_layout.dart';

void main() {
  group('Preview3 native stat layouts', () {
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
          WASIPreview3NativeStatLayout.forAbi(abi),
          supported.contains(abi) ? isNotNull : isNull,
          reason: '$abi',
        );
      }
    });

    test('selects Darwin x64 64-bit-inode stat symbols', () {
      expect(
        WASIPreview3NativeStatLayout.lstatSymbolForAbi(Abi.macosX64),
        r'lstat$INODE64',
      );
      expect(
        WASIPreview3NativeStatLayout.lstatSymbolForAbi(Abi.linuxX64),
        'lstat',
      );
      expect(
        WASIPreview3NativeStatLayout.fstatSymbolForAbi(Abi.macosX64),
        r'fstat$INODE64',
      );
      expect(
        WASIPreview3NativeStatLayout.fstatSymbolForAbi(Abi.linuxX64),
        'fstat',
      );
    });

    test('decodes Linux arm64 32-bit nlink_t and nanosecond timestamps', () {
      final bytes = Uint8List(120);
      ByteData.sublistView(bytes)
        ..setUint64(0, 0x01020304, Endian.little)
        ..setUint64(8, 0x0102030405060708, Endian.little)
        ..setUint32(20, 0x12345678, Endian.little)
        ..setInt64(48, 321, Endian.little)
        ..setInt64(72, 11, Endian.little)
        ..setInt64(80, 12, Endian.little)
        ..setInt64(88, 21, Endian.little)
        ..setInt64(96, 22, Endian.little)
        ..setInt64(104, 31, Endian.little)
        ..setInt64(112, 32, Endian.little);

      final metadata = WASIPreview3NativeStatLayout.forAbi(
        Abi.linuxArm64,
      )!.read(bytes)!;
      expect(metadata.objectIdentity, '16909060:72623859790382856');
      expect(metadata.linkCount, BigInt.from(0x12345678));
      expect(metadata.size, BigInt.from(321));
      expect(metadata.accessTimeNanos, BigInt.from(11000000012));
      expect(metadata.modificationTimeNanos, BigInt.from(21000000022));
      expect(metadata.statusChangeTimeNanos, BigInt.from(31000000032));
    });

    test('decodes the current host lstat snapshot', () {
      final layout = WASIPreview3NativeStatLayout.forAbi(Abi.current());
      if (layout == null || Platform.isWindows) {
        return;
      }
      final directory = Directory.systemTemp.createTempSync('wasd-p3-stat-');
      try {
        final file = File('${directory.path}/fixture.bin')
          ..writeAsBytesSync(List<int>.filled(321, 0x5a));
        final expected = file.statSync();
        final bytes = calloc<Uint8>(256);
        final path = file.path.toNativeUtf8();
        try {
          final lstat = DynamicLibrary.process()
              .lookupFunction<
                Int32 Function(Pointer<Utf8>, Pointer<Void>),
                int Function(Pointer<Utf8>, Pointer<Void>)
              >(WASIPreview3NativeStatLayout.lstatSymbolForAbi(Abi.current()));
          expect(lstat(path, bytes.cast<Void>()), 0);
          final metadata = layout.read(bytes.asTypedList(256))!;
          expect(metadata.size, BigInt.from(expected.size));
          expect(metadata.linkCount, isNotNull);
          expect(metadata.objectIdentity, isNotNull);
          expect(metadata.accessTimeNanos, isNotNull);
          expect(metadata.modificationTimeNanos, isNotNull);
          expect(metadata.statusChangeTimeNanos, isNotNull);
        } finally {
          malloc.free(path);
          calloc.free(bytes);
        }
      } finally {
        directory.deleteSync(recursive: true);
      }
    });

    test('rejects truncated snapshots', () {
      expect(
        WASIPreview3NativeStatLayout.forAbi(
          Abi.linuxArm64,
        )!.read(Uint8List(119)),
        isNull,
      );
    });

    test('preserves an unlinked descriptor link count of zero', () {
      final metadata = WASIPreview3NativeStatLayout.forAbi(
        Abi.linuxArm64,
      )!.read(Uint8List(120))!;

      expect(metadata.linkCount, BigInt.zero);
    });
  });
}
