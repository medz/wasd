import 'dart:convert';
import 'dart:typed_data';

import 'package:wasd/wasd.dart';
import 'package:test/test.dart';

void main() {
  group('wasd', () {
    test('executes exported add(i32, i32) -> i32', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f], [0x7f]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(name: 'add', kind: WasmExportKind.function, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('add', [20, 22]), 42);
    });

    test('supports block/loop/br_if control flow', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            locals: const [_LocalDeclSpec(1, 0x7f)],
            instructions: [
              Opcodes.block,
              0x40,
              Opcodes.loop,
              0x40,
              ..._localGet(0),
              Opcodes.i32Eqz,
              ..._brIf(1),
              ..._localGet(1),
              ..._localGet(0),
              Opcodes.i32Add,
              ..._localSet(1),
              ..._localGet(0),
              ..._i32Const(1),
              Opcodes.i32Sub,
              ..._localSet(0),
              ..._br(0),
              Opcodes.end,
              Opcodes.end,
              ..._localGet(1),
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(
            name: 'sum_to_n',
            kind: WasmExportKind.function,
            index: 0,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('sum_to_n', [5]), 15);
      expect(instance.invokeI32('sum_to_n', [10]), 55);
    });

    test('loop branch does not consume loop result arity', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              Opcodes.loop,
              0x7f,
              ..._localGet(0),
              Opcodes.i32Eqz,
              Opcodes.if_,
              0x40,
              ..._localGet(0),
              Opcodes.return_,
              Opcodes.end,
              ..._localGet(0),
              ..._i32Const(1),
              Opcodes.i32Sub,
              ..._localSet(0),
              ..._br(0),
              Opcodes.end,
              ..._i32Const(-1),
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(
            name: 'countdown',
            kind: WasmExportKind.function,
            index: 0,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('countdown', [0]), 0);
      expect(instance.invokeI32('countdown', [5]), 0);
    });

    test('runs start function and supports global.get/global.set', () {
      final wasm = _buildModule(
        types: [
          _funcType([], []),
          _funcType([], [0x7f]),
        ],
        functionTypeIndices: [0, 1],
        globals: [
          _GlobalSpec(
            valueType: 0x7f,
            mutable: true,
            initExpr: [..._i32Const(0), Opcodes.end],
          ),
        ],
        startFunctionIndex: 0,
        functionBodies: [
          _FunctionBodySpec(
            instructions: [..._i32Const(42), ..._globalSet(0), Opcodes.end],
          ),
          _FunctionBodySpec(instructions: [..._globalGet(0), Opcodes.end]),
        ],
        exports: [
          _ExportSpec(name: 'get', kind: WasmExportKind.function, index: 1),
          _ExportSpec(name: 'g', kind: WasmExportKind.global, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('get'), 42);
      expect(instance.readGlobalI32('g'), 42);
      instance.writeGlobal('g', 9);
      expect(instance.invokeI32('get'), 9);
    });

    test('initializes active data segments', () {
      final wasm = _buildModule(
        types: [
          _funcType([], [0x7f]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              Opcodes.i32Load,
              ..._u32Leb(2),
              ..._u32Leb(0),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(0), Opcodes.end],
            bytes: [0x78, 0x56, 0x34, 0x12],
          ),
        ],
        exports: [
          _ExportSpec(name: 'load0', kind: WasmExportKind.function, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('load0'), 0x12345678);
    });

    test('supports imported host function', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f], [0x7f]),
        ],
        imports: [
          _ImportFunctionSpec(module: 'env', name: 'plus', typeIndex: 0),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              ..._call(0),
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(
            name: 'use_plus',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final imports = WasmImports(
        functions: {
          WasmImports.key('env', 'plus'): (args) {
            final lhs = args[0] as int;
            final rhs = args[1] as int;
            return lhs + rhs;
          },
        },
      );

      final instance = WasmInstance.fromBytes(wasm, imports: imports);
      expect(instance.invokeI32('use_plus', [4, 5]), 9);
    });

    test('accepts passive data segments', () {
      final wasm = _buildModule(
        types: [
          _funcType([], [0x7f]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(instructions: [..._i32Const(7), Opcodes.end]),
        ],
        dataSegments: [
          const _DataSegmentSpec.passive(bytes: [1, 2, 3, 4]),
        ],
        exports: [
          _ExportSpec(name: 'const7', kind: WasmExportKind.function, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('const7'), 7);
    });

    test('supports memory.size and memory.grow', () {
      final wasm = _buildModule(
        types: [
          _funcType([], [0x7f]),
        ],
        functionTypeIndices: [0, 0],
        functionBodies: [
          _FunctionBodySpec(instructions: [..._memorySize(), Opcodes.end]),
          _FunctionBodySpec(
            instructions: [..._i32Const(1), ..._memoryGrow(), Opcodes.end],
          ),
        ],
        memoryMinPages: 1,
        exports: [
          _ExportSpec(name: 'size', kind: WasmExportKind.function, index: 0),
          _ExportSpec(name: 'grow', kind: WasmExportKind.function, index: 1),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('size'), 1);
      expect(instance.invokeI32('grow'), 1);
      expect(instance.invokeI32('size'), 2);
    });

    test('supports table/element + call_indirect', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([0x7f, 0x7f, 0x7f], [0x7f]),
        ],
        functionTypeIndices: [0, 0, 1],
        tables: const [_TableSpec(refType: 0x70, min: 2, max: 2)],
        elements: [
          _ElementSegmentSpec.active(
            tableIndex: 0,
            offsetExpr: [..._i32Const(0), Opcodes.end],
            functionIndices: [0, 1],
          ),
        ],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              Opcodes.i32Mul,
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(1),
              ..._localGet(2),
              ..._localGet(0),
              ..._callIndirect(0, 0),
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(
            name: 'dispatch',
            kind: WasmExportKind.function,
            index: 2,
          ),
          _ExportSpec(name: 'table0', kind: WasmExportKind.table, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('dispatch', [0, 3, 4]), 7);
      expect(instance.invokeI32('dispatch', [1, 3, 4]), 12);
      expect(instance.exportedTable('table0').snapshot(), [0, 1]);
    });

    test('accepts passive element segments', () {
      final wasm = _buildModule(
        types: [
          _funcType([], [0x7f]),
        ],
        functionTypeIndices: [0],
        tables: const [_TableSpec(refType: 0x70, min: 1)],
        elements: [
          const _ElementSegmentSpec.passive(functionIndices: [0]),
        ],
        functionBodies: [
          _FunctionBodySpec(instructions: [..._i32Const(1), Opcodes.end]),
        ],
        exports: [
          _ExportSpec(name: 'one', kind: WasmExportKind.function, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('one'), 1);
    });

    test('supports i64 arithmetic', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7e, 0x7e], [0x7e]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              Opcodes.i64Add,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(name: 'add64', kind: WasmExportKind.function, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI64('add64', [9_000_000_000, 5]), 9_000_000_005);
    });

    test('supports f64 arithmetic', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7c, 0x7c], [0x7c]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              Opcodes.f64Mul,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(name: 'mul64', kind: WasmExportKind.function, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeF64('mul64', [2.5, 4.0]), closeTo(10.0, 1e-12));
    });

    test('supports multi-value function returns', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f], [0x7f, 0x7f]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [..._localGet(0), ..._localGet(1), Opcodes.end],
          ),
        ],
        exports: [
          _ExportSpec(name: 'pair', kind: WasmExportKind.function, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeMulti('pair', [7, 11]), [7, 11]);
    });

    test('matches Wasm signed remainder semantics for i32/i64', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f], [0x7f]),
          _funcType([0x7e, 0x7e], [0x7e]),
        ],
        functionTypeIndices: [0, 1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              Opcodes.i32RemS,
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              Opcodes.i64RemS,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(name: 'rem32', kind: WasmExportKind.function, index: 0),
          _ExportSpec(name: 'rem64', kind: WasmExportKind.function, index: 1),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('rem32', [-5, 2]), -1);
      expect(instance.invokeI64('rem64', [-9, 4]), -1);
    });

    test('supports load/store instruction variants', () {
      final wasm = _buildModule(
        types: [
          _funcType([], [0x7f]),
          _funcType([], [0x7f]),
          _funcType([], [0x7e]),
          _funcType([], [0x7c]),
        ],
        functionTypeIndices: [0, 1, 2, 3],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._i32Const(-1),
              ..._memInstr(Opcodes.i32Store8),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load8S),
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._i32Const(0xff80),
              ..._memInstr(Opcodes.i32Store16),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load16U),
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._i32Const(-1),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i64Load32U),
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._f64Const(3.5),
              ..._memInstr(Opcodes.f64Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.f64Load),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: [
          _ExportSpec(name: 'load8s', kind: WasmExportKind.function, index: 0),
          _ExportSpec(name: 'load16u', kind: WasmExportKind.function, index: 1),
          _ExportSpec(
            name: 'load32u64',
            kind: WasmExportKind.function,
            index: 2,
          ),
          _ExportSpec(name: 'loadF64', kind: WasmExportKind.function, index: 3),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('load8s'), -1);
      expect(instance.invokeI32('load16u'), 65408);
      expect(instance.invokeI64('load32u64'), 4294967295);
      expect(instance.invokeF64('loadF64'), closeTo(3.5, 1e-12));
    });

    test('supports bulk memory operations and data.drop', () {
      final wasm = _buildModule(
        types: [
          _funcType([], [0x7f]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._i32Const(0),
              ..._i32Const(4),
              ..._fc2(Opcodes.memoryInit, 0, 0),
              ..._fc1(Opcodes.dataDrop, 0),
              ..._i32Const(8),
              ..._i32Const(0),
              ..._i32Const(4),
              ..._fc2(Opcodes.memoryCopy, 0, 0),
              ..._i32Const(12),
              ..._i32Const(9),
              ..._i32Const(2),
              ..._fc1(Opcodes.memoryFill, 0),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load8U),
              ..._i32Const(1),
              ..._memInstr(Opcodes.i32Load8U),
              Opcodes.i32Add,
              ..._i32Const(2),
              ..._memInstr(Opcodes.i32Load8U),
              Opcodes.i32Add,
              ..._i32Const(3),
              ..._memInstr(Opcodes.i32Load8U),
              Opcodes.i32Add,
              ..._i32Const(8),
              ..._memInstr(Opcodes.i32Load8U),
              Opcodes.i32Add,
              ..._i32Const(9),
              ..._memInstr(Opcodes.i32Load8U),
              Opcodes.i32Add,
              ..._i32Const(10),
              ..._memInstr(Opcodes.i32Load8U),
              Opcodes.i32Add,
              ..._i32Const(11),
              ..._memInstr(Opcodes.i32Load8U),
              Opcodes.i32Add,
              ..._i32Const(12),
              ..._memInstr(Opcodes.i32Load8U),
              Opcodes.i32Add,
              ..._i32Const(13),
              ..._memInstr(Opcodes.i32Load8U),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataCount: 1,
        dataSegments: [
          const _DataSegmentSpec.passive(bytes: [1, 2, 3, 4]),
        ],
        exports: [
          _ExportSpec(name: 'bulk', kind: WasmExportKind.function, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('bulk'), 38);
      expect(() => instance.invokeI32('bulk'), throwsA(isA<StateError>()));
    });

    test('supports table bulk operations and elem.drop', () {
      final wasm = _buildModule(
        types: [
          _funcType([], [0x7f]),
        ],
        functionTypeIndices: [0, 0, 0, 0],
        tables: const [_TableSpec(refType: 0x70, min: 6, max: 8)],
        elements: [
          const _ElementSegmentSpec.passive(functionIndices: [0, 1]),
          const _ElementSegmentSpec.passive(functionIndices: [2]),
        ],
        functionBodies: [
          _FunctionBodySpec(instructions: [..._i32Const(10), Opcodes.end]),
          _FunctionBodySpec(instructions: [..._i32Const(20), Opcodes.end]),
          _FunctionBodySpec(instructions: [..._i32Const(30), Opcodes.end]),
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._i32Const(0),
              ..._i32Const(2),
              ..._fc2(Opcodes.tableInit, 0, 0),
              ..._fc1(Opcodes.elemDrop, 0),
              ..._i32Const(3),
              ..._i32Const(0),
              ..._i32Const(2),
              ..._fc2(Opcodes.tableCopy, 0, 0),
              Opcodes.refNull,
              0x70,
              ..._i32Const(1),
              ..._fc1(Opcodes.tableGrow, 0),
              Opcodes.drop,
              ..._i32Const(5),
              Opcodes.refFunc,
              ..._u32Leb(2),
              ..._i32Const(1),
              ..._fc1(Opcodes.tableFill, 0),
              ..._fc1(Opcodes.tableSize, 0),
              ..._i32Const(4),
              ..._callIndirect(0, 0),
              Opcodes.i32Add,
              ..._i32Const(5),
              ..._callIndirect(0, 0),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(
            name: 'tableOps',
            kind: WasmExportKind.function,
            index: 3,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('tableOps'), 57);
      expect(() => instance.invokeI32('tableOps'), throwsA(isA<StateError>()));
    });

    test('decodes custom sections and data_count section', () {
      final base = _buildModule(
        types: [
          _funcType([], [0x7f]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(instructions: [..._i32Const(7), Opcodes.end]),
        ],
        exports: [
          _ExportSpec(name: 'seven', kind: WasmExportKind.function, index: 0),
        ],
      );

      final withSections = Uint8List.fromList([
        ...base.sublist(0, 8),
        ..._section(0, [..._name('test'), 0x01, 0x02]),
        ..._section(12, _u32Leb(0)),
        ...base.sublist(8),
      ]);

      final instance = WasmInstance.fromBytes(withSections);
      expect(instance.invokeI32('seven'), 7);

      final badDataCount = Uint8List.fromList([
        ...base.sublist(0, 8),
        ..._section(12, _u32Leb(1)),
        ...base.sublist(8),
      ]);
      expect(
        () => WasmInstance.fromBytes(badDataCount),
        throwsA(isA<FormatException>()),
      );
    });

    test('supports return_call opcode', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7e, 0x7e], [0x7e]),
          _funcType([0x7e], [0x7e]),
        ],
        functionTypeIndices: [0, 1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              Opcodes.i64Eqz,
              Opcodes.if_,
              0x7e,
              ..._localGet(1),
              Opcodes.else_,
              ..._localGet(0),
              ..._i64Const(1),
              Opcodes.i64Sub,
              ..._localGet(1),
              ..._localGet(0),
              Opcodes.i64Add,
              Opcodes.returnCall,
              ..._u32Leb(0),
              Opcodes.end,
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._i64Const(0),
              ..._call(0),
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(name: 'sum', kind: WasmExportKind.function, index: 1),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI64('sum', [100]), 5050);
    });

    test('supports typed select instruction encoding', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f], [0x7f]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              ..._localGet(2),
              Opcodes.selectT,
              ..._u32Leb(1),
              0x7f,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(name: 'pick', kind: WasmExportKind.function, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeI32('pick', [11, 22, 1]), 11);
      expect(instance.invokeI32('pick', [11, 22, 0]), 22);
    });

    test('validation rejects invalid branch depth before execution', () {
      final wasm = _buildModule(
        types: [_funcType([], [])],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(instructions: [..._br(0), Opcodes.end]),
        ],
      );

      expect(
        () => WasmInstance.fromBytes(wasm),
        throwsA(isA<FormatException>()),
      );
    });

    test('validation rejects invalid call index before execution', () {
      final wasm = _buildModule(
        types: [_funcType([], [])],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [..._call(9), Opcodes.drop, Opcodes.end],
          ),
        ],
      );

      expect(
        () => WasmInstance.fromBytes(wasm),
        throwsA(isA<FormatException>()),
      );
    });

    test('validation rejects non-void start function signature', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], []),
        ],
        functionTypeIndices: [0],
        startFunctionIndex: 0,
        functionBodies: [
          _FunctionBodySpec(
            instructions: [..._localGet(0), Opcodes.drop, Opcodes.end],
          ),
        ],
      );

      expect(
        () => WasmInstance.fromBytes(wasm),
        throwsA(isA<FormatException>()),
      );
    });

    test('proposal feature gate reports SIMD opcode usage', () {
      final wasm = _buildModule(
        types: [_funcType([], [])],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(instructions: [0xfd, 0x00, Opcodes.end]),
        ],
      );

      expect(
        () => WasmInstance.fromBytes(wasm),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => WasmInstance.fromBytes(
          wasm,
          features: const WasmFeatureSet(simd: true),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('supports async invoke wrappers', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f], [0x7f]),
        ],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(name: 'add', kind: WasmExportKind.function, index: 0),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(await instance.invokeI32Async('add', [40, 2]), 42);
      expect(await instance.invokeMultiAsync('add', [1, 2]), [3]);
    });

    test('supports layered feature defaults and extension query', () {
      final features = WasmFeatureSet.layeredDefaults(
        profile: WasmFeatureProfile.stable,
        additionalEnabled: const {'memory64'},
        additionalDisabled: const {'exception_handling'},
      );

      expect(features.simd, isTrue);
      expect(features.exceptionHandling, isFalse);
      expect(features.isEnabled('memory64'), isTrue);
      expect(features.isEnabled('threads'), isFalse);
    });
  });
}

