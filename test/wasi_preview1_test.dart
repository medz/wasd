import 'dart:convert';
import 'dart:typed_data';

import 'package:wasd/wasd.dart';
import 'package:test/test.dart';

void main() {
  group('WasiPreview1', () {
    test('auto-selects filesystem backend based on io capability', () {
      final wasi = WasiPreview1();
      if (wasi.hostIoSupported) {
        expect(wasi.usingHostIo, isTrue);
        expect(wasi.fileSystem is WasiInMemoryFileSystem, isFalse);
      } else {
        expect(wasi.usingHostIo, isFalse);
        expect(wasi.fileSystem is WasiInMemoryFileSystem, isTrue);
      }
    });

    test('can force in-memory backend even when host io is available', () {
      final wasi = WasiPreview1(preferHostIo: false);
      expect(wasi.fileSystem is WasiInMemoryFileSystem, isTrue);
      expect(wasi.usingHostIo, isFalse);
    });

    test('fd_write writes iovec bytes to stdout and sets nwritten', () {
      final stdoutBytes = <int>[];
      final wasi = WasiPreview1(
        stdoutSink: (bytes) => stdoutBytes.addAll(bytes),
      );

      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_write',
            typeIndex: 0,
          ),
        ],
        functionTypeIndices: [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._i32Const(16),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(4),
              ..._i32Const(4),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(1),
              ..._i32Const(0),
              ..._i32Const(1),
              ..._i32Const(8),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(8),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(16), Opcodes.end],
            bytes: utf8.encode('Hi!\n'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      expect(() => instance.invokeI32('run'), throwsStateError);

      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 4);
      expect(utf8.decode(stdoutBytes), 'Hi!\n');
    });

    test('args_sizes_get + args_get writes argv metadata and strings', () {
      final wasi = WasiPreview1(args: const ['hello', 'world']);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'args_sizes_get',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'args_get',
            typeIndex: 1,
          ),
        ],
        functionTypeIndices: [2],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._i32Const(4),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(64),
              ..._i32Const(128),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 2),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);

      expect(instance.invokeI32('run'), 2);

      final memory = instance.exportedMemory('memory');
      final argv0Ptr = memory.loadI32(64);
      final argv1Ptr = memory.loadI32(68);
      final arg0 = _readCString(memory, argv0Ptr);
      final arg1 = _readCString(memory, argv1Ptr);
      expect(arg0, 'hello');
      expect(arg1, 'world');
    });

    test('args_sizes_get returns zero counts for empty args', () {
      final wasi = WasiPreview1(args: const []);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final argsSizesGet =
          wasi.imports.functions[WasmImports.key(
            'wasi_snapshot_preview1',
            'args_sizes_get',
          )]!;

      expect(argsSizesGet([0, 4]), 0);
      expect(memory.loadI32(0), 0);
      expect(memory.loadI32(4), 0);
    });

    test('args_sizes_get returns EFAULT for out-of-bounds output pointers', () {
      final wasi = WasiPreview1(args: const ['x']);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final argsSizesGet =
          wasi.imports.functions[WasmImports.key(
            'wasi_snapshot_preview1',
            'args_sizes_get',
          )]!;

      expect(argsSizesGet([65535, 4]), 21);
      expect(argsSizesGet([0, 65535]), 21);
    });

    test('args_get writes contiguous UTF-8 c-strings and argv pointers', () {
      final wasi = WasiPreview1(args: const ['hé', '🚀']);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final argsGet = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'args_get')]!;

      expect(argsGet([0, 32]), 0);
      final arg0Bytes = utf8.encode('hé');
      final arg1Bytes = utf8.encode('🚀');
      final argv0Ptr = memory.loadI32(0);
      final argv1Ptr = memory.loadI32(4);
      expect(argv0Ptr, 32);
      expect(argv1Ptr, 32 + arg0Bytes.length + 1);
      expect(memory.readBytes(argv0Ptr, arg0Bytes.length), arg0Bytes);
      expect(memory.readBytes(argv1Ptr, arg1Bytes.length), arg1Bytes);
      expect(memory.loadU8(argv0Ptr + arg0Bytes.length), 0);
      expect(memory.loadU8(argv1Ptr + arg1Bytes.length), 0);
    });

    test('args_get returns EFAULT for out-of-bounds argv or argv_buf', () {
      final wasi = WasiPreview1(args: const ['x']);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final argsGet = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'args_get')]!;

      expect(argsGet([65535, 32]), 21);
      expect(argsGet([0, 65535]), 21);
    });

    test('fd_read fills memory from stdin bytes and sets nread', () {
      final wasi = WasiPreview1(stdin: const [65, 66, 67]);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_read',
            typeIndex: 0,
          ),
        ],
        functionTypeIndices: [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._i32Const(32),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(4),
              ..._i32Const(4),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._i32Const(0),
              ..._i32Const(1),
              ..._i32Const(8),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(8),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);

      expect(instance.invokeI32('run'), 3);
      final memory = instance.exportedMemory('memory');
      expect(memory.readBytes(32, 3), [65, 66, 67]);
    });

    test('proc_exit throws WasiProcExit carrying exit code', () {
      final wasi = WasiPreview1();
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], []),
          _funcType([], []),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'proc_exit',
            typeIndex: 0,
          ),
        ],
        functionTypeIndices: [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [..._i32Const(13), ..._call(0), Opcodes.end],
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      expect(
        () => instance.invoke('run'),
        throwsA(isA<WasiProcExit>().having((e) => e.exitCode, 'exitCode', 13)),
      );
    });

    test('path_open + fd_write + fd_close writes file content', () {
      final fs = WasiInMemoryFileSystem();
      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType(
            [0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7f, 0x7f],
            [0x7f],
          ),
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_write',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_open',
            typeIndex: 1,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_close',
            typeIndex: 2,
          ),
        ],
        functionTypeIndices: [3],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(9),
              ..._i32Const(1),
              ..._i64Const(64),
              ..._i64Const(0),
              ..._i32Const(0),
              ..._i32Const(0),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(4),
              ..._i32Const(128),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(8),
              ..._i32Const(2),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(4),
              ..._i32Const(1),
              ..._i32Const(12),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._call(2),
              Opcodes.drop,
              ..._i32Const(12),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(64), Opcodes.end],
            bytes: utf8.encode('zwasm.txt'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(128), Opcodes.end],
            bytes: utf8.encode('OK'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 3),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 2);
      expect(fs.readFileText('/zwasm.txt'), 'OK');
    });

    test('fd_seek + fd_tell + fd_filestat_get report offset and size', () {
      final fs = WasiInMemoryFileSystem();
      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType(
            [0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7f, 0x7f],
            [0x7f],
          ),
          _funcType([0x7f, 0x7e, 0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_open',
            typeIndex: 1,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_write',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_seek',
            typeIndex: 2,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_tell',
            typeIndex: 3,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_filestat_get',
            typeIndex: 3,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_close',
            typeIndex: 4,
          ),
        ],
        functionTypeIndices: [5],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(8),
              ..._i32Const(1),
              ..._i64Const(2097254),
              ..._i64Const(0),
              ..._i32Const(0),
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(16),
              ..._i32Const(128),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(20),
              ..._i32Const(5),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(16),
              ..._i32Const(1),
              ..._i32Const(24),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i64Const(-2),
              ..._i32Const(2),
              ..._i32Const(32),
              ..._call(2),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(40),
              ..._call(3),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(200),
              ..._call(4),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._call(5),
              Opcodes.drop,
              ..._i32Const(40),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(232),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(64), Opcodes.end],
            bytes: utf8.encode('demo.bin'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(128), Opcodes.end],
            bytes: utf8.encode('ABCDE'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 6),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 8);
      expect(fs.readFileText('/demo.bin'), 'ABCDE');
    });

    test('path_rename + path_unlink_file mutate in-memory filesystem', () {
      final fs = WasiInMemoryFileSystem();
      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType(
            [0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7f, 0x7f],
            [0x7f],
          ),
          _funcType([0x7f], [0x7f]),
          _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_open',
            typeIndex: 1,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_write',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_close',
            typeIndex: 2,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_rename',
            typeIndex: 3,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_unlink_file',
            typeIndex: 4,
          ),
        ],
        functionTypeIndices: [5],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(7),
              ..._i32Const(1),
              ..._i64Const(64),
              ..._i64Const(0),
              ..._i32Const(0),
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(16),
              ..._i32Const(160),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(20),
              ..._i32Const(1),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(16),
              ..._i32Const(1),
              ..._i32Const(24),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._call(2),
              Opcodes.drop,
              ..._i32Const(3),
              ..._i32Const(64),
              ..._i32Const(7),
              ..._i32Const(3),
              ..._i32Const(80),
              ..._i32Const(7),
              ..._call(3),
              Opcodes.drop,
              ..._i32Const(3),
              ..._i32Const(80),
              ..._i32Const(7),
              ..._call(4),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(64), Opcodes.end],
            bytes: utf8.encode('old.txt'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(80), Opcodes.end],
            bytes: utf8.encode('new.txt'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(160), Opcodes.end],
            bytes: utf8.encode('X'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 5),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 0);
      expect(fs.readFileText('/old.txt'), isNull);
      expect(fs.readFileText('/new.txt'), isNull);
    });

    test(
      'path_create_directory + path_remove_directory update directories',
      () {
        final fs = WasiInMemoryFileSystem();
        final wasi = WasiPreview1(fileSystem: fs);
        final wasm = _buildModule(
          types: [
            _funcType([0x7f, 0x7f, 0x7f], [0x7f]),
            _funcType([], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(
              module: 'wasi_snapshot_preview1',
              name: 'path_create_directory',
              typeIndex: 0,
            ),
            _ImportFunctionSpec(
              module: 'wasi_snapshot_preview1',
              name: 'path_remove_directory',
              typeIndex: 0,
            ),
          ],
          functionTypeIndices: [1],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._i32Const(3),
                ..._i32Const(64),
                ..._i32Const(3),
                ..._call(0),
                Opcodes.drop,
                ..._i32Const(3),
                ..._i32Const(64),
                ..._i32Const(3),
                ..._call(1),
                Opcodes.end,
              ],
            ),
          ],
          memoryMinPages: 1,
          dataSegments: [
            _DataSegmentSpec.active(
              memoryIndex: 0,
              offsetExpr: [..._i32Const(64), Opcodes.end],
              bytes: utf8.encode('tmp'),
            ),
          ],
          exports: const [
            _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 2),
            _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
          ],
        );

        final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
        wasi.bindInstance(instance);
        expect(instance.invokeI32('run'), 0);
        expect(fs.snapshotDirectories(), ['/']);
      },
    );

    test('fd_fdstat_get + fd_fdstat_set_flags support append mode', () {
      final fs = WasiInMemoryFileSystem();
      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType(
            [0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7f, 0x7f],
            [0x7f],
          ),
          _funcType([0x7f, 0x7e, 0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_write',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_open',
            typeIndex: 1,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_seek',
            typeIndex: 2,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_fdstat_set_flags',
            typeIndex: 3,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_fdstat_get',
            typeIndex: 3,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_close',
            typeIndex: 4,
          ),
        ],
        functionTypeIndices: [5],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(5),
              ..._i32Const(1),
              ..._i64Const(78),
              ..._i64Const(0),
              ..._i32Const(0),
              ..._i32Const(0),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(16),
              ..._i32Const(128),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(20),
              ..._i32Const(1),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(16),
              ..._i32Const(1),
              ..._i32Const(40),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(1),
              ..._call(3),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i64Const(0),
              ..._i32Const(0),
              ..._i32Const(48),
              ..._call(2),
              Opcodes.drop,
              ..._i32Const(32),
              ..._i32Const(129),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(36),
              ..._i32Const(1),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(32),
              ..._i32Const(1),
              ..._i32Const(56),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(256),
              ..._call(4),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._call(5),
              Opcodes.drop,
              ..._i32Const(258),
              ..._memInstr(Opcodes.i32Load16U),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(64), Opcodes.end],
            bytes: utf8.encode('f.txt'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(128), Opcodes.end],
            bytes: utf8.encode('AB'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 6),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 1);
      expect(fs.readFileText('/f.txt'), 'AB');
      expect(instance.exportedMemory('memory').loadU8(256), 4);
    });

    test('fd_prestat_get + fd_prestat_dir_name expose preopened root', () {
      final wasi = WasiPreview1();
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_prestat_get',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_prestat_dir_name',
            typeIndex: 1,
          ),
        ],
        functionTypeIndices: [2],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(3),
              ..._i32Const(16),
              ..._i32Const(1),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(4),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 2),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 1);
      final memory = instance.exportedMemory('memory');
      expect(memory.loadU8(0), 0);
      expect(utf8.decode(memory.readBytes(16, 1)), '/');
    });

    test('environ_sizes_get + environ_get write envp pointers and strings', () {
      final wasi = WasiPreview1(environment: const {'A': '1', 'B': 'two'});
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'environ_sizes_get',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'environ_get',
            typeIndex: 0,
          ),
        ],
        functionTypeIndices: [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._i32Const(4),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(32),
              ..._i32Const(64),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 2),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 2);
      final memory = instance.exportedMemory('memory');
      final env0 = _readCString(memory, memory.loadI32(32));
      final env1 = _readCString(memory, memory.loadI32(36));
      expect(<String>{env0, env1}, {'A=1', 'B=two'});
    });

    test('environ_sizes_get returns zero counts for empty environment', () {
      final wasi = WasiPreview1(environment: const {});
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final environSizesGet =
          wasi.imports.functions[WasmImports.key(
            'wasi_snapshot_preview1',
            'environ_sizes_get',
          )]!;

      expect(environSizesGet([0, 4]), 0);
      expect(memory.loadI32(0), 0);
      expect(memory.loadI32(4), 0);
    });

    test(
      'environ_sizes_get returns EFAULT for out-of-bounds output pointers',
      () {
        final wasi = WasiPreview1(environment: const {'A': '1'});
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final environSizesGet =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'environ_sizes_get',
            )]!;

        expect(environSizesGet([65535, 4]), 21);
        expect(environSizesGet([0, 65535]), 21);
      },
    );

    test('environ_get writes UTF-8 KEY=VALUE c-strings and pointer table', () {
      final wasi = WasiPreview1(environment: const {'A': '1', 'B': 'twø'});
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final environGet = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'environ_get')]!;

      expect(environGet([0, 64]), 0);
      final env0Ptr = memory.loadI32(0);
      final env1Ptr = memory.loadI32(4);
      final env0 = _readCString(memory, env0Ptr);
      final env1 = _readCString(memory, env1Ptr);
      expect(<String>{env0, env1}, {'A=1', 'B=twø'});
      final env0Len = utf8.encode(env0).length;
      final env1Len = utf8.encode(env1).length;
      expect(env1Ptr, env0Ptr + env0Len + 1);
      expect(memory.loadU8(env0Ptr + env0Len), 0);
      expect(memory.loadU8(env1Ptr + env1Len), 0);
    });

    test(
      'environ_get returns EFAULT for out-of-bounds environ or environ_buf',
      () {
        final wasi = WasiPreview1(environment: const {'A': '1'});
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final environGet =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'environ_get',
            )]!;

        expect(environGet([65535, 64]), 21);
        expect(environGet([0, 65535]), 21);
      },
    );

    test('clock_time_get + random_get populate memory', () {
      final wasi = WasiPreview1();
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7e, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'clock_time_get',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'random_get',
            typeIndex: 1,
          ),
        ],
        functionTypeIndices: [2],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._i64Const(0),
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(16),
              ..._i32Const(8),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 2),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), isNonZero);
      final randomBytes = instance.exportedMemory('memory').readBytes(16, 8);
      expect(randomBytes.any((b) => b != 0), isTrue);
    });

    test('fd_pwrite + fd_pread keep cursor unchanged', () {
      final fs = WasiInMemoryFileSystem();
      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType(
            [0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7f, 0x7f],
            [0x7f],
          ),
          _funcType([0x7f, 0x7f, 0x7f, 0x7e, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7e, 0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_open',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_pwrite',
            typeIndex: 1,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_seek',
            typeIndex: 2,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_pread',
            typeIndex: 1,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_tell',
            typeIndex: 3,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_close',
            typeIndex: 4,
          ),
        ],
        functionTypeIndices: [5],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(9),
              ..._i32Const(1),
              ..._i64Const(2097254),
              ..._i64Const(0),
              ..._i32Const(0),
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(16),
              ..._i32Const(128),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(20),
              ..._i32Const(5),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(16),
              ..._i32Const(1),
              ..._i64Const(0),
              ..._i32Const(24),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i64Const(2),
              ..._i32Const(0),
              ..._i32Const(40),
              ..._call(2),
              Opcodes.drop,
              ..._i32Const(32),
              ..._i32Const(300),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(36),
              ..._i32Const(2),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(32),
              ..._i32Const(1),
              ..._i64Const(1),
              ..._i32Const(44),
              ..._call(3),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(48),
              ..._call(4),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._call(5),
              Opcodes.drop,
              ..._i32Const(44),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(48),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(64), Opcodes.end],
            bytes: utf8.encode('pread.txt'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(128), Opcodes.end],
            bytes: utf8.encode('ABCDE'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 6),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 4);
      expect(fs.readFileText('/pread.txt'), 'ABCDE');
      expect(
        utf8.decode(instance.exportedMemory('memory').readBytes(300, 2)),
        'BC',
      );
    });

    test('fd_readdir returns directory entries', () {
      final fs = WasiInMemoryFileSystem();
      fs.createDirectory('/sub');
      final file = fs.open(
        path: '/a.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
      );
      file.write(Uint8List.fromList(utf8.encode('x')));
      file.close();

      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7e, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_readdir',
            typeIndex: 0,
          ),
        ],
        functionTypeIndices: [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(128),
              ..._i32Const(512),
              ..._i64Const(0),
              ..._i32Const(64),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(64),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      final used = instance.invokeI32('run');
      expect(used, greaterThan(0));

      final bytes = instance.exportedMemory('memory').readBytes(128, used);
      final names = _decodeDirentNames(bytes);
      expect(names, contains('a.txt'));
      expect(names, contains('sub'));
    });

    test('path_filestat_get and clock_res_get are supported', () {
      final fs = WasiInMemoryFileSystem();
      final file = fs.open(
        path: '/stat.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
      );
      file.write(Uint8List.fromList(utf8.encode('HELLO')));
      file.close();

      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_filestat_get',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'clock_res_get',
            typeIndex: 1,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'sched_yield',
            typeIndex: 2,
          ),
        ],
        functionTypeIndices: [2],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(8),
              ..._i32Const(128),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(0),
              ..._i32Const(200),
              ..._call(1),
              Opcodes.drop,
              ..._call(2),
              Opcodes.drop,
              ..._i32Const(160),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(200),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(64), Opcodes.end],
            bytes: utf8.encode('stat.txt'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 3),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 6);
      expect(instance.exportedMemory('memory').loadU8(144), 4);
    });

    test('fd_allocate grows file and fd_filestat_set_times updates mtime', () {
      final fs = WasiInMemoryFileSystem();
      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType(
            [0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7f, 0x7f],
            [0x7f],
          ),
          _funcType([0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7e, 0x7e], [0x7f]),
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
          _funcType([0x7f, 0x7e, 0x7e, 0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_open',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_write',
            typeIndex: 1,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_allocate',
            typeIndex: 2,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_filestat_set_times',
            typeIndex: 6,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_filestat_get',
            typeIndex: 3,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_close',
            typeIndex: 4,
          ),
        ],
        functionTypeIndices: [5],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(8),
              ..._i32Const(1),
              ..._i64Const(2130030),
              ..._i64Const(0),
              ..._i32Const(0),
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(16),
              ..._i32Const(128),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(20),
              ..._i32Const(1),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(16),
              ..._i32Const(1),
              ..._i32Const(24),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i64Const(10),
              ..._i64Const(5),
              ..._call(2),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i64Const(0),
              ..._i64Const(1234567),
              ..._i32Const(4),
              ..._call(3),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(200),
              ..._call(4),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._call(5),
              Opcodes.drop,
              ..._i32Const(232),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(248),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(64), Opcodes.end],
            bytes: utf8.encode('grow.bin'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(128), Opcodes.end],
            bytes: utf8.encode('A'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 6),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 1234582);
      expect(fs.readFileBytes('/grow.bin')!.length, 15);
    });

    test('fd_advise supports file descriptors and rejects invalid targets', () {
      final fs = WasiInMemoryFileSystem();
      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pathOpen = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'path_open')]!;
      final fdAdvise = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_advise')]!;
      final fdClose = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_close')]!;

      memory.writeBytesFromList(64, utf8.encode('advise.txt'));
      expect(pathOpen([3, 0, 64, 10, 1, 66, 0, 0, 32]), 0);
      final openedFd = memory.loadI32(32);
      expect(fdAdvise([openedFd, 0, 0, 0]), 0);
      expect(fdAdvise([3, 0, 0, 0]), 8);
      expect(fdAdvise([999, 0, 0, 0]), 8);
      expect(fdClose([openedFd]), 0);
    });

    test(
      'fd_datasync and fd_sync flush writable files and reject non-file descriptors',
      () {
        final fs = WasiInMemoryFileSystem();
        final wasi = WasiPreview1(fileSystem: fs);
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final pathOpen = wasi
            .imports
            .functions[WasmImports.key('wasi_snapshot_preview1', 'path_open')]!;
        final fdDatasync =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'fd_datasync',
            )]!;
        final fdSync = wasi
            .imports
            .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_sync')]!;
        final fdClose = wasi
            .imports
            .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_close')]!;

        memory.writeBytesFromList(64, utf8.encode('sync.txt'));
        expect(pathOpen([3, 0, 64, 8, 1, 66, 0, 0, 32]), 0);
        final openedFd = memory.loadI32(32);
        expect(fdDatasync([openedFd]), 0);
        expect(fdSync([openedFd]), 0);
        expect(fdDatasync([3]), 8);
        expect(fdSync([999]), 8);
        expect(fdClose([openedFd]), 0);
      },
    );

    test('fd_filestat_set_size truncates files and validates size bounds', () {
      final fs = WasiInMemoryFileSystem();
      final writer = fs.open(
        path: '/resize.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
      );
      writer.write(Uint8List.fromList(utf8.encode('ABCDE')));
      writer.close();

      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pathOpen = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'path_open')]!;
      final fdFilestatSetSize =
          wasi.imports.functions[WasmImports.key(
            'wasi_snapshot_preview1',
            'fd_filestat_set_size',
          )]!;
      final fdClose = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_close')]!;

      memory.writeBytesFromList(64, utf8.encode('resize.txt'));
      expect(pathOpen([3, 0, 64, 10, 0, 66, 0, 0, 32]), 0);
      final openedFd = memory.loadI32(32);
      expect(fdFilestatSetSize([openedFd, 2]), 0);
      expect(fs.readFileText('/resize.txt'), 'AB');
      expect(fdFilestatSetSize([openedFd, -1]), 28);
      expect(fdFilestatSetSize([3, 1]), 8);
      expect(fdClose([openedFd]), 0);
    });

    test('path_filestat_set_times updates path metadata in in-memory fs', () {
      final fs = WasiInMemoryFileSystem();
      final file = fs.open(
        path: '/ptime.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
      );
      file.write(Uint8List.fromList(utf8.encode('t')));
      file.close();

      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_filestat_set_times',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_filestat_get',
            typeIndex: 1,
          ),
        ],
        functionTypeIndices: [2],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(9),
              ..._i64Const(0),
              ..._i64Const(7654321),
              ..._i32Const(4),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(9),
              ..._i32Const(128),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(176),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(64), Opcodes.end],
            bytes: utf8.encode('ptime.txt'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 2),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 7654321);
    });

    test('poll_oneoff produces one clock event', () {
      final wasi = WasiPreview1();
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'poll_oneoff',
            typeIndex: 0,
          ),
        ],
        functionTypeIndices: [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(64),
              ..._i32Const(128),
              ..._i32Const(1),
              ..._i32Const(32),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(32),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(138),
              ..._memInstr(Opcodes.i32Load8U),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 1);
    });

    test('poll_oneoff rejects zero subscriptions', () {
      final wasi = WasiPreview1();
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pollOneoff = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'poll_oneoff')]!;

      expect(pollOneoff([64, 128, 0, 32]), 28);
    });

    test('poll_oneoff rejects unknown subscription event type', () {
      final wasi = WasiPreview1();
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pollOneoff = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'poll_oneoff')]!;

      memory.storeI32(32, 123);
      memory.fillBytes(128, 0x7a, 32);
      memory.storeI64(64, 7);
      memory.storeI8(72, 99);
      expect(pollOneoff([64, 128, 1, 32]), 28);
      expect(memory.loadI32(32), 123);
      expect(memory.loadU8(128), 0x7a);
    });

    test('poll_oneoff emits BADF event for unknown fd subscriptions', () {
      final wasi = WasiPreview1();
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pollOneoff = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'poll_oneoff')]!;

      memory.storeI64(64, 99);
      memory.storeI8(72, 1);
      memory.storeI32(80, 1234);
      expect(pollOneoff([64, 128, 1, 32]), 0);
      expect(memory.loadI32(32), 1);
      expect(memory.loadU16(136), 8);
      expect(memory.loadU8(138), 1);
    });

    test('poll_oneoff rejects invalid clock flags atomically', () {
      final wasi = WasiPreview1();
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pollOneoff = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'poll_oneoff')]!;

      memory.storeI32(32, 77);
      memory.fillBytes(128, 0x6b, 32);
      memory.storeI64(64, 42);
      memory.storeI8(72, 0); // clock
      memory.storeI32(80, 1); // monotonic
      memory.storeI64(88, 1); // timeout ns
      memory.storeI64(96, 0); // precision
      memory.storeI16(104, 0x0002); // invalid flags

      expect(pollOneoff([64, 128, 1, 32]), 28);
      expect(memory.loadI32(32), 77);
      expect(memory.loadU8(128), 0x6b);
    });

    test('poll_oneoff blocks on relative clock timeout then returns event', () {
      var nowNs = BigInt.from(1_000_000_000);
      final sleepDurations = <Duration>[];
      final wasi = WasiPreview1(
        nowRealtimeNs: () => nowNs,
        nowMonotonicNs: () => nowNs,
        sleep: (duration) {
          sleepDurations.add(duration);
          nowNs += BigInt.from(duration.inMicroseconds) * BigInt.from(1000);
        },
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pollOneoff = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'poll_oneoff')]!;

      memory.storeI64(64, 11);
      memory.storeI8(72, 0); // clock
      memory.storeI32(80, 1); // monotonic
      memory.storeI64(88, 5_000_000); // 5ms relative timeout
      memory.storeI64(96, 0); // precision
      memory.storeI16(104, 0); // relative

      expect(pollOneoff([64, 128, 1, 32]), 0);
      expect(memory.loadI32(32), 1);
      expect(memory.loadI64(128), BigInt.from(11));
      expect(memory.loadU16(136), 0);
      expect(memory.loadU8(138), 0);
      expect(sleepDurations, isNotEmpty);
    });

    test('poll_oneoff blocks on ABSTIME clock deadline then returns event', () {
      var nowNs = BigInt.from(3_000_000_000);
      final sleepDurations = <Duration>[];
      final wasi = WasiPreview1(
        nowRealtimeNs: () => nowNs,
        nowMonotonicNs: () => nowNs,
        sleep: (duration) {
          sleepDurations.add(duration);
          nowNs += BigInt.from(duration.inMicroseconds) * BigInt.from(1000);
        },
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pollOneoff = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'poll_oneoff')]!;

      memory.storeI64(64, 12);
      memory.storeI8(72, 0); // clock
      memory.storeI32(80, 1); // monotonic
      memory.storeI64(88, BigInt.from(3_008_000_000)); // absolute deadline
      memory.storeI64(96, 0); // precision
      memory.storeI16(104, 0x0001); // ABSTIME

      expect(pollOneoff([64, 128, 1, 32]), 0);
      expect(memory.loadI32(32), 1);
      expect(memory.loadI64(128), BigInt.from(12));
      expect(memory.loadU16(136), 0);
      expect(memory.loadU8(138), 0);
      expect(sleepDurations, isNotEmpty);
    });

    test('poll_oneoff preserves subscription order for mixed ready events', () {
      final wasi = WasiPreview1();
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pollOneoff = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'poll_oneoff')]!;

      // subscription 0: fd_write stdout (ready)
      memory.storeI64(64, 33);
      memory.storeI8(72, 2);
      memory.storeI32(80, 1);
      // subscription 1: clock immediate (ready)
      memory.storeI64(112, 44);
      memory.storeI8(120, 0);
      memory.storeI32(128, 1);
      memory.storeI64(136, 0);
      memory.storeI64(144, 0);
      memory.storeI16(152, 0);

      expect(pollOneoff([64, 256, 2, 32]), 0);
      expect(memory.loadI32(32), 2);
      expect(memory.loadI64(256), BigInt.from(33));
      expect(memory.loadU8(266), 2);
      expect(memory.loadI64(288), BigInt.from(44));
      expect(memory.loadU8(298), 0);
    });

    test('poll_oneoff blocks when no ready events and no timeout', () {
      final wasi = WasiPreview1(sleep: (_) => throw const _PollWaitAbort());
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pollOneoff = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'poll_oneoff')]!;

      memory.storeI32(32, 55);
      memory.fillBytes(128, 0x5c, 32);
      memory.storeI64(64, 9);
      memory.storeI8(72, 1); // fd_read
      memory.storeI32(80, 0); // stdin, empty buffer => not ready

      expect(
        () => pollOneoff([64, 128, 1, 32]),
        throwsA(isA<_PollWaitAbort>()),
      );
      expect(memory.loadI32(32), 55);
      expect(memory.loadU8(128), 0x5c);
    });

    test('path_open supports O_DIRECTORY for directory targets', () {
      final fs = WasiInMemoryFileSystem();
      fs.createDirectory('/data');
      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pathOpen = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'path_open')]!;
      final fdFdstatGet =
          wasi.imports.functions[WasmImports.key(
            'wasi_snapshot_preview1',
            'fd_fdstat_get',
          )]!;
      final fdClose = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_close')]!;

      memory.writeBytesFromList(64, utf8.encode('data'));
      expect(pathOpen([3, 0, 64, 4, 2, 0, 0, 0, 32]), 0);
      final openedFd = memory.loadI32(32);
      expect(openedFd, greaterThanOrEqualTo(4));
      expect(fdFdstatGet([openedFd, 96]), 0);
      expect(memory.loadU8(96), 3);
      expect(fdClose([openedFd]), 0);
    });

    test('path_open O_DIRECTORY returns NOTDIR for regular files', () {
      final fs = WasiInMemoryFileSystem();
      final file = fs.open(
        path: '/plain.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
      );
      file.write(Uint8List.fromList(utf8.encode('x')));
      file.close();
      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pathOpen = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'path_open')]!;

      memory.writeBytesFromList(64, utf8.encode('plain.txt'));
      expect(pathOpen([3, 0, 64, 9, 2, 0, 0, 0, 32]), 54);
    });

    test('path resolution returns BADF/NOTCAPABLE/INVAL/FAULT distinctly', () {
      final wasi = WasiPreview1(fileSystem: WasiInMemoryFileSystem());
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pathFilestatGet =
          wasi.imports.functions[WasmImports.key(
            'wasi_snapshot_preview1',
            'path_filestat_get',
          )]!;

      memory.writeBytesFromList(64, utf8.encode('ok'));
      expect(pathFilestatGet([99, 0, 64, 2, 128]), 8);

      memory.writeBytesFromList(64, utf8.encode('../escape'));
      expect(pathFilestatGet([3, 0, 64, 9, 128]), 76);

      memory.writeBytesFromList(64, const [0xff]);
      expect(pathFilestatGet([3, 0, 64, 1, 128]), 28);

      expect(pathFilestatGet([3, 0, 65535, 2, 128]), 21);
    });

    test('path_link + path_symlink + path_readlink work on in-memory fs', () {
      final fs = WasiInMemoryFileSystem();
      final source = fs.open(
        path: '/source.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
      );
      source.write(Uint8List.fromList(utf8.encode('ABC')));
      source.close();

      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_link',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_symlink',
            typeIndex: 1,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_readlink',
            typeIndex: 2,
          ),
        ],
        functionTypeIndices: [3],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(10),
              ..._i32Const(3),
              ..._i32Const(80),
              ..._i32Const(8),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(96),
              ..._i32Const(10),
              ..._i32Const(3),
              ..._i32Const(112),
              ..._i32Const(7),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(3),
              ..._i32Const(112),
              ..._i32Const(7),
              ..._i32Const(160),
              ..._i32Const(64),
              ..._i32Const(40),
              ..._call(2),
              Opcodes.drop,
              ..._i32Const(40),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(64), Opcodes.end],
            bytes: utf8.encode('source.txt'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(80), Opcodes.end],
            bytes: utf8.encode('hard.txt'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(96), Opcodes.end],
            bytes: utf8.encode('source.txt'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(112), Opcodes.end],
            bytes: utf8.encode('sym.txt'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 3),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 10);
      expect(fs.readFileText('/hard.txt'), 'ABC');
      expect(fs.readlink('/sym.txt'), 'source.txt');
      expect(
        utf8.decode(instance.exportedMemory('memory').readBytes(160, 10)),
        'source.txt',
      );
    });

    test('fd_fdstat_set_rights and fd_renumber are supported', () {
      final fs = WasiInMemoryFileSystem();
      final wasi = WasiPreview1(fileSystem: fs);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType(
            [0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7f, 0x7f],
            [0x7f],
          ),
          _funcType([0x7f, 0x7e, 0x7e], [0x7f]),
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_write',
            typeIndex: 0,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'path_open',
            typeIndex: 1,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_fdstat_set_rights',
            typeIndex: 2,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_renumber',
            typeIndex: 3,
          ),
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'fd_fdstat_get',
            typeIndex: 4,
          ),
        ],
        functionTypeIndices: [5],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(64),
              ..._i32Const(7),
              ..._i32Const(1),
              ..._i64Const(66),
              ..._i64Const(0),
              ..._i32Const(0),
              ..._i32Const(0),
              ..._call(1),
              Opcodes.drop,
              ..._i32Const(16),
              ..._i32Const(160),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(20),
              ..._i32Const(1),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i64Const(2),
              ..._i64Const(0),
              ..._call(2),
              Opcodes.drop,
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(16),
              ..._i32Const(1),
              ..._i32Const(40),
              ..._call(0),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._i32Const(20),
              ..._call(3),
              Opcodes.drop,
              ..._i32Const(20),
              ..._i32Const(256),
              ..._call(4),
              Opcodes.drop,
              ..._i32Const(264),
              ..._memInstr(Opcodes.i32Load),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(64), Opcodes.end],
            bytes: utf8.encode('cap.txt'),
          ),
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(160), Opcodes.end],
            bytes: utf8.encode('Z'),
          ),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 5),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);
      expect(instance.invokeI32('run'), 78);
    });

    test(
      'proc_raise defaults to ENOSYS and sock_* imports are ENOSYS stubs',
      () {
        final wasi = WasiPreview1();
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
            _funcType([0x7f, 0x7f, 0x7f], [0x7f]),
            _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
            _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
            _funcType([0x7f, 0x7f], [0x7f]),
            _funcType([], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(
              module: 'wasi_snapshot_preview1',
              name: 'proc_raise',
              typeIndex: 0,
            ),
            _ImportFunctionSpec(
              module: 'wasi_snapshot_preview1',
              name: 'sock_accept',
              typeIndex: 1,
            ),
            _ImportFunctionSpec(
              module: 'wasi_snapshot_preview1',
              name: 'sock_recv',
              typeIndex: 2,
            ),
            _ImportFunctionSpec(
              module: 'wasi_snapshot_preview1',
              name: 'sock_send',
              typeIndex: 3,
            ),
            _ImportFunctionSpec(
              module: 'wasi_snapshot_preview1',
              name: 'sock_shutdown',
              typeIndex: 4,
            ),
          ],
          functionTypeIndices: [5],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._i32Const(0),
                ..._call(0),
                ..._i32Const(0),
                ..._i32Const(0),
                ..._i32Const(0),
                ..._call(1),
                Opcodes.i32Add,
                ..._i32Const(0),
                ..._i32Const(0),
                ..._i32Const(0),
                ..._i32Const(0),
                ..._i32Const(0),
                ..._i32Const(0),
                ..._call(2),
                Opcodes.i32Add,
                ..._i32Const(0),
                ..._i32Const(0),
                ..._i32Const(0),
                ..._i32Const(0),
                ..._i32Const(0),
                ..._call(3),
                Opcodes.i32Add,
                ..._i32Const(0),
                ..._i32Const(0),
                ..._call(4),
                Opcodes.i32Add,
                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 5),
          ],
        );

        final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
        expect(instance.invokeI32('run'), 260);
      },
    );

    test(
      'sock_accept delegates to socket transport and writes accepted fd',
      () {
        final wasi = WasiPreview1(
          socketTransport: WasiSocketTransport(
            accept: ({required fd, required flags, required allocateFd}) {
              expect(fd, 41);
              expect(flags, 3);
              return WasiSockAcceptResult.accepted(allocateFd());
            },
            containsFd: ({required fd}) => fd == 4,
          ),
        );
        final wasm = _buildSockAcceptModule(fd: 41, flags: 3, roFdPtr: 64);
        final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
        wasi.bindInstance(instance);

        expect(instance.invokeI32('run'), 0);
        final memory = instance.exportedMemory('memory');
        expect(memory.loadI32(64), 5);
      },
    );

    test('sock_recv copies data into iovecs and writes result metadata', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          recv: ({required fd, required flags, required maxBytes}) {
            expect(fd, 7);
            expect(flags, 9);
            expect(maxBytes, 5);
            return WasiSockRecvResult.received(
              Uint8List.fromList([1, 2, 3, 4, 5, 6]),
              flags: 2,
            );
          },
        ),
      );
      final wasm = _buildSockRecvModule(
        fd: 7,
        riFlags: 9,
        riDataPtr: 32,
        firstDataPtr: 96,
        firstDataLen: 2,
        secondDataPtr: 98,
        secondDataLen: 3,
        roDatalenPtr: 48,
        roFlagsPtr: 52,
      );
      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);

      expect(instance.invokeI32('run'), 0);
      final memory = instance.exportedMemory('memory');
      expect(memory.readBytes(96, 2), [1, 2]);
      expect(memory.readBytes(98, 3), [3, 4, 5]);
      expect(memory.loadI32(48), 5);
      expect(memory.loadU16(52), 2);
    });

    test('sock_send flattens ciovecs and reports bytes written', () {
      var capturedFd = -1;
      var capturedFlags = -1;
      var capturedData = Uint8List(0);
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          send: ({required fd, required flags, required data}) {
            capturedFd = fd;
            capturedFlags = flags;
            capturedData = Uint8List.fromList(data);
            return const WasiSockSendResult.sent(3);
          },
        ),
      );
      final wasm = _buildSockSendModule(
        fd: 11,
        siFlags: 7,
        siDataPtr: 32,
        firstDataPtr: 96,
        firstDataLen: 2,
        secondDataPtr: 98,
        secondDataLen: 3,
        soDatalenPtr: 48,
        payload: const [65, 66, 67, 68, 69],
      );
      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      wasi.bindInstance(instance);

      expect(instance.invokeI32('run'), 0);
      expect(capturedFd, 11);
      expect(capturedFlags, 7);
      expect(capturedData, [65, 66, 67, 68, 69]);
      expect(instance.exportedMemory('memory').loadI32(48), 3);
    });

    test('sock_shutdown returns errno from socket transport', () {
      var called = false;
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          shutdown: ({required fd, required how}) {
            called = true;
            expect(fd, 9);
            expect(how, 2);
            return 0;
          },
        ),
      );
      final wasm = _buildSockShutdownModule(fd: 9, how: 2);
      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);

      expect(instance.invokeI32('run'), 0);
      expect(called, isTrue);
    });

    test('fd_close closes socket-only descriptors via socket transport', () {
      var closedFd = -1;
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          close: ({required fd}) {
            closedFd = fd;
            return 0;
          },
        ),
      );
      final wasm = _buildFdCloseModule(fd: 77);
      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);

      expect(instance.invokeI32('run'), 0);
      expect(closedFd, 77);
    });

    test('proc_raise mode success returns errno 0', () {
      final wasi = WasiPreview1(
        procRaiseMode: WasiProcRaiseMode.success,
        allowNonStandardWasi: true,
      );
      final wasm = _buildProcRaiseModule(signal: 15);
      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);

      expect(instance.invokeI32('run'), 0);
    });

    test('proc_raise mode trap throws WasiProcRaise with signal', () {
      final wasi = WasiPreview1(
        procRaiseMode: WasiProcRaiseMode.trap,
        allowNonStandardWasi: true,
      );
      final wasm = _buildProcRaiseModule(signal: 9);
      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);

      expect(
        () => instance.invokeI32('run'),
        throwsA(isA<WasiProcRaise>().having((e) => e.signal, 'signal', 9)),
      );
    });

    test('proc_raise non-standard modes require explicit opt-in', () {
      expect(
        () => WasiPreview1(procRaiseMode: WasiProcRaiseMode.success),
        throwsArgumentError,
      );
      expect(
        () => WasiPreview1(procRaiseMode: WasiProcRaiseMode.trap),
        throwsArgumentError,
      );
    });
  });
}

