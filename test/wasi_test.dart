import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';
import 'support/wasm_fixtures.dart';

final _wasiBytes = wasiStartModuleBytes();

void main() {
  group('WASI', () {
    test('constructor creates instance', () {
      final wasi = WASI();
      expect(wasi, isA<WASI>());
    });

    test('imports contains wasi_snapshot_preview1', () {
      final wasi = WASI();
      expect(wasi.imports.containsKey('wasi_snapshot_preview1'), isTrue);
    });

    test('imports has proc_exit function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('proc_exit'), isTrue);
      expect(preview1['proc_exit'], isA<FunctionImportExportValue>());
    });

    test('imports has fd_write function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('fd_write'), isTrue);
      expect(preview1['fd_write'], isA<FunctionImportExportValue>());
    });

    test('imports has fd_read function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('fd_read'), isTrue);
      expect(preview1['fd_read'], isA<FunctionImportExportValue>());
    });

    test('imports has fd_close function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('fd_close'), isTrue);
      expect(preview1['fd_close'], isA<FunctionImportExportValue>());
    });

    test('imports has args functions', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('args_sizes_get'), isTrue);
      expect(preview1.containsKey('args_get'), isTrue);
      expect(preview1['args_sizes_get'], isA<FunctionImportExportValue>());
      expect(preview1['args_get'], isA<FunctionImportExportValue>());
    });

    test('imports has environ functions', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('environ_sizes_get'), isTrue);
      expect(preview1.containsKey('environ_get'), isTrue);
      expect(preview1['environ_sizes_get'], isA<FunctionImportExportValue>());
      expect(preview1['environ_get'], isA<FunctionImportExportValue>());
    });

    test('imports has random_get function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('random_get'), isTrue);
      expect(preview1['random_get'], isA<FunctionImportExportValue>());
    });

    test('imports has fd_fdstat_get function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('fd_fdstat_get'), isTrue);
      expect(preview1['fd_fdstat_get'], isA<FunctionImportExportValue>());
    });

    test('imports has clock_time_get function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('clock_time_get'), isTrue);
      expect(preview1['clock_time_get'], isA<FunctionImportExportValue>());
    });

    test('imports exposes preview1 compatibility functions', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('sched_yield'), isTrue);
      expect(preview1.containsKey('fd_prestat_get'), isTrue);
      expect(preview1.containsKey('fd_prestat_dir_name'), isTrue);
      expect(preview1.containsKey('path_open'), isTrue);
      expect(preview1.containsKey('path_filestat_get'), isTrue);
      expect(preview1.containsKey('poll_oneoff'), isTrue);
      expect(preview1.containsKey('path_unlink_file'), isTrue);
      expect(preview1.containsKey('fd_seek'), isTrue);
      expect(preview1.containsKey('proc_raise'), isTrue);
      expect(preview1['sched_yield'], isA<FunctionImportExportValue>());
      expect(preview1['path_open'], isA<FunctionImportExportValue>());
      expect(preview1['fd_seek'], isA<FunctionImportExportValue>());
    });

    group('with instantiated module', () {
      late WASI wasi;
      late Instance instance;

      setUp(() async {
        wasi = WASI(
          args: ['app.wasm'],
          env: {'FOO': 'bar'},
          preopens: {'/sandbox': '/tmp'},
        );
        final result = await WebAssembly.instantiate(
          _wasiBytes.buffer,
          wasi.imports,
        );
        instance = result.instance;
      });

      test('instance exports _start and memory', () {
        expect(instance.exports.containsKey('_start'), isTrue);
        expect(instance.exports.containsKey('memory'), isTrue);
      });

      test('start returns exit code 42', () {
        final code = wasi.start(instance);
        expect(code, 42);
      });

      test(
        'start rethrows on proc_exit when returnOnExit is false',
        () {
          final nonReturningWasi = WASI(returnOnExit: false);
          expect(() => nonReturningWasi.start(instance), throwsA(isA<Error>()));
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; proc_exit may terminate process.'
            : false,
      );

      test('fd_write writes bytes to stdout and returns number of bytes', () {
        final preview1 = wasi.imports['wasi_snapshot_preview1']!;
        final fdWrite = preview1['fd_write'];
        expect(fdWrite, isA<FunctionImportExportValue>());

        final memory =
            (instance.exports['memory'] as MemoryImportExportValue).ref;
        wasi.finalizeBindings(instance, memory: memory);

        final bytes = Uint8List.view(memory.buffer);
        final data = ByteData.view(memory.buffer);
        const text = 'hello wasi';
        final textBytes = utf8.encode(text);
        const iovPtr = 128;
        const bufferPtr = 256;
        const writtenPtr = 1024;

        bytes.setAll(bufferPtr, textBytes);
        data.setUint32(iovPtr, bufferPtr, Endian.little);
        data.setUint32(iovPtr + 4, textBytes.length, Endian.little);

        final result = (fdWrite as FunctionImportExportValue).ref([
          1,
          iovPtr,
          1,
          writtenPtr,
        ]);
        expect(result, 0);
        final reported = data.getUint32(writtenPtr, Endian.little);
        expect(reported, textBytes.length);
      });

      test(
        'args_sizes_get and args_get write argv pointers and data',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final argsSizesGet =
              preview1['args_sizes_get'] as FunctionImportExportValue;
          final argsGet = preview1['args_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const argcPtr = 1200;
          const argvBufSizePtr = 1204;
          const argvPtr = 1216;
          const argvBufPtr = 1232;

          expect(argsSizesGet.ref([argcPtr, argvBufSizePtr]), 0);
          expect(data.getUint32(argcPtr, Endian.little), 1);
          expect(data.getUint32(argvBufSizePtr, Endian.little), 9);

          expect(argsGet.ref([argvPtr, argvBufPtr]), 0);
          final firstArgPtr = data.getUint32(argvPtr, Endian.little);
          expect(firstArgPtr, argvBufPtr);
          expect(
            utf8.decode(bytes.sublist(firstArgPtr, firstArgPtr + 8)),
            'app.wasm',
          );
          expect(bytes[firstArgPtr + 8], 0);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; args behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'args_get returns inval for out-of-bounds argv buffer',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final argsGet = preview1['args_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          const argvPtr = 1000;
          final argvBufPtr = bytes.length - 4;

          final result = argsGet.ref([argvPtr, argvBufPtr]);
          expect(result, 28);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; args behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'environ_sizes_get and environ_get write environment pointers and data',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final environSizesGet =
              preview1['environ_sizes_get'] as FunctionImportExportValue;
          final environGet =
              preview1['environ_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const environCountPtr = 1240;
          const environBufSizePtr = 1244;
          const environPtr = 1260;
          const environBufPtr = 1280;

          expect(environSizesGet.ref([environCountPtr, environBufSizePtr]), 0);
          expect(data.getUint32(environCountPtr, Endian.little), 1);
          expect(data.getUint32(environBufSizePtr, Endian.little), 8);

          expect(environGet.ref([environPtr, environBufPtr]), 0);
          final firstEnvPtr = data.getUint32(environPtr, Endian.little);
          expect(firstEnvPtr, environBufPtr);
          expect(
            utf8.decode(bytes.sublist(firstEnvPtr, firstEnvPtr + 7)),
            'FOO=bar',
          );
          expect(bytes[firstEnvPtr + 7], 0);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; environ behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'random_get fills memory region',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final randomGet = preview1['random_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          const randomPtr = 1400;
          const randomLen = 32;
          bytes.fillRange(randomPtr, randomPtr + randomLen, 0xaa);

          expect(randomGet.ref([randomPtr, randomLen]), 0);
          final after = bytes.sublist(randomPtr, randomPtr + randomLen);
          expect(after.any((value) => value != 0xaa), isTrue);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; random behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'fd_write returns badf for unknown descriptors',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final result = fdWrite.ref([99, 0, 0, 0]);
          expect(result, 8);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; fd_write behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'fd_write returns inval for out-of-bounds iovec',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 128;
          data.setUint32(iovPtr, bytes.length - 2, Endian.little);
          data.setUint32(iovPtr + 4, 8, Endian.little);

          final result = fdWrite.ref([1, iovPtr, 1, 0]);
          expect(result, 28);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; fd_write behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'fd_read reports EOF with zero bytes on stdin',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdRead = preview1['fd_read'];
          expect(fdRead, isA<FunctionImportExportValue>());

          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const iovPtr = 128;
          const bufferPtr = 512;
          const nreadPtr = 1028;

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 8, Endian.little);
          data.setUint32(nreadPtr, 999, Endian.little);

          final result = (fdRead as FunctionImportExportValue).ref([
            0,
            iovPtr,
            1,
            nreadPtr,
          ]);
          expect(result, 0);
          expect(data.getUint32(nreadPtr, Endian.little), 0);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; fd_read behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'fd_read returns badf for unknown descriptors',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdRead = preview1['fd_read'] as FunctionImportExportValue;
          final result = fdRead.ref([99, 0, 0, 0]);
          expect(result, 8);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; fd_read behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'fd_close returns badf for unknown descriptors',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdClose = preview1['fd_close'];
          expect(fdClose, isA<FunctionImportExportValue>());

          final result = (fdClose as FunctionImportExportValue).ref([42]);
          expect(result, 8);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; fd_close behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'fd_fdstat_get writes a character-device descriptor for stdio',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          const fdstatPtr = 1500;
          bytes.fillRange(fdstatPtr, fdstatPtr + 24, 0xff);

          final result = fdFdstatGet.ref([1, fdstatPtr]);
          expect(result, 0);
          expect(bytes[fdstatPtr], 2);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; fd_fdstat_get behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'fd_fdstat_get returns badf for unknown descriptors',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final result = fdFdstatGet.ref([42, 0]);
          expect(result, 8);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; fd_fdstat_get behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'clock_time_get writes a non-zero timestamp',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final clockTimeGet =
              preview1['clock_time_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const timePtr = 1600;
          data.setUint64(timePtr, 0, Endian.little);

          final result = clockTimeGet.ref([0, 0, timePtr]);
          expect(result, 0);
          expect(data.getUint64(timePtr, Endian.little), greaterThan(0));
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; clock_time_get behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'clock_time_get returns inval for out-of-bounds pointer',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final clockTimeGet =
              preview1['clock_time_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final result = clockTimeGet.ref([0, 0, bytes.length - 4]);
          expect(result, 28);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; clock_time_get behavior is delegated to node:wasi.'
            : false,
      );

      test('finalizeBindings accepts explicit memory and reuses it later', () {
        final memoryValue = instance.exports['memory'];
        expect(memoryValue, isA<MemoryImportExportValue>());
        final memory = (memoryValue as MemoryImportExportValue).ref;

        final memoryAwareWasi = WASI();
        memoryAwareWasi.finalizeBindings(instance, memory: memory);
        expect(
          () => memoryAwareWasi.finalizeBindings(instance),
          returnsNormally,
        );
      });

      test(
        'custom stdio descriptors are honored by fd_read/fd_write/fd_close',
        () async {
          final customWasi = WASI(stdin: 10, stdout: 11, stderr: 12);
          final customResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            customWasi.imports,
          );
          final customInstance = customResult.instance;
          final preview1 = customWasi.imports['wasi_snapshot_preview1']!;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final fdRead = preview1['fd_read'] as FunctionImportExportValue;
          final fdClose = preview1['fd_close'] as FunctionImportExportValue;
          final memory =
              (customInstance.exports['memory'] as MemoryImportExportValue).ref;
          customWasi.finalizeBindings(customInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const text = 'ok';
          final textBytes = utf8.encode(text);
          const iovPtr = 1900;
          const bufferPtr = 1910;
          const writtenPtr = 1920;
          const nreadPtr = 1930;

          bytes.setAll(bufferPtr, textBytes);
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, textBytes.length, Endian.little);

          expect(fdWrite.ref([11, iovPtr, 1, writtenPtr]), 0);
          expect(fdRead.ref([10, iovPtr, 1, nreadPtr]), 0);
          expect(fdClose.ref([11]), 0);
          expect(fdClose.ref([12]), 0);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; descriptor behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'unsupported syscalls return nosys',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final schedYield =
              preview1['sched_yield'] as FunctionImportExportValue;
          final pathUnlinkFile =
              preview1['path_unlink_file'] as FunctionImportExportValue;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final procRaise = preview1['proc_raise'] as FunctionImportExportValue;

          expect(schedYield.ref(const []), 52);
          expect(pathUnlinkFile.ref([3, 0, 0]), 52);
          expect(pollOneoff.ref([0, 0, 0, 0]), 52);
          expect(procRaise.ref([15]), 52);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; unsupported syscall behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'path_open opens virtual file and fd_seek updates file offset',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/doom1.wad': Uint8List.fromList([1, 2, 3, 4]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final relativePath = utf8.encode('doom1.wad');
          const pathPtr = 2000;
          const openedFdPtr = 2020;
          const newOffsetPtr = 2032;

          bytes.setAll(pathPtr, relativePath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              relativePath.length,
              0,
              0,
              0,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final openedFd = data.getUint32(openedFdPtr, Endian.little);
          expect(openedFd, greaterThanOrEqualTo(64));

          expect(fdSeek.ref([openedFd, 2, 0, newOffsetPtr]), 0);
          expect(data.getUint32(newOffsetPtr, Endian.little), 2);
          expect(data.getUint32(newOffsetPtr + 4, Endian.little), 0);
          expect(fdSeek.ref([1, 0, 0, newOffsetPtr]), 8);
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; path_open/fd_seek behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'path_filestat_get reports file, directory, and missing paths',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/doom1.wad': Uint8List.fromList([1, 2, 3, 4]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathFilestatGet =
              preview1['path_filestat_get'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const pathPtr = 2064;
          const filestatPtr = 2100;

          final filePath = utf8.encode('doom1.wad');
          bytes.setAll(pathPtr, filePath);
          expect(
            pathFilestatGet.ref([3, 0, pathPtr, filePath.length, filestatPtr]),
            0,
          );
          expect(bytes[filestatPtr + 16], 4);
          expect(data.getUint32(filestatPtr + 32, Endian.little), 4);
          expect(data.getUint32(filestatPtr + 36, Endian.little), 0);

          final dirPath = utf8.encode('.');
          bytes.setAll(pathPtr, dirPath);
          expect(
            pathFilestatGet.ref([3, 0, pathPtr, dirPath.length, filestatPtr]),
            0,
          );
          expect(bytes[filestatPtr + 16], 3);

          final missingPath = utf8.encode('missing.wad');
          bytes.setAll(pathPtr, missingPath);
          expect(
            pathFilestatGet.ref([
              3,
              0,
              pathPtr,
              missingPath.length,
              filestatPtr,
            ]),
            44,
          );
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; path_filestat_get behavior is delegated to node:wasi.'
            : false,
      );

      test(
        'fd_prestat_get and fd_prestat_dir_name expose configured preopen',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdPrestatGet =
              preview1['fd_prestat_get'] as FunctionImportExportValue;
          final fdPrestatDirName =
              preview1['fd_prestat_dir_name'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const prestatPtr = 1800;
          const pathPtr = 1816;

          expect(fdPrestatGet.ref([3, prestatPtr]), 0);
          expect(bytes[prestatPtr], 0);
          final pathLen = data.getUint32(prestatPtr + 4, Endian.little);
          expect(pathLen, 8);

          expect(fdPrestatDirName.ref([3, pathPtr, pathLen]), 0);
          expect(
            utf8.decode(bytes.sublist(pathPtr, pathPtr + pathLen)),
            '/sandbox',
          );
        },
        skip: const bool.fromEnvironment('dart.library.js_interop')
            ? 'Skipping on JS runtimes; prestat behavior is delegated to node:wasi.'
            : false,
      );
    });
  });
}
