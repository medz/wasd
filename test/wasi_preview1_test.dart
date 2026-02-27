import 'dart:convert';
import 'dart:typed_data';

import 'package:wasd/wasd.dart';
import 'package:test/test.dart';

const int _errnoSuccess = 0;
const int _errnoBadf = 8;
const int _errnoExist = 20;
const int _errnoFault = 21;
const int _errnoInval = 28;
const int _errnoIsdir = 31;
const int _errnoLoop = 32;
const int _errnoNametoolong = 37;
const int _errnoNoent = 44;
const int _errnoNosys = 52;
const int _errnoNotdir = 54;
const int _errnoNotempty = 55;
const int _errnoNotsup = 58;
const int _errnoNotcapable = 76;

const int _lookupflagSymlinkFollow = 0x0001;
const int _oflagCreat = 0x0001;
const int _oflagDirectory = 0x0002;
const int _oflagExcl = 0x0004;
const int _oflagTrunc = 0x0008;

const int _fstFlagMtim = 0x0004;

const int _rightFdDatasync = 0x0000000000000001;
const int _rightFdRead = 0x0000000000000002;
const int _rightFdSeek = 0x0000000000000004;
const int _rightFdFdstatSetFlags = 0x0000000000000008;
const int _rightFdSync = 0x0000000000000010;
const int _rightFdTell = 0x0000000000000020;
const int _rightFdWrite = 0x0000000000000040;
const int _rightFdAdvise = 0x0000000000000080;
const int _rightFdAllocate = 0x0000000000000100;
const int _rightFdReaddir = 0x0000000000004000;
const int _rightFdFileStatSetTimes = 0x0000000000008000;
const int _rightFdFileStatGet = 0x0000000000200000;
const int _rightFdFileStatSetSize = 0x0000000000400000;

const int _rightFdReadWrite = _rightFdRead | _rightFdWrite;
const int _maxWasiFileSize = 0x7fffffffffffffff;

const int _sockAcceptFlagNonblock = 0x0004;
const int _sockRecvFlagPeek = 0x0001;
const int _sockRecvFlagWaitall = 0x0002;
const int _sockRecvRoFlagDataTruncated = 0x0001;