Uint8List _buildProcRaiseModule({required int signal}) {
  return _buildModule(
    types: [
      _funcType([0x7f], [0x7f]),
      _funcType([], [0x7f]),
    ],
    imports: const [
      _ImportFunctionSpec(
        module: 'wasi_snapshot_preview1',
        name: 'proc_raise',
        typeIndex: 0,
      ),
    ],
    functionTypeIndices: [1],
    functionBodies: [
      _FunctionBodySpec(
        instructions: [..._i32Const(signal), ..._call(0), Opcodes.end],
      ),
    ],
    exports: const [
      _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
    ],
  );
}

Uint8List _buildSockAcceptModule({
  required int fd,
  required int flags,
  required int roFdPtr,
}) {
  return _buildModule(
    types: [
      _funcType([0x7f, 0x7f, 0x7f], [0x7f]),
      _funcType([], [0x7f]),
    ],
    imports: const [
      _ImportFunctionSpec(
        module: 'wasi_snapshot_preview1',
        name: 'sock_accept',
        typeIndex: 0,
      ),
    ],
    functionTypeIndices: [1],
    functionBodies: [
      _FunctionBodySpec(
        instructions: [
          ..._i32Const(fd),
          ..._i32Const(flags),
          ..._i32Const(roFdPtr),
          ..._call(0),
          Opcodes.end,
        ],
      ),
    ],
    memoryMinPages: 1,
    exports: const [
      _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
      _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
    ],
  );
}