final class _FunctionBodySpec {
  const _FunctionBodySpec({this.locals = const [], required this.instructions});

  final List<_LocalDeclSpec> locals;
  final List<int> instructions;
}

final class _LocalDeclSpec {
  const _LocalDeclSpec(this.count, this.valueType);

  final int count;
  final int valueType;
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

final class _TableSpec {
  const _TableSpec({required this.refType, required this.min, this.max});

  final int refType;
  final int min;
  final int? max;
}

final class _GlobalSpec {
  const _GlobalSpec({
    required this.valueType,
    required this.mutable,
    required this.initExpr,
  });

  final int valueType;
  final bool mutable;
  final List<int> initExpr;
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

final class _DataSegmentSpec {
  const _DataSegmentSpec.active({
    required this.memoryIndex,
    required this.offsetExpr,
    required this.bytes,
  }) : isPassive = false;

  const _DataSegmentSpec.passive({required this.bytes})
    : isPassive = true,
      memoryIndex = 0,
      offsetExpr = null;

  final bool isPassive;
  final int memoryIndex;
  final List<int>? offsetExpr;
  final List<int> bytes;
}

final class _ElementSegmentSpec {
  const _ElementSegmentSpec.active({
    required this.tableIndex,
    required this.offsetExpr,
    required this.functionIndices,
  }) : mode = WasmElementMode.active;