const int _filetypeRegularFile = 4;
const int _filetypeSymbolicLink = 7;

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

    test('proc_exit direct host call throws WasiProcExit with i32 code', () {
      final wasi = WasiPreview1();
      final procExit = _wasiFunction(wasi, 'proc_exit');

      expect(
        () => procExit([27]),
        throwsA(isA<WasiProcExit>().having((e) => e.exitCode, 'exitCode', 27)),
      );
    });

    test(
      'proc_exit direct host call keeps StateError contract for missing/invalid args',
      () {
        final wasi = WasiPreview1();
        final procExit = _wasiFunction(wasi, 'proc_exit');

        expect(() => procExit([]), throwsStateError);
        expect(() => procExit(['bad']), throwsStateError);
      },
    );

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

    test(
      'random_get direct host call returns success and writes in-bounds',
      () {
        final wasi = WasiPreview1();
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final randomGet = _wasiFunction(wasi, 'random_get');

        memory.storeI8(31, 0x55);
        memory.storeI8(40, 0x66);
        expect(randomGet([32, 8]), _errnoSuccess);

        final bytes = memory.readBytes(32, 8);
        expect(bytes.length, 8);
        expect(memory.loadU8(31), 0x55);
        expect(memory.loadU8(40), 0x66);
      },
    );

    test('random_get returns EINVAL for negative length', () {
      final wasi = WasiPreview1();
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final randomGet = _wasiFunction(wasi, 'random_get');

      expect(randomGet([0, -1]), _errnoInval);
    });

    test('random_get returns EFAULT for out-of-bounds destination buffer', () {
      final wasi = WasiPreview1();
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final randomGet = _wasiFunction(wasi, 'random_get');

      expect(randomGet([65535, 2]), _errnoFault);
    });

    test(
      'random_get direct host call keeps StateError contract for missing/invalid args',
      () {
        final wasi = WasiPreview1();
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final randomGet = _wasiFunction(wasi, 'random_get');

        expect(() => randomGet([]), throwsStateError);
        expect(() => randomGet(['bad', 4]), throwsStateError);
      },
    );

    test(
      'clock_time_get supports realtime/monotonic/process/thread mappings',
      () {
        final wasi = WasiPreview1(
          nowRealtimeNs: () => BigInt.from(111),
          nowMonotonicNs: () => BigInt.from(222),
        );
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final clockTimeGet =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'clock_time_get',
            )]!;

        expect(clockTimeGet([0, 0, 0]), 0);
        expect(memory.loadI64(0), BigInt.from(111));

        expect(clockTimeGet([1, 0, 8]), 0);
        expect(memory.loadI64(8), BigInt.from(222));

        expect(clockTimeGet([2, 0, 16]), 0);
        expect(memory.loadI64(16), BigInt.from(222));

        expect(clockTimeGet([3, 0, 24]), 0);
        expect(memory.loadI64(24), BigInt.from(222));
      },
    );

    test(
      'clock_time_get returns EINVAL for unsupported id and EFAULT for oob pointer',
      () {
        final wasi = WasiPreview1();
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final clockTimeGet =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'clock_time_get',
            )]!;

        expect(clockTimeGet([99, 0, 0]), 28);
        expect(clockTimeGet([0, 0, 65535]), 21);
      },
    );

    test(
      'clock_res_get supports all preview1 clock ids with 1ns resolution',
      () {
        final wasi = WasiPreview1();
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final clockResGet =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'clock_res_get',
            )]!;

        expect(clockResGet([0, 0]), 0);
        expect(memory.loadI64(0), BigInt.one);

        expect(clockResGet([1, 8]), 0);
        expect(memory.loadI64(8), BigInt.one);

        expect(clockResGet([2, 16]), 0);
        expect(memory.loadI64(16), BigInt.one);

        expect(clockResGet([3, 24]), 0);
        expect(memory.loadI64(24), BigInt.one);
      },
    );

    test(
      'clock_res_get returns EINVAL for unsupported id and EFAULT for oob pointer',
      () {
        final wasi = WasiPreview1();
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final clockResGet =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'clock_res_get',
            )]!;

        expect(clockResGet([99, 0]), 28);
        expect(clockResGet([0, 65535]), 21);
      },
    );

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
        followSymlinks: true,
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

    test('fd_readdir requires RIGHT_FD_READDIR on opened directory fds', () {
      final fs = WasiInMemoryFileSystem();
      fs.createDirectory('/scan');
      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final fdReaddir = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_readdir')]!;

      expect(
        _pathOpen(
          wasi: wasi,
          memory: memory,
          path: 'scan',
          oflags: _oflagDirectory,
          rightsBase: 0,
        ),
        _errnoSuccess,
      );
      final dirFd = memory.loadI32(32);
      expect(fdReaddir([dirFd, 96, 64, 0, 24]), _errnoNotcapable);
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
        followSymlinks: true,
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
              ..._i64Const(
                _rightFdRead |
                    _rightFdWrite |
                    _rightFdSeek |
                    _rightFdFdstatSetFlags |
                    _rightFdTell |
                    _rightFdAllocate |
                    _rightFdFileStatSetTimes |
                    _rightFdFileStatGet,
              ),
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
      final fdAdvise = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_advise')]!;
      final fdClose = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_close')]!;

      expect(
        _pathOpen(
          wasi: wasi,
          memory: memory,
          path: 'advise.txt',
          oflags: _oflagCreat,
          rightsBase: _rightFdReadWrite | _rightFdAdvise,
        ),
        _errnoSuccess,
      );
      final openedFd = memory.loadI32(32);
      expect(fdAdvise([openedFd, 0, 0, 0]), _errnoSuccess);
      expect(fdAdvise([openedFd, 0, 0, 99]), _errnoInval);
      expect(fdAdvise([openedFd, -1, 0, 0]), _errnoInval);
      expect(fdAdvise([openedFd, 0, -1, 0]), _errnoInval);
      expect(fdAdvise([openedFd, _maxWasiFileSize, 1, 0]), _errnoInval);
      expect(fdAdvise([3, 0, 0, 0]), _errnoBadf);
      expect(fdAdvise([999, 0, 0, 0]), _errnoBadf);
      expect(fdClose([openedFd]), _errnoSuccess);
    });

    test('fd_advise requires RIGHT_FD_ADVISE', () {
      final wasi = WasiPreview1(fileSystem: WasiInMemoryFileSystem());
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final fdAdvise = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_advise')]!;

      expect(
        _pathOpen(
          wasi: wasi,
          memory: memory,
          path: 'no-advise.txt',
          oflags: _oflagCreat,
          rightsBase: _rightFdReadWrite,
        ),
        _errnoSuccess,
      );
      final openedFd = memory.loadI32(32);
      expect(fdAdvise([openedFd, 0, 0, 0]), _errnoNotcapable);
    });

    test('fd_allocate validates range and requires RIGHT_FD_ALLOCATE', () {
      final fs = WasiInMemoryFileSystem();
      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final fdAllocate = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_allocate')]!;

      expect(
        _pathOpen(
          wasi: wasi,
          memory: memory,
          path: 'alloc.txt',
          oflags: _oflagCreat,
          rightsBase: _rightFdWrite | _rightFdAllocate,
        ),
        _errnoSuccess,
      );
      final fdWithAllocate = memory.loadI32(32);
      expect(fdAllocate([fdWithAllocate, 2, 4]), _errnoSuccess);
      expect(fs.readFileBytes('/alloc.txt')!.length, 6);
      expect(fdAllocate([fdWithAllocate, -1, 1]), _errnoInval);
      expect(fdAllocate([fdWithAllocate, 0, -1]), _errnoInval);
      expect(fdAllocate([fdWithAllocate, _maxWasiFileSize, 1]), _errnoInval);

      expect(
        _pathOpen(
          wasi: wasi,
          memory: memory,
          path: 'alloc-no-right.txt',
          oflags: _oflagCreat,
          rightsBase: _rightFdWrite,
          outFdPtr: 36,
        ),
        _errnoSuccess,
      );
      final fdNoAllocate = memory.loadI32(36);
      expect(fdAllocate([fdNoAllocate, 0, 1]), _errnoNotcapable);
      expect(fdAllocate([3, 0, 1]), _errnoBadf);
    });

    test(
      'fd_datasync and fd_sync flush writable files and reject non-file descriptors',
      () {
        final fs = WasiInMemoryFileSystem();
        final wasi = WasiPreview1(fileSystem: fs);
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
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

        expect(
          _pathOpen(
            wasi: wasi,
            memory: memory,
            path: 'sync.txt',
            oflags: _oflagCreat,
            rightsBase: _rightFdWrite | _rightFdDatasync | _rightFdSync,
          ),
          _errnoSuccess,
        );
        final openedFd = memory.loadI32(32);
        expect(fdDatasync([openedFd]), _errnoSuccess);
        expect(fdSync([openedFd]), _errnoSuccess);
        expect(fdDatasync([3]), _errnoBadf);
        expect(fdSync([999]), _errnoBadf);
        expect(fdClose([openedFd]), _errnoSuccess);
      },
    );

    test('fd_datasync and fd_sync enforce independent rights', () {
      final wasi = WasiPreview1(fileSystem: WasiInMemoryFileSystem());
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final fdDatasync = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_datasync')]!;
      final fdSync = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_sync')]!;

      expect(
        _pathOpen(
          wasi: wasi,
          memory: memory,
          path: 'datasync-only.txt',
          oflags: _oflagCreat,
          rightsBase: _rightFdWrite | _rightFdDatasync,
        ),
        _errnoSuccess,
      );
      final datasyncFd = memory.loadI32(32);
      expect(fdDatasync([datasyncFd]), _errnoSuccess);
      expect(fdSync([datasyncFd]), _errnoNotcapable);

      expect(
        _pathOpen(
          wasi: wasi,
          memory: memory,
          path: 'sync-only.txt',
          oflags: _oflagCreat,
          rightsBase: _rightFdWrite | _rightFdSync,
          outFdPtr: 36,
        ),
        _errnoSuccess,
      );
      final syncFd = memory.loadI32(36);
      expect(fdSync([syncFd]), _errnoSuccess);
      expect(fdDatasync([syncFd]), _errnoNotcapable);
    });

    test('fd_filestat_set_size truncates files and validates size bounds', () {
      final fs = WasiInMemoryFileSystem();
      final writer = fs.open(
        path: '/resize.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
        followSymlinks: true,
      );
      writer.write(Uint8List.fromList(utf8.encode('ABCDE')));
      writer.close();

      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final fdFilestatSetSize =
          wasi.imports.functions[WasmImports.key(
            'wasi_snapshot_preview1',
            'fd_filestat_set_size',
          )]!;
      final fdClose = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_close')]!;

      expect(
        _pathOpen(
          wasi: wasi,
          memory: memory,
          path: 'resize.txt',
          rightsBase: _rightFdWrite | _rightFdFileStatSetSize,
        ),
        _errnoSuccess,
      );
      final openedFd = memory.loadI32(32);
      expect(fdFilestatSetSize([openedFd, 2]), _errnoSuccess);
      expect(fs.readFileText('/resize.txt'), 'AB');
      expect(fdFilestatSetSize([openedFd, -1]), _errnoInval);
      expect(fdFilestatSetSize([3, 1]), _errnoBadf);
      expect(fdClose([openedFd]), _errnoSuccess);

      expect(
        _pathOpen(
          wasi: wasi,
          memory: memory,
          path: 'resize-no-right.txt',
          oflags: _oflagCreat,
          rightsBase: _rightFdWrite,
          outFdPtr: 36,
        ),
        _errnoSuccess,
      );
      final noRightFd = memory.loadI32(36);
      expect(fdFilestatSetSize([noRightFd, 1]), _errnoNotcapable);
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
        followSymlinks: true,
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

    test(
      'poll_oneoff returns EFAULT for out-of-bounds input span atomically',
      () {
        final wasi = WasiPreview1();
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final pollOneoff =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'poll_oneoff',
            )]!;

        memory.storeI32(32, 91);
        memory.fillBytes(128, 0x5a, 32);

        expect(pollOneoff([65520, 128, 1, 32]), _errnoFault);
        expect(memory.loadI32(32), 91);
        expect(memory.loadU8(128), 0x5a);
      },
    );

    test(
      'poll_oneoff returns EFAULT when output span cannot hold all events atomically',
      () {
        final wasi = WasiPreview1();
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final pollOneoff =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'poll_oneoff',
            )]!;

        // sub 0: fd_write on stdout -> immediately ready
        memory.storeI64(64, 1);
        memory.storeI8(72, 2);
        memory.storeI32(80, 1);
        // sub 1: immediate clock -> immediately ready
        memory.storeI64(112, 2);
        memory.storeI8(120, 0);
        memory.storeI32(128, 1);
        memory.storeI64(136, 0);
        memory.storeI64(144, 0);
        memory.storeI16(152, 0);

        const outPtr = 65500; // first event fits, second does not.
        memory.fillBytes(outPtr, 0x44, 32);
        memory.storeI32(32, 73);

        expect(pollOneoff([64, outPtr, 2, 32]), _errnoFault);
        expect(memory.loadI32(32), 73);
        expect(memory.loadU8(outPtr), 0x44);
      },
    );

    test(
      'poll_oneoff returns EFAULT when nevents pointer is out-of-bounds atomically',
      () {
        final wasi = WasiPreview1();
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final pollOneoff =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'poll_oneoff',
            )]!;

        memory.fillBytes(128, 0x33, 32);
        memory.storeI64(64, 7);
        memory.storeI8(72, 0); // clock
        memory.storeI32(80, 1);
        memory.storeI64(88, 0);
        memory.storeI64(96, 0);
        memory.storeI16(104, 0);

        expect(pollOneoff([64, 128, 1, 65535]), _errnoFault);
        expect(memory.loadU8(128), 0x33);
      },
    );

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

    test('poll_oneoff emits EINVAL event for unsupported clock id', () {
      final wasi = WasiPreview1();
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pollOneoff = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'poll_oneoff')]!;

      memory.storeI64(64, 66);
      memory.storeI8(72, 0); // clock
      memory.storeI32(80, 99); // unsupported id
      memory.storeI64(88, 0);
      memory.storeI64(96, 0);
      memory.storeI16(104, 0);

      expect(pollOneoff([64, 128, 1, 32]), _errnoSuccess);
      expect(memory.loadI32(32), 1);
      expect(memory.loadU16(136), _errnoInval);
      expect(memory.loadU8(138), 0);
    });

    test(
      'poll_oneoff emits NOTCAPABLE event when fd_read right is missing',
      () {
        final wasi = WasiPreview1(fileSystem: WasiInMemoryFileSystem());
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final pollOneoff =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'poll_oneoff',
            )]!;

        expect(
          _pathOpen(
            wasi: wasi,
            memory: memory,
            path: 'poll-read-cap.txt',
            oflags: _oflagCreat,
            rightsBase: _rightFdWrite,
            outFdPtr: 40,
          ),
          _errnoSuccess,
        );
        final fd = memory.loadI32(40);
        memory.storeI64(64, 77);
        memory.storeI8(72, 1); // fd_read
        memory.storeI32(80, fd);

        expect(pollOneoff([64, 128, 1, 32]), _errnoSuccess);
        expect(memory.loadI32(32), 1);
        expect(memory.loadU16(136), _errnoNotcapable);
        expect(memory.loadU8(138), 1);
      },
    );

    test(
      'poll_oneoff emits NOTCAPABLE event when fd_write right is missing',
      () {
        final wasi = WasiPreview1(fileSystem: WasiInMemoryFileSystem());
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final pollOneoff =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'poll_oneoff',
            )]!;

        expect(
          _pathOpen(
            wasi: wasi,
            memory: memory,
            path: 'poll-write-cap.txt',
            oflags: _oflagCreat,
            rightsBase: _rightFdRead,
            outFdPtr: 40,
          ),
          _errnoSuccess,
        );
        final fd = memory.loadI32(40);
        memory.storeI64(64, 88);
        memory.storeI8(72, 2); // fd_write
        memory.storeI32(80, fd);

        expect(pollOneoff([64, 128, 1, 32]), _errnoSuccess);
        expect(memory.loadI32(32), 1);
        expect(memory.loadU16(136), _errnoNotcapable);
        expect(memory.loadU8(138), 2);
      },
    );

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

    test(
      'poll_oneoff preserves order across ready and error events in mixed subscriptions',
      () {
        final wasi = WasiPreview1(fileSystem: WasiInMemoryFileSystem());
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final pollOneoff =
            wasi.imports.functions[WasmImports.key(
              'wasi_snapshot_preview1',
              'poll_oneoff',
            )]!;

        expect(
          _pathOpen(
            wasi: wasi,
            memory: memory,
            path: 'poll-mixed-cap.txt',
            oflags: _oflagCreat,
            rightsBase: _rightFdRead,
            outFdPtr: 48,
          ),
          _errnoSuccess,
        );
        final fdNoWrite = memory.loadI32(48);

        // sub 0: unsupported clock id -> EINVAL event
        memory.storeI64(64, 11);
        memory.storeI8(72, 0);
        memory.storeI32(80, 99);
        memory.storeI64(88, 0);
        memory.storeI64(96, 0);
        memory.storeI16(104, 0);

        // sub 1: fd_write without RIGHT_FD_WRITE -> NOTCAPABLE event
        memory.storeI64(112, 22);
        memory.storeI8(120, 2);
        memory.storeI32(128, fdNoWrite);

        // sub 2: immediate monotonic clock -> success event
        memory.storeI64(160, 33);
        memory.storeI8(168, 0);
        memory.storeI32(176, 1);
        memory.storeI64(184, 0);
        memory.storeI64(192, 0);
        memory.storeI16(200, 0);

        expect(pollOneoff([64, 256, 3, 32]), _errnoSuccess);
        expect(memory.loadI32(32), 3);

        expect(memory.loadI64(256), BigInt.from(11));
        expect(memory.loadU16(264), _errnoInval);
        expect(memory.loadU8(266), 0);

        expect(memory.loadI64(288), BigInt.from(22));
        expect(memory.loadU16(296), _errnoNotcapable);
        expect(memory.loadU8(298), 2);

        expect(memory.loadI64(320), BigInt.from(33));
        expect(memory.loadU16(328), _errnoSuccess);
        expect(memory.loadU8(330), 0);
      },
    );

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

    test('sched_yield direct host call returns success', () {
      final wasi = WasiPreview1();
      final schedYield = _wasiFunction(wasi, 'sched_yield');
      expect(schedYield([]), _errnoSuccess);
    });

    test('sched_yield ignores extra host arguments and still succeeds', () {
      final wasi = WasiPreview1();
      final schedYield = _wasiFunction(wasi, 'sched_yield');
      expect(schedYield([1, 2, 3]), _errnoSuccess);
    });

    test('sched_yield wasm import returns success errno', () {
      final wasi = WasiPreview1();
      final wasm = _buildModule(
        types: [
          _funcType([], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(
            module: 'wasi_snapshot_preview1',
            name: 'sched_yield',
            typeIndex: 0,
          ),
        ],
        functionTypeIndices: [1],
        functionBodies: [
          _FunctionBodySpec(instructions: [..._call(0), Opcodes.end]),
        ],
        exports: const [
          _ExportSpec(name: 'run', kind: WasmExportKind.function, index: 1),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      expect(instance.invokeI32('run'), _errnoSuccess);
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
        followSymlinks: true,
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

    test(
      'path_open rejects unknown oflags and truncate without write rights',
      () {
        final fs = WasiInMemoryFileSystem();
        final seed = fs.open(
          path: '/truncate.txt',
          create: true,
          truncate: true,
          read: true,
          write: true,
          exclusive: false,
          followSymlinks: true,
        );
        seed.write(Uint8List.fromList(utf8.encode('abc')));
        seed.close();

        final wasi = WasiPreview1(fileSystem: fs);
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);

        expect(
          _pathOpen(
            wasi: wasi,
            memory: memory,
            path: 'truncate.txt',
            oflags: 0x0010,
            rightsBase: _rightFdRead,
          ),
          _errnoInval,
        );
        expect(
          _pathOpen(
            wasi: wasi,
            memory: memory,
            path: 'truncate.txt',
            oflags: _oflagTrunc,
            rightsBase: _rightFdRead,
          ),
          _errnoNotcapable,
        );
      },
    );

    test(
      'path_open and path_filestat_get respect LOOKUP_SYMLINK_FOLLOW for final component',
      () {
        final fs = WasiInMemoryFileSystem();
        final target = fs.open(
          path: '/target.txt',
          create: true,
          truncate: true,
          read: true,
          write: true,
          exclusive: false,
          followSymlinks: true,
        );
        target.write(Uint8List.fromList(utf8.encode('XYZ')));
        target.close();
        fs.symlink(targetPath: '/target.txt', linkPath: '/alias.txt');

        final wasi = WasiPreview1(fileSystem: fs);
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final fdClose = _wasiFunction(wasi, 'fd_close');
        final pathFilestatGet = _wasiFunction(wasi, 'path_filestat_get');
        final pathBytes = utf8.encode('alias.txt');
        memory.writeBytesFromList(64, pathBytes);

        expect(
          _pathOpen(
            wasi: wasi,
            memory: memory,
            path: 'alias.txt',
            rightsBase: _rightFdRead,
          ),
          _errnoLoop,
        );
        expect(
          _pathOpen(
            wasi: wasi,
            memory: memory,
            path: 'alias.txt',
            dirFlags: _lookupflagSymlinkFollow,
            rightsBase: _rightFdRead,
            outFdPtr: 36,
          ),
          _errnoSuccess,
        );
        expect(fdClose([memory.loadI32(36)]), _errnoSuccess);

        expect(
          pathFilestatGet([3, 0, 64, pathBytes.length, 128]),
          _errnoSuccess,
        );
        expect(memory.loadU8(144), _filetypeSymbolicLink);
        expect(
          memory.loadI64(160),
          BigInt.from(utf8.encode('/target.txt').length),
        );
        expect(
          pathFilestatGet([
            3,
            _lookupflagSymlinkFollow,
            64,
            pathBytes.length,
            256,
          ]),
          _errnoSuccess,
        );
        expect(memory.loadU8(272), _filetypeRegularFile);
        expect(memory.loadI64(288), BigInt.from(3));
      },
    );

    test(
      'path_filestat_set_times applies to link or target based on flags',
      () {
        final fs = WasiInMemoryFileSystem();
        final target = fs.open(
          path: '/time-target.txt',
          create: true,
          truncate: true,
          read: true,
          write: true,
          exclusive: false,
          followSymlinks: true,
        );
        target.write(Uint8List.fromList(utf8.encode('t')));
        target.close();
        fs.symlink(targetPath: '/time-target.txt', linkPath: '/time-link.txt');

        final wasi = WasiPreview1(fileSystem: fs);
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final pathFilestatGet = _wasiFunction(wasi, 'path_filestat_get');
        final pathFilestatSetTimes = _wasiFunction(
          wasi,
          'path_filestat_set_times',
        );
        final pathBytes = utf8.encode('time-link.txt');
        memory.writeBytesFromList(64, pathBytes);

        expect(
          pathFilestatSetTimes([
            3,
            0,
            64,
            pathBytes.length,
            0,
            1111,
            _fstFlagMtim,
          ]),
          _errnoSuccess,
        );
        expect(
          pathFilestatGet([3, 0, 64, pathBytes.length, 128]),
          _errnoSuccess,
        );
        expect(memory.loadI64(176), BigInt.from(1111));
        expect(
          pathFilestatGet([
            3,
            _lookupflagSymlinkFollow,
            64,
            pathBytes.length,
            256,
          ]),
          _errnoSuccess,
        );
        expect(memory.loadI64(304), isNot(BigInt.from(1111)));

        expect(
          pathFilestatSetTimes([
            3,
            _lookupflagSymlinkFollow,
            64,
            pathBytes.length,
            0,
            2222,
            _fstFlagMtim,
          ]),
          _errnoSuccess,
        );
        expect(
          pathFilestatGet([
            3,
            _lookupflagSymlinkFollow,
            64,
            pathBytes.length,
            384,
          ]),
          _errnoSuccess,
        );
        expect(memory.loadI64(432), BigInt.from(2222));
        expect(
          pathFilestatGet([3, 0, 64, pathBytes.length, 512]),
          _errnoSuccess,
        );
        expect(memory.loadI64(560), BigInt.from(1111));
      },
    );

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
        followSymlinks: true,
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

    test('path_link validates flags and respects symlink follow behavior', () {
      final fs = WasiInMemoryFileSystem();
      final source = fs.open(
        path: '/origin.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
        followSymlinks: true,
      );
      source.write(Uint8List.fromList(utf8.encode('ABCD')));
      source.close();
      fs.symlink(targetPath: '/origin.txt', linkPath: '/origin-link.txt');

      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pathLink = _wasiFunction(wasi, 'path_link');
      final pathReadlink = _wasiFunction(wasi, 'path_readlink');
      final pathFilestatGet = _wasiFunction(wasi, 'path_filestat_get');
      final sourceBytes = utf8.encode('origin-link.txt');
      final noFollowDestBytes = utf8.encode('copy-link.txt');
      final followDestBytes = utf8.encode('copy-file.txt');
      memory.writeBytesFromList(64, sourceBytes);
      memory.writeBytesFromList(96, noFollowDestBytes);
      memory.writeBytesFromList(128, followDestBytes);

      expect(
        pathLink([
          3,
          0x0002,
          64,
          sourceBytes.length,
          3,
          96,
          noFollowDestBytes.length,
        ]),
        _errnoInval,
      );
      expect(
        pathLink([
          3,
          0,
          64,
          sourceBytes.length,
          3,
          96,
          noFollowDestBytes.length,
        ]),
        _errnoSuccess,
      );
      expect(
        pathReadlink([3, 96, noFollowDestBytes.length, 256, 64, 336]),
        _errnoSuccess,
      );
      expect(memory.loadI32(336), utf8.encode('/origin.txt').length);
      expect(
        utf8.decode(memory.readBytes(256, memory.loadI32(336))),
        '/origin.txt',
      );

      expect(
        pathLink([
          3,
          _lookupflagSymlinkFollow,
          64,
          sourceBytes.length,
          3,
          128,
          followDestBytes.length,
        ]),
        _errnoSuccess,
      );
      expect(
        pathFilestatGet([3, 0, 128, followDestBytes.length, 384]),
        _errnoSuccess,
      );
      expect(memory.loadU8(400), _filetypeRegularFile);
    });

    test('path_readlink truncates output and reports nread', () {
      final fs = WasiInMemoryFileSystem();
      fs.symlink(targetPath: '/very/long/target', linkPath: '/long-link.txt');

      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pathReadlink = _wasiFunction(wasi, 'path_readlink');
      final pathBytes = utf8.encode('long-link.txt');
      memory.writeBytesFromList(64, pathBytes);

      expect(
        pathReadlink([3, 64, pathBytes.length, 128, 4, 200]),
        _errnoSuccess,
      );
      expect(memory.loadI32(200), 4);
      expect(utf8.decode(memory.readBytes(128, 4)), '/ver');
      expect(
        pathReadlink([3, 65535, pathBytes.length, 128, 4, 200]),
        _errnoFault,
      );
      expect(pathReadlink([99, 64, pathBytes.length, 128, 4, 200]), _errnoBadf);
    });

    test('path_create/remove/unlink enforce errno boundaries', () {
      final fs = WasiInMemoryFileSystem();
      fs.createDirectory('/dir');
      final file = fs.open(
        path: '/file.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
        followSymlinks: true,
      );
      file.write(Uint8List.fromList(utf8.encode('x')));
      file.close();
      final nested = fs.open(
        path: '/dir/nested.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
        followSymlinks: true,
      );
      nested.close();

      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pathCreateDirectory = _wasiFunction(wasi, 'path_create_directory');
      final pathRemoveDirectory = _wasiFunction(wasi, 'path_remove_directory');
      final pathUnlinkFile = _wasiFunction(wasi, 'path_unlink_file');
      final fdFdstatSetRights = _wasiFunction(wasi, 'fd_fdstat_set_rights');

      memory.writeBytesFromList(64, utf8.encode('tmp'));
      expect(pathCreateDirectory([3, 64, 3]), _errnoSuccess);
      expect(pathCreateDirectory([3, 64, 3]), _errnoExist);

      memory.writeBytesFromList(96, utf8.encode('dir'));
      expect(pathRemoveDirectory([3, 96, 3]), _errnoNotempty);
      memory.writeBytesFromList(128, utf8.encode('dir/nested.txt'));
      expect(pathUnlinkFile([3, 128, 14]), _errnoSuccess);
      expect(pathRemoveDirectory([3, 96, 3]), _errnoSuccess);

      memory.writeBytesFromList(160, utf8.encode('tmp'));
      expect(pathUnlinkFile([3, 160, 3]), _errnoIsdir);
      memory.writeBytesFromList(192, utf8.encode('missing.txt'));
      expect(pathUnlinkFile([3, 192, 11]), _errnoNoent);
      expect(pathRemoveDirectory([3, 192, 11]), _errnoNotdir);
      expect(pathCreateDirectory([99, 64, 3]), _errnoBadf);
      expect(pathCreateDirectory([3, 65535, 3]), _errnoFault);

      expect(fdFdstatSetRights([3, 0, 0]), _errnoSuccess);
      expect(pathCreateDirectory([3, 64, 3]), _errnoNotcapable);
    });

    test('path_rename enforces replace and type-conflict semantics', () {
      final fs = WasiInMemoryFileSystem();
      final src = fs.open(
        path: '/src.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
        followSymlinks: true,
      );
      src.write(Uint8List.fromList(utf8.encode('src')));
      src.close();
      final dst = fs.open(
        path: '/dst.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
        followSymlinks: true,
      );
      dst.write(Uint8List.fromList(utf8.encode('dst')));
      dst.close();
      fs.createDirectory('/dir-src');
      fs.createDirectory('/dir-empty');
      fs.createDirectory('/dir-nonempty');
      final nested = fs.open(
        path: '/dir-nonempty/child.txt',
        create: true,
        truncate: true,
        read: true,
        write: true,
        exclusive: false,
        followSymlinks: true,
      );
      nested.close();

      final wasi = WasiPreview1(fileSystem: fs);
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pathRename = _wasiFunction(wasi, 'path_rename');
      final fdFdstatSetRights = _wasiFunction(wasi, 'fd_fdstat_set_rights');

      memory.writeBytesFromList(64, utf8.encode('src.txt'));
      memory.writeBytesFromList(96, utf8.encode('dst.txt'));
      expect(pathRename([3, 64, 7, 3, 96, 7]), _errnoSuccess);
      expect(fs.readFileText('/dst.txt'), 'src');
      expect(fs.readFileText('/src.txt'), isNull);

      memory.writeBytesFromList(128, utf8.encode('dir-src'));
      memory.writeBytesFromList(160, utf8.encode('dir-nonempty'));
      expect(pathRename([3, 128, 7, 3, 160, 12]), _errnoNotempty);
      expect(pathRename([3, 128, 7, 3, 96, 7]), _errnoNotdir);
      expect(pathRename([3, 96, 7, 3, 160, 12]), _errnoIsdir);

      memory.writeBytesFromList(192, utf8.encode('dir-empty'));
      expect(pathRename([3, 128, 7, 3, 192, 9]), _errnoSuccess);
      expect(fs.snapshotDirectories(), contains('/dir-empty'));
      expect(fs.snapshotDirectories(), isNot(contains('/dir-src')));

      expect(pathRename([99, 64, 7, 3, 96, 7]), _errnoBadf);
      expect(pathRename([3, 65535, 7, 3, 96, 7]), _errnoFault);

      expect(fdFdstatSetRights([3, 0, 0]), _errnoSuccess);
      expect(pathRename([3, 64, 7, 3, 96, 7]), _errnoNotcapable);
    });

    test('path APIs return NOSYS when backend capability is missing', () {
      final wasi = WasiPreview1(fileSystem: _OpenOnlyFileSystem());
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final pathOpen = _wasiFunction(wasi, 'path_open');
      final pathFilestatGet = _wasiFunction(wasi, 'path_filestat_get');
      final pathCreateDirectory = _wasiFunction(wasi, 'path_create_directory');
      final pathReadlink = _wasiFunction(wasi, 'path_readlink');
      memory.writeBytesFromList(64, utf8.encode('p'));

      expect(
        pathOpen([3, 0, 64, 1, _oflagDirectory, 0, 0, 0, 32]),
        _errnoNosys,
      );
      expect(pathFilestatGet([3, 0, 64, 1, 128]), _errnoNosys);
      expect(pathCreateDirectory([3, 64, 1]), _errnoNosys);
      expect(pathReadlink([3, 64, 1, 256, 16, 300]), _errnoNosys);
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

    test('fd_renumber rejects preopened directories with NOTSUP', () {
      final wasi = WasiPreview1(fileSystem: WasiInMemoryFileSystem());
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final fdRenumber = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_renumber')]!;
      expect(fdRenumber([3, 9]), _errnoNotsup);
    });

    test('fd_close keeps preopened directories reachable', () {
      final wasi = WasiPreview1(fileSystem: WasiInMemoryFileSystem());
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final fdClose = wasi
          .imports
          .functions[WasmImports.key('wasi_snapshot_preview1', 'fd_close')]!;
      final fdPrestatGet =
          wasi.imports.functions[WasmImports.key(
            'wasi_snapshot_preview1',
            'fd_prestat_get',
          )]!;

      expect(fdClose([3]), _errnoSuccess);
      expect(fdPrestatGet([3, 40]), _errnoSuccess);
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
              expect(flags, _sockAcceptFlagNonblock);
              return WasiSockAcceptResult.accepted(allocateFd());
            },
            containsFd: ({required fd}) => fd == 4,
          ),
        );
        final wasm = _buildSockAcceptModule(
          fd: 41,
          flags: _sockAcceptFlagNonblock,
          roFdPtr: 64,
        );
        final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
        wasi.bindInstance(instance);

        expect(instance.invokeI32('run'), 0);
        final memory = instance.exportedMemory('memory');
        expect(memory.loadI32(64), 5);
      },
    );

    test('sock_accept returns ENOSYS without socket transport', () {
      final wasi = WasiPreview1();
      final sockAccept = _wasiFunction(wasi, 'sock_accept');

      expect(sockAccept([3, 0, 0]), _errnoNosys);
    });

    test('sock_accept rejects invalid flags before transport call', () {
      var called = false;
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          accept: ({required fd, required flags, required allocateFd}) {
            called = true;
            return WasiSockAcceptResult.accepted(allocateFd());
          },
        ),
      );
      final sockAccept = _wasiFunction(wasi, 'sock_accept');

      expect(sockAccept([41, 1, 0]), _errnoInval);
      expect(called, isFalse);
    });

    test('sock_accept returns EFAULT for out-of-bounds ro_fd_ptr', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          accept: ({required fd, required flags, required allocateFd}) {
            return WasiSockAcceptResult.accepted(allocateFd());
          },
        ),
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final sockAccept = _wasiFunction(wasi, 'sock_accept');

      expect(
        sockAccept([41, _sockAcceptFlagNonblock, memory.lengthInBytes - 1]),
        _errnoFault,
      );
    });

    test('sock_accept throws on conflicting accepted fd', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          accept: ({required fd, required flags, required allocateFd}) {
            return const WasiSockAcceptResult.accepted(3);
          },
        ),
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final sockAccept = _wasiFunction(wasi, 'sock_accept');

      expect(
        () => sockAccept([41, _sockAcceptFlagNonblock, 0]),
        throwsStateError,
      );
    });

    test('sock_recv copies data into iovecs and writes result metadata', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          recv: ({required fd, required flags, required maxBytes}) {
            expect(fd, 7);
            expect(flags, _sockRecvFlagPeek | _sockRecvFlagWaitall);
            expect(maxBytes, 5);
            return WasiSockRecvResult.received(
              Uint8List.fromList([1, 2, 3, 4, 5, 6]),
              flags: _sockRecvRoFlagDataTruncated,
            );
          },
        ),
      );
      final wasm = _buildSockRecvModule(
        fd: 7,
        riFlags: _sockRecvFlagPeek | _sockRecvFlagWaitall,
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
      expect(memory.loadU16(52), _sockRecvRoFlagDataTruncated);
    });

    test('sock_recv returns ENOSYS without socket transport', () {
      final wasi = WasiPreview1();
      final sockRecv = _wasiFunction(wasi, 'sock_recv');

      expect(sockRecv([7, 0, 0, 0, 4, 8]), _errnoNosys);
    });

    test('sock_recv rejects invalid flags before transport call', () {
      var called = false;
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          recv: ({required fd, required flags, required maxBytes}) {
            called = true;
            return WasiSockRecvResult.received(Uint8List(0));
          },
        ),
      );
      final sockRecv = _wasiFunction(wasi, 'sock_recv');

      expect(sockRecv([7, 0, 0, 8, 4, 8]), _errnoInval);
      expect(called, isFalse);
    });

    test('sock_recv returns EINVAL for negative iovec length', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          recv: ({required fd, required flags, required maxBytes}) {
            return WasiSockRecvResult.received(Uint8List(0));
          },
        ),
      );
      final sockRecv = _wasiFunction(wasi, 'sock_recv');

      expect(sockRecv([7, 0, -1, 0, 4, 8]), _errnoInval);
    });

    test(
      'sock_recv returns EFAULT for out-of-bounds iovec descriptor span',
      () {
        final wasi = WasiPreview1(
          socketTransport: WasiSocketTransport(
            recv: ({required fd, required flags, required maxBytes}) {
              return WasiSockRecvResult.received(Uint8List(0));
            },
          ),
        );
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final sockRecv = _wasiFunction(wasi, 'sock_recv');

        expect(
          sockRecv([7, memory.lengthInBytes - 4, 1, 0, 4, 8]),
          _errnoFault,
        );
      },
    );

    test('sock_recv returns EFAULT for out-of-bounds iovec target span', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          recv: ({required fd, required flags, required maxBytes}) {
            return WasiSockRecvResult.received(Uint8List.fromList([1]));
          },
        ),
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final sockRecv = _wasiFunction(wasi, 'sock_recv');
      _writeIoVec(
        memory: memory,
        iovPtr: 32,
        dataPtr: memory.lengthInBytes - 1,
        dataLen: 2,
      );

      expect(sockRecv([7, 32, 1, 0, 4, 8]), _errnoFault);
    });

    test('sock_recv returns EFAULT for out-of-bounds output pointers', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          recv: ({required fd, required flags, required maxBytes}) {
            return WasiSockRecvResult.received(Uint8List.fromList([1]));
          },
        ),
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final sockRecv = _wasiFunction(wasi, 'sock_recv');
      _writeIoVec(memory: memory, iovPtr: 32, dataPtr: 96, dataLen: 1);

      expect(sockRecv([7, 32, 1, 0, memory.lengthInBytes - 1, 8]), _errnoFault);
      expect(sockRecv([7, 32, 1, 0, 4, memory.lengthInBytes - 1]), _errnoFault);
    });

    test('sock_recv passes through transport errno', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          recv: ({required fd, required flags, required maxBytes}) {
            return const WasiSockRecvResult.error(_errnoBadf);
          },
        ),
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final sockRecv = _wasiFunction(wasi, 'sock_recv');
      _writeIoVec(memory: memory, iovPtr: 32, dataPtr: 96, dataLen: 1);

      expect(sockRecv([7, 32, 1, 0, 4, 8]), _errnoBadf);
    });

    test('sock_recv throws when transport returns invalid ro_flags bits', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          recv: ({required fd, required flags, required maxBytes}) {
            return WasiSockRecvResult.received(
              Uint8List.fromList([1]),
              flags: 2,
            );
          },
        ),
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final sockRecv = _wasiFunction(wasi, 'sock_recv');
      _writeIoVec(memory: memory, iovPtr: 32, dataPtr: 96, dataLen: 1);

      expect(() => sockRecv([7, 32, 1, 0, 4, 8]), throwsStateError);
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
        siFlags: 0,
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
      expect(capturedFlags, 0);
      expect(capturedData, [65, 66, 67, 68, 69]);
      expect(instance.exportedMemory('memory').loadI32(48), 3);
    });

    test('sock_send returns ENOSYS without socket transport', () {
      final wasi = WasiPreview1();
      final sockSend = _wasiFunction(wasi, 'sock_send');

      expect(sockSend([7, 0, 0, 0, 4]), _errnoNosys);
    });

    test('sock_send rejects invalid flags before transport call', () {
      var called = false;
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          send: ({required fd, required flags, required data}) {
            called = true;
            return const WasiSockSendResult.sent(0);
          },
        ),
      );
      final sockSend = _wasiFunction(wasi, 'sock_send');

      expect(sockSend([7, 0, 0, 1, 4]), _errnoInval);
      expect(called, isFalse);
    });

    test('sock_send returns EINVAL for negative iovec length', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          send: ({required fd, required flags, required data}) {
            return const WasiSockSendResult.sent(0);
          },
        ),
      );
      final sockSend = _wasiFunction(wasi, 'sock_send');

      expect(sockSend([7, 0, -1, 0, 4]), _errnoInval);
    });

    test(
      'sock_send returns EFAULT for out-of-bounds iovec descriptor span',
      () {
        final wasi = WasiPreview1(
          socketTransport: WasiSocketTransport(
            send: ({required fd, required flags, required data}) {
              return const WasiSockSendResult.sent(0);
            },
          ),
        );
        final memory = WasmMemory(minPages: 1);
        wasi.bindMemory(memory);
        final sockSend = _wasiFunction(wasi, 'sock_send');

        expect(sockSend([7, memory.lengthInBytes - 4, 1, 0, 4]), _errnoFault);
      },
    );

    test('sock_send returns EFAULT for out-of-bounds iovec source span', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          send: ({required fd, required flags, required data}) {
            return WasiSockSendResult.sent(data.length);
          },
        ),
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final sockSend = _wasiFunction(wasi, 'sock_send');
      _writeIoVec(
        memory: memory,
        iovPtr: 32,
        dataPtr: memory.lengthInBytes - 1,
        dataLen: 2,
      );

      expect(sockSend([7, 32, 1, 0, 4]), _errnoFault);
    });

    test('sock_send returns EFAULT for out-of-bounds so_datalen_ptr', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          send: ({required fd, required flags, required data}) {
            return WasiSockSendResult.sent(data.length);
          },
        ),
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final sockSend = _wasiFunction(wasi, 'sock_send');
      _writeIoVec(memory: memory, iovPtr: 32, dataPtr: 96, dataLen: 1);
      memory.storeI8(96, 42);

      expect(sockSend([7, 32, 1, 0, memory.lengthInBytes - 1]), _errnoFault);
    });

    test('sock_send passes through transport errno', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          send: ({required fd, required flags, required data}) {
            return const WasiSockSendResult.error(_errnoBadf);
          },
        ),
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final sockSend = _wasiFunction(wasi, 'sock_send');
      _writeIoVec(memory: memory, iovPtr: 32, dataPtr: 96, dataLen: 1);
      memory.storeI8(96, 42);

      expect(sockSend([7, 32, 1, 0, 4]), _errnoBadf);
    });

    test('sock_send throws when transport reports invalid bytesWritten', () {
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          send: ({required fd, required flags, required data}) {
            return WasiSockSendResult.sent(data.length + 1);
          },
        ),
      );
      final memory = WasmMemory(minPages: 1);
      wasi.bindMemory(memory);
      final sockSend = _wasiFunction(wasi, 'sock_send');
      _writeIoVec(memory: memory, iovPtr: 32, dataPtr: 96, dataLen: 1);
      memory.storeI8(96, 42);

      expect(() => sockSend([7, 32, 1, 0, 4]), throwsStateError);
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

    test('sock_shutdown returns ENOSYS without socket transport', () {
      final wasi = WasiPreview1();
      final sockShutdown = _wasiFunction(wasi, 'sock_shutdown');

      expect(sockShutdown([7, 0]), _errnoNosys);
    });

    test('sock_shutdown rejects invalid how before transport call', () {
      var called = false;
      final wasi = WasiPreview1(
        socketTransport: WasiSocketTransport(
          shutdown: ({required fd, required how}) {
            called = true;
            return 0;
          },
        ),
      );
      final sockShutdown = _wasiFunction(wasi, 'sock_shutdown');

      expect(sockShutdown([7, 99]), _errnoInval);
      expect(called, isFalse);
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

    test('proc_raise direct host call returns ENOSYS', () {
      final wasi = WasiPreview1();
      final procRaise = _wasiFunction(wasi, 'proc_raise');

      expect(procRaise([15]), _errnoNosys);
    });

    test(
      'proc_raise direct host call keeps StateError contract for missing/invalid args',
      () {
        final wasi = WasiPreview1();
        final procRaise = _wasiFunction(wasi, 'proc_raise');

        expect(() => procRaise([]), throwsStateError);
        expect(() => procRaise(['bad']), throwsStateError);
      },
    );

    test('proc_raise wasm import returns ENOSYS', () {
      final wasi = WasiPreview1();
      final wasm = _buildProcRaiseModule(signal: 9);
      final instance = WasmInstance.fromBytes(wasm, imports: wasi.imports);
      expect(instance.invokeI32('run'), _errnoNosys);
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

Object? Function(List<Object?>) _wasiFunction(WasiPreview1 wasi, String name) {
  return wasi.imports.functions[WasmImports.key(
    'wasi_snapshot_preview1',
    name,
  )]!;
}

void _writeIoVec({
  required WasmMemory memory,
  required int iovPtr,
  required int dataPtr,
  required int dataLen,
}) {
  memory.storeI32(iovPtr, dataPtr);
  memory.storeI32(iovPtr + 4, dataLen);
}

int _pathOpen({
  required WasiPreview1 wasi,
  required WasmMemory memory,
  required String path,
  int dirFd = 3,
  int dirFlags = 0,
  int oflags = 0,
  required int rightsBase,
  int rightsInheriting = 0,
  int fdFlags = 0,
  int pathPtr = 64,
  int outFdPtr = 32,
}) {
  final pathOpen = _wasiFunction(wasi, 'path_open');
  final pathBytes = utf8.encode(path);
  memory.writeBytesFromList(pathPtr, pathBytes);
  final errno = pathOpen([
    dirFd,
    dirFlags,
    pathPtr,
    pathBytes.length,
    oflags,
    rightsBase,
    rightsInheriting,
    fdFlags,
    outFdPtr,
  ]);
  return errno as int;
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

final class _OpenOnlyFileSystem implements WasiFileSystem {
  @override
  WasiFileDescriptor open({
    required String path,
    required bool create,
    required bool truncate,
    required bool read,
    required bool write,
    required bool exclusive,
    required bool followSymlinks,
  }) {
    throw const WasiFsException(WasiFsError.notSupported);
  }
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