Uint8List _buildSockRecvModule({
  required int fd,
  required int riFlags,
  required int riDataPtr,
  required int firstDataPtr,
  required int firstDataLen,
  required int secondDataPtr,
  required int secondDataLen,
  required int roDatalenPtr,
  required int roFlagsPtr,
}) {
  return _buildModule(
    types: [
      _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
      _funcType([], [0x7f]),
    ],
    imports: const [
      _ImportFunctionSpec(
        module: 'wasi_snapshot_preview1',
        name: 'sock_recv',
        typeIndex: 0,
      ),
    ],
    functionTypeIndices: [1],
    functionBodies: [
      _FunctionBodySpec(
        instructions: [
          ..._i32Const(riDataPtr),
          ..._i32Const(firstDataPtr),
          ..._memInstr(Opcodes.i32Store),
          ..._i32Const(riDataPtr + 4),
          ..._i32Const(firstDataLen),
          ..._memInstr(Opcodes.i32Store),
          ..._i32Const(riDataPtr + 8),
          ..._i32Const(secondDataPtr),
          ..._memInstr(Opcodes.i32Store),
          ..._i32Const(riDataPtr + 12),
          ..._i32Const(secondDataLen),
          ..._memInstr(Opcodes.i32Store),
          ..._i32Const(fd),
          ..._i32Const(riDataPtr),
          ..._i32Const(2),
          ..._i32Const(riFlags),
          ..._i32Const(roDatalenPtr),
          ..._i32Const(roFlagsPtr),
          ..._call(0),
          Opcodes.end,
        ],
      ),
    ],
    memoryMinPages: 1,
    exports: const [
      _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
      _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
    ],
  );
}

