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
      expect(instance.invokeI32('run'), 65);
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

    test('proc_raise handler int return is used as errno', () {
      int? seenSignal;
      final wasi = WasiPreview1(
        procRaiseHandler: (signal) {
          seenSignal = signal;
          return 28;
        },
      );
      final wasm = _buildProcRaiseModule(signal: 15);
      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);

      expect(instance.invokeI32('run'), 28);
      expect(seenSignal, 15);
    });

    test('proc_raise handler null return is treated as errno 0', () {
      var callCount = 0;
      final wasi = WasiPreview1(
        procRaiseHandler: (signal) {
          callCount++;
          expect(signal, 9);
          return null;
        },
      );
      final wasm = _buildProcRaiseModule(signal: 9);
      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);

      expect(instance.invokeI32('run'), 0);
      expect(callCount, 1);
    });

    test('proc_raise handler exception is propagated', () {
      final error = StateError('proc_raise handler failure');
      final wasi = WasiPreview1(procRaiseHandler: (_) => throw error);
      final wasm = _buildProcRaiseModule(signal: 2);
      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);

      expect(() => instance.invokeI32('run'), throwsA(same(error)));
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