  const _ElementSegmentSpec.passive({required this.functionIndices})
    : mode = WasmElementMode.passive,
      tableIndex = 0,
      offsetExpr = null;

  final WasmElementMode mode;
  final int tableIndex;
  final List<int>? offsetExpr;
  final List<int?> functionIndices;
}

Uint8List _buildModule({
  required List<List<int>> types,
  required List<int> functionTypeIndices,
  required List<_FunctionBodySpec> functionBodies,
  List<_ImportFunctionSpec> imports = const [],
  List<_TableSpec> tables = const [],
  List<_GlobalSpec> globals = const [],
  List<_ExportSpec> exports = const [],
  List<_ElementSegmentSpec> elements = const [],
  List<_DataSegmentSpec> dataSegments = const [],
  int? dataCount,
  int? memoryMinPages,
  int? memoryMaxPages,
  int? startFunctionIndex,
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

  if (tables.isNotEmpty) {
    final payload = <int>[..._u32Leb(tables.length)];
    for (final table in tables) {
      payload
        ..add(table.refType)
        ..addAll(_limits(table.min, table.max));
    }
    bytes.addAll(_section(4, payload));
  }

  if (memoryMinPages != null) {
    bytes.addAll(
      _section(5, <int>[
        ..._u32Leb(1),
        ..._limits(memoryMinPages, memoryMaxPages),
      ]),
    );
  }

  if (globals.isNotEmpty) {
    final payload = <int>[..._u32Leb(globals.length)];
    for (final global in globals) {
      payload
        ..add(global.valueType)
        ..add(global.mutable ? 1 : 0)
        ..addAll(global.initExpr);
    }
    bytes.addAll(_section(6, payload));
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

  if (startFunctionIndex != null) {
    bytes.addAll(_section(8, _u32Leb(startFunctionIndex)));
  }

  if (elements.isNotEmpty) {
    final payload = <int>[..._u32Leb(elements.length)];
    for (final element in elements) {
      switch (element.mode) {
        case WasmElementMode.active:
          if (element.tableIndex == 0) {
            payload
              ..addAll(_u32Leb(0))
              ..addAll(element.offsetExpr!)
              ..addAll(_u32Leb(element.functionIndices.length))
              ..addAll(
                element.functionIndices
                    .map((index) => _u32Leb(index!))
                    .expand((it) => it),
              );
          } else {
            payload
              ..addAll(_u32Leb(2))
              ..addAll(_u32Leb(element.tableIndex))
              ..addAll(element.offsetExpr!)
              ..add(0x00)
              ..addAll(_u32Leb(element.functionIndices.length))
              ..addAll(
                element.functionIndices
                    .map((index) => _u32Leb(index!))
                    .expand((it) => it),
              );
          }

        case WasmElementMode.passive:
          payload
            ..addAll(_u32Leb(1))
            ..add(0x00)
            ..addAll(_u32Leb(element.functionIndices.length))
            ..addAll(
              element.functionIndices
                  .map((index) => _u32Leb(index!))
                  .expand((it) => it),
            );

        case WasmElementMode.declarative:
          payload
            ..addAll(_u32Leb(3))
            ..add(0x00)
            ..addAll(_u32Leb(element.functionIndices.length))
            ..addAll(
              element.functionIndices
                  .map((index) => _u32Leb(index!))
                  .expand((it) => it),
            );
      }
    }
    bytes.addAll(_section(9, payload));
  }

  final codePayload = <int>[..._u32Leb(functionBodies.length)];
  for (final body in functionBodies) {
    if (body.instructions.isEmpty || body.instructions.last != Opcodes.end) {
      throw ArgumentError('Function body must end with Opcodes.end.');
    }

    final localDecls = <int>[..._u32Leb(body.locals.length)];
    for (final local in body.locals) {
      localDecls
        ..addAll(_u32Leb(local.count))
        ..add(local.valueType);
    }

    final functionBody = <int>[...localDecls, ...body.instructions];
    codePayload
      ..addAll(_u32Leb(functionBody.length))
      ..addAll(functionBody);
  }
  bytes.addAll(_section(10, codePayload));

  if (dataCount != null) {
    bytes.addAll(_section(12, _u32Leb(dataCount)));
  }

  if (dataSegments.isNotEmpty) {
    final payload = <int>[..._u32Leb(dataSegments.length)];
    for (final data in dataSegments) {
      if (data.isPassive) {
        payload
          ..addAll(_u32Leb(1))
          ..addAll(_u32Leb(data.bytes.length))
          ..addAll(data.bytes);
      } else {
        if (data.memoryIndex == 0) {
          payload
            ..addAll(_u32Leb(0))
            ..addAll(data.offsetExpr!)
            ..addAll(_u32Leb(data.bytes.length))
            ..addAll(data.bytes);
        } else {
          payload
            ..addAll(_u32Leb(2))
            ..addAll(_u32Leb(data.memoryIndex))
            ..addAll(data.offsetExpr!)
            ..addAll(_u32Leb(data.bytes.length))
            ..addAll(data.bytes);
        }
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

List<int> _localGet(int index) => <int>[Opcodes.localGet, ..._u32Leb(index)];
List<int> _localSet(int index) => <int>[Opcodes.localSet, ..._u32Leb(index)];
List<int> _globalGet(int index) => <int>[Opcodes.globalGet, ..._u32Leb(index)];
List<int> _globalSet(int index) => <int>[Opcodes.globalSet, ..._u32Leb(index)];
List<int> _call(int index) => <int>[Opcodes.call, ..._u32Leb(index)];
List<int> _callIndirect(int typeIndex, int tableIndex) => <int>[
  Opcodes.callIndirect,
  ..._u32Leb(typeIndex),
  ..._u32Leb(tableIndex),
];
List<int> _br(int depth) => <int>[Opcodes.br, ..._u32Leb(depth)];
List<int> _brIf(int depth) => <int>[Opcodes.brIf, ..._u32Leb(depth)];
List<int> _memorySize() => <int>[Opcodes.memorySize, ..._u32Leb(0)];
List<int> _memoryGrow() => <int>[Opcodes.memoryGrow, ..._u32Leb(0)];
List<int> _i32Const(int value) => <int>[Opcodes.i32Const, ..._i32Leb(value)];
List<int> _i64Const(int value) => <int>[Opcodes.i64Const, ..._i64Leb(value)];
List<int> _f64Const(double value) => <int>[
  Opcodes.f64Const,
  ...(() {
    final data = ByteData(8);
    data.setFloat64(0, value, Endian.little);
    return data.buffer.asUint8List();
  })(),
];
List<int> _memInstr(int opcode, {int align = 0, int offset = 0}) => <int>[
  opcode,
  ..._u32Leb(align),
  ..._u32Leb(offset),
];
List<int> _fc1(int pseudoOpcode, int immediate) => <int>[
  0xfc,
  ..._u32Leb(pseudoOpcode & 0xff),
  ..._u32Leb(immediate),
];
List<int> _fc2(int pseudoOpcode, int immediate0, int immediate1) => <int>[
  0xfc,
  ..._u32Leb(pseudoOpcode & 0xff),
  ..._u32Leb(immediate0),
  ..._u32Leb(immediate1),
];

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