Uint8List _buildSockSendModule({
  required int fd,
  required int siFlags,
  required int siDataPtr,
  required int firstDataPtr,
  required int firstDataLen,
  required int secondDataPtr,
  required int secondDataLen,
  required int soDatalenPtr,
  required List<int> payload,
}) {
  return _buildModule(
    types: [
      _funcType([0x7f, 0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
      _funcType([], [0x7f]),
    ],
    imports: const [
      _ImportFunctionSpec(
        module: 'wasi_snapshot_preview1',
        name: 'sock_send',
        typeIndex: 0,
      ),
    ],
    functionTypeIndices: [1],
    functionBodies: [
      _FunctionBodySpec(
        instructions: [
          ..._i32Const(siDataPtr),
          ..._i32Const(firstDataPtr),
          ..._memInstr(Opcodes.i32Store),
          ..._i32Const(siDataPtr + 4),
          ..._i32Const(firstDataLen),
          ..._memInstr(Opcodes.i32Store),
          ..._i32Const(siDataPtr + 8),
          ..._i32Const(secondDataPtr),
          ..._memInstr(Opcodes.i32Store),
          ..._i32Const(siDataPtr + 12),
          ..._i32Const(secondDataLen),
          ..._memInstr(Opcodes.i32Store),
          ..._i32Const(fd),
          ..._i32Const(siDataPtr),
          ..._i32Const(2),
          ..._i32Const(siFlags),
          ..._i32Const(soDatalenPtr),
          ..._call(0),
          Opcodes.end,
        ],
      ),
    ],
    memoryMinPages: 1,
    dataSegments: [
      _DataSegmentSpec.active(
        memoryIndex: 0,
        offsetExpr: [..._i32Const(firstDataPtr), Opcodes.end],
        bytes: payload,
      ),
    ],
    exports: const [
      _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
      _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
    ],
  );
}

Uint8List _buildSockShutdownModule({required int fd, required int how}) {
  return _buildModule(
    types: [
      _funcType([0x7f, 0x7f], [0x7f]),
      _funcType([], [0x7f]),
    ],
    imports: const [
      _ImportFunctionSpec(
        module: 'wasi_snapshot_preview1',
        name: 'sock_shutdown',
        typeIndex: 0,
      ),
    ],
    functionTypeIndices: [1],
    functionBodies: [
      _FunctionBodySpec(
        instructions: [
          ..._i32Const(fd),
          ..._i32Const(how),
          ..._call(0),
          Opcodes.end,
        ],
      ),
    ],
    exports: const [
      _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
    ],
  );
}

Uint8List _buildFdCloseModule({required int fd}) {
  return _buildModule(
    types: [
      _funcType([0x7f], [0x7f]),
      _funcType([], [0x7f]),
    ],
    imports: const [
      _ImportFunctionSpec(
        module: 'wasi_snapshot_preview1',
        name: 'fd_close',
        typeIndex: 0,
      ),
    ],
    functionTypeIndices: [1],
    functionBodies: [
      _FunctionBodySpec(
        instructions: [..._i32Const(fd), ..._call(0), Opcodes.end],
      ),
    ],
    exports: const [
      _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
    ],
  );
}

String _readCString(WasmMemory memory, int pointer) {
  final codeUnits = <int>[];
  var cursor = pointer;
  while (true) {
    final b = memory.loadU8(cursor);
    if (b == 0) {
      return utf8.decode(codeUnits);
    }
    codeUnits.add(b);
    cursor++;
  }
}

Set<String> _decodeDirentNames(Uint8List bytes) {
  final names = <String>{};
  var cursor = 0;
  while (cursor + 24 <= bytes.length) {
    final view = ByteData.sublistView(bytes, cursor);
    final nameLen = view.getUint32(16, Endian.little);
    if (cursor + 24 + nameLen > bytes.length) {
      break;
    }
    final nameBytes = bytes.sublist(cursor + 24, cursor + 24 + nameLen);
    names.add(utf8.decode(nameBytes));
    cursor += 24 + nameLen;
  }
  return names;
}

final class _FunctionBodySpec {
  const _FunctionBodySpec({required this.instructions});

  final List<int> instructions;
}

final class _ImportFunctionSpec {
  const _ImportFunctionSpec({
    required this.module,
    required this.name,
    required this.typeIndex,
  });

  final String module;
  final String name;
  final int typeIndex;
}

final class _DataSegmentSpec {
  const _DataSegmentSpec.active({
    required this.memoryIndex,
    required this.offsetExpr,
    required this.bytes,
  });

  final int memoryIndex;
  final List<int> offsetExpr;
  final List<int> bytes;
}

final class _ExportSpec {
  const _ExportSpec({
    required this.name,
    required this.kind,
    required this.index,
  });

  final String name;
  final int kind;
  final int index;
}

final class _PollWaitAbort implements Exception {
  const _PollWaitAbort();
}

Uint8List _buildModule({
  required List<List<int>> types,
  required List<_ImportFunctionSpec> imports,
  required List<int> functionTypeIndices,
  required List<_FunctionBodySpec> functionBodies,
  List<_DataSegmentSpec> dataSegments = const [],
  List<_ExportSpec> exports = const [],
  int? memoryMinPages,
  int? memoryMaxPages,
}) {
  if (functionTypeIndices.length != functionBodies.length) {
    throw ArgumentError(
      'functionTypeIndices and functionBodies length mismatch.',
    );
  }

  final bytes = <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

  bytes.addAll(
    _section(1, <int>[..._u32Leb(types.length), ...types.expand((it) => it)]),
  );

  if (imports.isNotEmpty) {
    final payload = <int>[..._u32Leb(imports.length)];
    for (final import in imports) {
      payload
        ..addAll(_name(import.module))
        ..addAll(_name(import.name))
        ..add(WasmImportKind.function)
        ..addAll(_u32Leb(import.typeIndex));
    }
    bytes.addAll(_section(2, payload));
  }

  bytes.addAll(
    _section(3, <int>[
      ..._u32Leb(functionTypeIndices.length),
      ...functionTypeIndices.expand(_u32Leb),
    ]),
  );

  if (memoryMinPages != null) {
    bytes.addAll(
      _section(5, <int>[
        ..._u32Leb(1),
        ..._limits(memoryMinPages, memoryMaxPages),
      ]),
    );
  }

  if (exports.isNotEmpty) {
    final payload = <int>[..._u32Leb(exports.length)];
    for (final export in exports) {
      payload
        ..addAll(_name(export.name))
        ..add(export.kind)
        ..addAll(_u32Leb(export.index));
    }
    bytes.addAll(_section(7, payload));
  }

  final codePayload = <int>[..._u32Leb(functionBodies.length)];
  for (final body in functionBodies) {
    if (body.instructions.isEmpty || body.instructions.last != Opcodes.end) {
      throw ArgumentError('Function body must end with Opcodes.end.');
    }
    final functionBody = <int>[0x00, ...body.instructions];
    codePayload
      ..addAll(_u32Leb(functionBody.length))
      ..addAll(functionBody);
  }
  bytes.addAll(_section(10, codePayload));

  if (dataSegments.isNotEmpty) {
    final payload = <int>[..._u32Leb(dataSegments.length)];
    for (final data in dataSegments) {
      if (data.memoryIndex == 0) {
        payload
          ..addAll(_u32Leb(0))
          ..addAll(data.offsetExpr)
          ..addAll(_u32Leb(data.bytes.length))
          ..addAll(data.bytes);
      } else {
        payload
          ..addAll(_u32Leb(2))
          ..addAll(_u32Leb(data.memoryIndex))
          ..addAll(data.offsetExpr)
          ..addAll(_u32Leb(data.bytes.length))
          ..addAll(data.bytes);
      }
    }
    bytes.addAll(_section(11, payload));
  }

  return Uint8List.fromList(bytes);
}

List<int> _section(int id, List<int> payload) {
  return <int>[id, ..._u32Leb(payload.length), ...payload];
}

List<int> _funcType(List<int> params, List<int> results) {
  return <int>[
    0x60,
    ..._u32Leb(params.length),
    ...params,
    ..._u32Leb(results.length),
    ...results,
  ];
}

List<int> _name(String value) {
  final encoded = utf8.encode(value);
  return <int>[..._u32Leb(encoded.length), ...encoded];
}

List<int> _limits(int min, int? max) {
  if (max == null) {
    return <int>[0x00, ..._u32Leb(min)];
  }
  return <int>[0x01, ..._u32Leb(min), ..._u32Leb(max)];
}

List<int> _memInstr(int opcode, {int align = 0, int offset = 0}) => <int>[
  opcode,
  ..._u32Leb(align),
  ..._u32Leb(offset),
];

List<int> _call(int index) => <int>[Opcodes.call, ..._u32Leb(index)];

List<int> _i32Const(int value) => <int>[Opcodes.i32Const, ..._i32Leb(value)];
List<int> _i64Const(int value) => <int>[Opcodes.i64Const, ..._i64Leb(value)];

List<int> _u32Leb(int value) {
  if (value < 0) {
    throw ArgumentError.value(value, 'value');
  }

  final bytes = <int>[];
  var current = value;
  do {
    var byte = current & 0x7f;
    current >>= 7;
    if (current != 0) {
      byte |= 0x80;
    }
    bytes.add(byte);
  } while (current != 0);
  return bytes;
}

List<int> _i32Leb(int value) {
  final bytes = <int>[];
  var current = value;
  var more = true;

  while (more) {
    var byte = current & 0x7f;
    current >>= 7;

    final signBitSet = (byte & 0x40) != 0;
    final done = (current == 0 && !signBitSet) || (current == -1 && signBitSet);

    if (!done) {
      byte |= 0x80;
    }

    bytes.add(byte);
    more = !done;
  }

  return bytes;
}

List<int> _i64Leb(int value) {
  final bytes = <int>[];
  var current = value;
  var more = true;

  while (more) {
    var byte = current & 0x7f;
    current >>= 7;

    final signBitSet = (byte & 0x40) != 0;
    final done = (current == 0 && !signBitSet) || (current == -1 && signBitSet);

    if (!done) {
      byte |= 0x80;
    }

    bytes.add(byte);
    more = !done;
  }

  return bytes;
}
