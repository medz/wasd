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
      final snapshot = instance.exportedTable('table0').snapshot();
      expect(snapshot, hasLength(2));
      expect(snapshot[0], isNotNull);
      expect(snapshot[1], isNotNull);
      expect(snapshot[0], isNot(equals(snapshot[1])));
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
        dataCount: 0,
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

    test('supports legacy try/catch with tag matching', () {
      final wasm = _buildModule(
        types: [
          _funcType([], []),
          _funcType([], [0x7f]),
        ],
        tagTypeIndices: const [0],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.throwTag,
              ..._u32Leb(0),
              ..._i32Const(0),
              Opcodes.catchTag,
              ..._u32Leb(0),
              ..._i32Const(23),
              Opcodes.end,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(
            name: 'legacyCatch',
            kind: WasmExportKind.function,
            index: 0,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(exceptionHandling: true),
      );
      expect(instance.invokeI32('legacyCatch'), 23);
    });

    test('legacy try skips catch handlers on normal flow', () {
      final wasm = _buildModule(
        types: [
          _funcType([], [0x7f]),
        ],
        functionTypeIndices: const [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              Opcodes.tryLegacy,
              0x7f,
              ..._i32Const(5),
              Opcodes.catchAll,
              ..._i32Const(99),
              Opcodes.end,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(
            name: 'normalFlow',
            kind: WasmExportKind.function,
            index: 0,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(exceptionHandling: true),
      );
      expect(instance.invokeI32('normalFlow'), 5);
    });

    test('supports legacy rethrow from catch blocks', () {
      final wasm = _buildModule(
        types: [
          _funcType([], []),
          _funcType([], [0x7f]),
        ],
        tagTypeIndices: const [0],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.throwTag,
              ..._u32Leb(0),
              ..._i32Const(0),
              Opcodes.catchTag,
              ..._u32Leb(0),
              Opcodes.rethrowTag,
              ..._u32Leb(0),
              Opcodes.end,
              Opcodes.catchAll,
              ..._i32Const(99),
              Opcodes.end,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(
            name: 'legacyRethrow',
            kind: WasmExportKind.function,
            index: 0,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(exceptionHandling: true),
      );
      expect(instance.invokeI32('legacyRethrow'), 99);
    });

    test('supports legacy delegate to outer handlers', () {
      final wasm = _buildModule(
        types: [
          _funcType([], []),
          _funcType([], [0x7f]),
        ],
        tagTypeIndices: const [0],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.throwTag,
              ..._u32Leb(0),
              ..._i32Const(0),
              Opcodes.delegate,
              ..._u32Leb(0),
              Opcodes.catchAll,
              ..._i32Const(7),
              Opcodes.end,
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(
            name: 'legacyDelegate',
            kind: WasmExportKind.function,
            index: 0,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(exceptionHandling: true),
      );
      expect(instance.invokeI32('legacyDelegate'), 7);
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

    test('supports i64 wide-arithmetic proposal opcodes', () {
      final wasm = _buildModule(
        types: [
          _funcType([0x7e, 0x7e, 0x7e, 0x7e], [0x7e, 0x7e]),
          _funcType([0x7e, 0x7e], [0x7e, 0x7e]),
        ],
        functionTypeIndices: [0, 0, 1, 1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              ..._localGet(2),
              ..._localGet(3),
              ..._fc0(Opcodes.i64Add128),
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              ..._localGet(2),
              ..._localGet(3),
              ..._fc0(Opcodes.i64Sub128),
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              ..._fc0(Opcodes.i64MulWideS),
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._localGet(1),
              ..._fc0(Opcodes.i64MulWideU),
              Opcodes.end,
            ],
          ),
        ],
        exports: [
          _ExportSpec(name: 'add128', kind: WasmExportKind.function, index: 0),
          _ExportSpec(name: 'sub128', kind: WasmExportKind.function, index: 1),
          _ExportSpec(
            name: 'mulWideS',
            kind: WasmExportKind.function,
            index: 2,
          ),
          _ExportSpec(
            name: 'mulWideU',
            kind: WasmExportKind.function,
            index: 3,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(wasm);
      expect(instance.invokeMulti('add128', [0, 1, 1, 0]), [1, 1]);
      expect(instance.invokeMulti('sub128', [0, 0, 1, 1]), [-1, -2]);
      expect(instance.invokeMulti('mulWideS', [-1, 1]), [-1, -1]);
      expect(instance.invokeMulti('mulWideU', [-1, 1]), [-1, 0]);
    });

    test('validation rejects invalid branch depth before execution', () {
      final wasm = _buildModule(
        types: [_funcType([], [])],
        functionTypeIndices: [0],
        functionBodies: [
          _FunctionBodySpec(instructions: [..._br(1), Opcodes.end]),
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
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              0xfd,
              0x0f, // i8x16.splat
              Opcodes.drop,
              Opcodes.end,
            ],
          ),
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
        returnsNormally,
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

    test(
      'supports async-only imported host functions via invokeAsync',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [],
          functionBodies: const [],
          exports: const [
            _ExportSpec(name: 'inc', kind: WasmExportKind.function, index: 0),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async {
                await Future<void>.delayed(Duration.zero);
                return (args.single as int) + 1;
              },
            },
          ),
        );

        expect(await instance.invokeI32Async('inc', [41]), 42);
        expect(
          () => instance.invokeI32('inc', [41]),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains('Async-only host import'),
            ),
          ),
        );
      },
    );

    test(
      'supports async import call chains for subset-compatible wrappers',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [0],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._memorySize(),
                Opcodes.drop,
                ..._localGet(0),
                ..._i32Const(1),
                Opcodes.i32And,
                Opcodes.if_,
                0x7f,
                ..._localGet(0),
                ..._call(0),
                Opcodes.else_,
                ..._i32Const(0),
                Opcodes.end,
                Opcodes.end,
              ],
            ),
          ],
          memoryMinPages: 1,
          exports: const [
            _ExportSpec(name: 'wrap', kind: WasmExportKind.function, index: 1),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrap', [41]), 42);
        expect(await instance.invokeI32Async('wrap', [0]), 0);
      },
    );

    test('supports memory load/store in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._localGet(0),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(0),
              ..._memInstr(Opcodes.i32Load),
              ..._call(0),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(name: 'wrapMem', kind: WasmExportKind.function, index: 1),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapMem', [41]), 42);
    });

    test(
      'supports memory.copy and memory.fill in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [0],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._call(0),
                Opcodes.drop,

                ..._i32Const(0),
                ..._i32Const(0x11),
                ..._i32Const(4),
                ..._fc1(Opcodes.memoryFill, 0),

                ..._i32Const(8),
                ..._i32Const(0x22),
                ..._memInstr(Opcodes.i32Store8),
                ..._i32Const(9),
                ..._i32Const(0x33),
                ..._memInstr(Opcodes.i32Store8),

                ..._i32Const(1),
                ..._i32Const(8),
                ..._i32Const(2),
                ..._fc2(Opcodes.memoryCopy, 0, 0),

                ..._i32Const(0),
                ..._i32Const(0),
                ..._memInstr(Opcodes.i32Load8U),
                ..._i32Const(0x11),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._i32Const(1),
                ..._memInstr(Opcodes.i32Load8U),
                ..._i32Const(0x22),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._i32Const(2),
                ..._memInstr(Opcodes.i32Load8U),
                ..._i32Const(0x33),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._i32Const(3),
                ..._memInstr(Opcodes.i32Load8U),
                ..._i32Const(0x11),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                Opcodes.end,
              ],
            ),
          ],
          memoryMinPages: 1,
          exports: const [
            _ExportSpec(
              name: 'wrapMemBulk',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapMemBulk', [41]), 4);
      },
    );

    test(
      'supports memory.init and data.drop in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [0],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._call(0),
                Opcodes.drop,

                ..._i32Const(0),
                ..._i32Const(0),
                ..._i32Const(4),
                ..._fc2(Opcodes.memoryInit, 0, 0),
                ..._fc1(Opcodes.dataDrop, 0),

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
                Opcodes.end,
              ],
            ),
          ],
          memoryMinPages: 1,
          dataCount: 1,
          dataSegments: [
            const _DataSegmentSpec.passive(bytes: [1, 2, 3, 4]),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapMemInit',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapMemInit', [41]), 10);
        await expectLater(
          () async => instance.invokeI32Async('wrapMemInit', [41]),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'supports table bulk operations in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
            _funcType([], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [1, 1, 1, 1],
          tables: const [_TableSpec(refType: 0x70, min: 6, max: 8)],
          elements: [
            const _ElementSegmentSpec.passive(functionIndices: [1, 2]),
            const _ElementSegmentSpec.passive(functionIndices: [3]),
          ],
          functionBodies: [
            _FunctionBodySpec(instructions: [..._i32Const(10), Opcodes.end]),
            _FunctionBodySpec(instructions: [..._i32Const(20), Opcodes.end]),
            _FunctionBodySpec(instructions: [..._i32Const(30), Opcodes.end]),
            _FunctionBodySpec(
              instructions: [
                ..._i32Const(0),
                ..._call(0),
                Opcodes.drop,
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
                ..._u32Leb(3),
                ..._i32Const(1),
                ..._fc1(Opcodes.tableFill, 0),
                ..._fc1(Opcodes.tableSize, 0),
                ..._i32Const(4),
                ..._callIndirect(1, 0),
                Opcodes.i32Add,
                ..._i32Const(5),
                ..._callIndirect(1, 0),
                Opcodes.i32Add,
                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapTableOps',
              kind: WasmExportKind.function,
              index: 4,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapTableOps'), 57);
        await expectLater(
          () async => instance.invokeI32Async('wrapTableOps'),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'supports table.get/table.set and ref ops in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
            _funcType([], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [1, 1],
          tables: const [_TableSpec(refType: 0x70, min: 2)],
          functionBodies: [
            _FunctionBodySpec(instructions: [..._i32Const(7), Opcodes.end]),
            _FunctionBodySpec(
              instructions: [
                ..._i32Const(0),
                ..._call(0),
                Opcodes.drop,

                ..._i32Const(0),
                Opcodes.refFunc,
                ..._u32Leb(1),
                ..._tableSet(0),

                ..._i32Const(0),
                ..._tableGet(0),
                Opcodes.refAsNonNull,
                Opcodes.refIsNull,
                Opcodes.i32Eqz,

                ..._i32Const(1),
                Opcodes.refNull,
                0x70,
                ..._tableSet(0),
                ..._i32Const(1),
                ..._tableGet(0),
                Opcodes.refIsNull,
                Opcodes.i32Add,
                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'targetRefTable',
              kind: WasmExportKind.function,
              index: 1,
            ),
            _ExportSpec(
              name: 'wrapRefTable',
              kind: WasmExportKind.function,
              index: 2,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapRefTable'), 2);
      },
    );

    test('supports call_ref in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [1, 1],
        functionBodies: [
          _FunctionBodySpec(instructions: [..._i32Const(13), Opcodes.end]),
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              Opcodes.refFunc,
              ..._u32Leb(1),
              Opcodes.callRef,
              ..._u32Leb(1),
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'targetCallRef',
            kind: WasmExportKind.function,
            index: 1,
          ),
          _ExportSpec(
            name: 'wrapCallRef',
            kind: WasmExportKind.function,
            index: 2,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapCallRef'), 13);
    });

    test('supports return_call_ref in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [1, 1],
        functionBodies: [
          _FunctionBodySpec(instructions: [..._i32Const(9), Opcodes.end]),
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              Opcodes.refFunc,
              ..._u32Leb(1),
              Opcodes.returnCallRef,
              ..._u32Leb(1),
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'targetReturnCallRef',
            kind: WasmExportKind.function,
            index: 1,
          ),
          _ExportSpec(
            name: 'wrapReturnCallRef',
            kind: WasmExportKind.function,
            index: 2,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapReturnCallRef'), 9);
    });

    test('supports legacy try/catch in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([], []),
          _funcType([], [0x7f]),
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 2),
        ],
        tagTypeIndices: const [0],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.throwTag,
              ..._u32Leb(0),
              Opcodes.catchTag,
              ..._u32Leb(0),
              ..._i32Const(23),
              Opcodes.end,
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'wrapLegacyCatch',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(exceptionHandling: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapLegacyCatch'), 23);
    });

    test('supports legacy rethrow in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([], []),
          _funcType([], [0x7f]),
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 2),
        ],
        tagTypeIndices: const [0],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.throwTag,
              ..._u32Leb(0),
              Opcodes.catchTag,
              ..._u32Leb(0),
              Opcodes.rethrowTag,
              ..._u32Leb(0),
              Opcodes.end,
              Opcodes.catchAll,
              ..._i32Const(99),
              Opcodes.end,
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'wrapLegacyRethrow',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(exceptionHandling: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapLegacyRethrow'), 99);
    });

    test('supports legacy delegate in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([], []),
          _funcType([], [0x7f]),
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 2),
        ],
        tagTypeIndices: const [0],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.throwTag,
              ..._u32Leb(0),
              Opcodes.delegate,
              ..._u32Leb(0),
              Opcodes.catchAll,
              ..._i32Const(7),
              Opcodes.end,
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'wrapLegacyDelegate',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(exceptionHandling: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapLegacyDelegate'), 7);
    });

    test(
      'supports try_table catch_ref + throw_ref in async call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([], []),
            _funcType([], [0x7f]),
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 2),
          ],
          tagTypeIndices: const [0],
          functionTypeIndices: const [1],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._i32Const(0),
                ..._call(0),
                Opcodes.drop,
                Opcodes.tryLegacy,
                0x7f,
                Opcodes.block,
                0x64, // (ref non-null exn)
                0x74,
                Opcodes.tryTable,
                0x64, // (ref non-null exn)
                0x74,
                ..._u32Leb(1),
                0x01, // catch_ref
                ..._u32Leb(0), // tag index
                ..._u32Leb(0), // label depth
                Opcodes.throwTag,
                ..._u32Leb(0),
                Opcodes.unreachable,
                Opcodes.end, // end try_table
                Opcodes.end, // end block
                Opcodes.throwRef,
                Opcodes.catchAll,
                ..._i32Const(77),
                Opcodes.end, // end try_legacy
                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapTryTableThrowRef',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          features: const WasmFeatureSet(exceptionHandling: true),
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapTryTableThrowRef'), 77);
      },
    );

    test('supports try_table catch_tag in async call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([], []),
          _funcType([], [0x7f]),
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 2),
        ],
        tagTypeIndices: const [0],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              Opcodes.block,
              0x40,
              Opcodes.tryTable,
              0x40,
              ..._u32Leb(1),
              0x00, // catch_tag
              ..._u32Leb(0), // tag index
              ..._u32Leb(0), // label depth
              Opcodes.throwTag,
              ..._u32Leb(0),
              Opcodes.unreachable,
              Opcodes.end,
              Opcodes.end,
              ..._i32Const(11),
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'wrapTryTableCatchTag',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(exceptionHandling: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapTryTableCatchTag'), 11);
    });

    test('supports try_table catch_all in async call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([], []),
          _funcType([], [0x7f]),
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 2),
        ],
        tagTypeIndices: const [0],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              Opcodes.block,
              0x40,
              Opcodes.tryTable,
              0x40,
              ..._u32Leb(1),
              0x02, // catch_all
              ..._u32Leb(0), // label depth
              Opcodes.throwTag,
              ..._u32Leb(0),
              Opcodes.unreachable,
              Opcodes.end,
              Opcodes.end,
              ..._i32Const(22),
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'wrapTryTableCatchAll',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(exceptionHandling: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapTryTableCatchAll'), 22);
    });

    test('supports try_table catch_all_ref in async call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([], []),
          _funcType([], [0x7f]),
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 2),
        ],
        tagTypeIndices: const [0],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              Opcodes.tryLegacy,
              0x7f,
              Opcodes.block,
              0x64,
              0x74,
              Opcodes.tryTable,
              0x64,
              0x74,
              ..._u32Leb(1),
              0x03, // catch_all_ref
              ..._u32Leb(0), // label depth
              Opcodes.throwTag,
              ..._u32Leb(0),
              Opcodes.unreachable,
              Opcodes.end,
              Opcodes.end,
              Opcodes.throwRef,
              Opcodes.catchAll,
              ..._i32Const(55),
              Opcodes.end,
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'wrapTryTableCatchAllRef',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(exceptionHandling: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapTryTableCatchAllRef'), 55);
    });

    test('supports atomic.fence in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              ..._fe0(Opcodes.atomicFence),
              ..._i32Const(7),
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'wrapAtomicFence',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(threads: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapAtomicFence'), 7);
    });

    test(
      'supports memory.atomic.notify/wait32 in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
            _funcType([], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [1],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._i32Const(0),
                ..._call(0),
                Opcodes.drop,
                ..._i32Const(0),
                ..._i32Const(7),
                ..._memInstr(Opcodes.i32Store, align: 2),
                ..._i32Const(0),
                ..._i32Const(8),
                ..._i64Const(0),
                ..._feMem(Opcodes.memoryAtomicWait32, align: 2),
                ..._i32Const(0),
                ..._i32Const(7),
                ..._i64Const(0),
                ..._feMem(Opcodes.memoryAtomicWait32, align: 2),
                Opcodes.i32Add,
                ..._i32Const(0),
                ..._i32Const(1),
                ..._feMem(Opcodes.memoryAtomicNotify, align: 2),
                Opcodes.i32Add,
                Opcodes.end,
              ],
            ),
          ],
          memoryMinPages: 1,
          exports: const [
            _ExportSpec(
              name: 'wrapAtomicWaitNotify32',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          features: const WasmFeatureSet(threads: true),
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapAtomicWaitNotify32'), 3);
      },
    );

    test('supports memory.atomic.wait64 in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(8),
              ..._i64Const(42),
              ..._memInstr(Opcodes.i64Store, align: 3),
              ..._i32Const(8),
              ..._i64Const(41),
              ..._i64Const(0),
              ..._feMem(Opcodes.memoryAtomicWait64, align: 3),
              ..._i32Const(8),
              ..._i64Const(42),
              ..._i64Const(0),
              ..._feMem(Opcodes.memoryAtomicWait64, align: 3),
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(
            name: 'wrapAtomicWait64',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(threads: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapAtomicWait64'), 3);
    });

    test('traps unaligned atomic wait32 in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(2),
              ..._i32Const(0),
              ..._i64Const(0),
              ..._feMem(Opcodes.memoryAtomicWait32, align: 2),
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(
            name: 'wrapAtomicWait32Unaligned',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(threads: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      await expectLater(
        () async => instance.invokeI32Async('wrapAtomicWait32Unaligned'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unaligned atomic'),
          ),
        ),
      );
    });

    test(
      'supports atomic load/store opcodes in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
            _funcType([], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [1],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._i32Const(0),
                ..._call(0),
                Opcodes.drop,
                ..._i32Const(0),
                ..._i32Const(0x10203040),
                ..._feMem(Opcodes.i32AtomicStore, align: 2),
                ..._i32Const(0),
                ..._feMem(Opcodes.i32AtomicLoad, align: 2),
                ..._i32Const(0x10203040),
                Opcodes.i32Eq,
                ..._i32Const(4),
                ..._i32Const(0xAB),
                ..._feMem(Opcodes.i32AtomicStore8, align: 0),
                ..._i32Const(4),
                ..._feMem(Opcodes.i32AtomicLoad8U, align: 0),
                ..._i32Const(0xAB),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(6),
                ..._i32Const(0xCDEF),
                ..._feMem(Opcodes.i32AtomicStore16, align: 1),
                ..._i32Const(6),
                ..._feMem(Opcodes.i32AtomicLoad16U, align: 1),
                ..._i32Const(0xCDEF),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(8),
                ..._i64Const(305419896),
                ..._feMem(Opcodes.i64AtomicStore, align: 3),
                ..._i32Const(8),
                ..._feMem(Opcodes.i64AtomicLoad, align: 3),
                ..._i64Const(305419896),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(16),
                ..._i64Const(254),
                ..._feMem(Opcodes.i64AtomicStore8, align: 0),
                ..._i32Const(16),
                ..._feMem(Opcodes.i64AtomicLoad8U, align: 0),
                ..._i64Const(254),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(18),
                ..._i64Const(0xBEEF),
                ..._feMem(Opcodes.i64AtomicStore16, align: 1),
                ..._i32Const(18),
                ..._feMem(Opcodes.i64AtomicLoad16U, align: 1),
                ..._i64Const(0xBEEF),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(20),
                ..._i64Const(0x89ABCDEF),
                ..._feMem(Opcodes.i64AtomicStore32, align: 2),
                ..._i32Const(20),
                ..._feMem(Opcodes.i64AtomicLoad32U, align: 2),
                ..._i64Const(0x89ABCDEF),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                Opcodes.end,
              ],
            ),
          ],
          memoryMinPages: 1,
          exports: const [
            _ExportSpec(
              name: 'wrapAtomicLoadStore',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          features: const WasmFeatureSet(threads: true),
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapAtomicLoadStore'), 7);
      },
    );

    test('supports atomic rmw opcodes in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
          _funcType([], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._i32Const(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(0),

              ..._i32Const(0),
              ..._i32Const(10),
              ..._memInstr(Opcodes.i32Store, align: 2),
              ..._i32Const(16),
              ..._i32Const(0x00ff00ff),
              ..._memInstr(Opcodes.i32Store, align: 2),
              ..._i32Const(40),
              ..._i64Const(1000),
              ..._memInstr(Opcodes.i64Store, align: 3),
              ..._i32Const(56),
              ..._i32Const(0x1234),
              ..._memInstr(Opcodes.i32Store, align: 2),
              ..._i32Const(60),
              ..._i32Const(0x12345678),
              ..._memInstr(Opcodes.i32Store, align: 2),
              ..._i32Const(64),
              ..._i64Const(170),
              ..._memInstr(Opcodes.i64Store, align: 3),

              ..._i32Const(0),
              ..._i32Const(5),
              ..._feMem(Opcodes.i32AtomicRmwAdd, align: 2),
              ..._i32Const(10),
              Opcodes.i32Eq,
              Opcodes.i32Add,
              ..._i32Const(0),
              ..._feMem(Opcodes.i32AtomicLoad, align: 2),
              ..._i32Const(15),
              Opcodes.i32Eq,
              Opcodes.i32Add,

              ..._i32Const(0),
              ..._i32Const(3),
              ..._feMem(Opcodes.i32AtomicRmwSub, align: 2),
              ..._i32Const(15),
              Opcodes.i32Eq,
              Opcodes.i32Add,
              ..._i32Const(0),
              ..._feMem(Opcodes.i32AtomicLoad, align: 2),
              ..._i32Const(12),
              Opcodes.i32Eq,
              Opcodes.i32Add,

              ..._i32Const(16),
              ..._i32Const(0x0f0f0f0f),
              ..._feMem(Opcodes.i32AtomicRmwAnd, align: 2),
              ..._i32Const(0x00ff00ff),
              Opcodes.i32Eq,
              Opcodes.i32Add,
              ..._i32Const(16),
              ..._feMem(Opcodes.i32AtomicLoad, align: 2),
              ..._i32Const(0x000f000f),
              Opcodes.i32Eq,
              Opcodes.i32Add,

              ..._i32Const(16),
              ..._i32Const(0x00f000f0),
              ..._feMem(Opcodes.i32AtomicRmwOr, align: 2),
              ..._i32Const(0x000f000f),
              Opcodes.i32Eq,
              Opcodes.i32Add,
              ..._i32Const(16),
              ..._feMem(Opcodes.i32AtomicLoad, align: 2),
              ..._i32Const(0x00ff00ff),
              Opcodes.i32Eq,
              Opcodes.i32Add,

              ..._i32Const(16),
              ..._i32Const(0x00ff00ff),
              ..._feMem(Opcodes.i32AtomicRmwXor, align: 2),
              ..._i32Const(0x00ff00ff),
              Opcodes.i32Eq,
              Opcodes.i32Add,
              ..._i32Const(16),
              ..._feMem(Opcodes.i32AtomicLoad, align: 2),
              ..._i32Const(0),
              Opcodes.i32Eq,
              Opcodes.i32Add,

              ..._i32Const(0),
              ..._i32Const(77),
              ..._feMem(Opcodes.i32AtomicRmwXchg, align: 2),
              ..._i32Const(12),
              Opcodes.i32Eq,
              Opcodes.i32Add,
              ..._i32Const(0),
              ..._feMem(Opcodes.i32AtomicLoad, align: 2),
              ..._i32Const(77),
              Opcodes.i32Eq,
              Opcodes.i32Add,

              ..._i32Const(40),
              ..._i64Const(24),
              ..._feMem(Opcodes.i64AtomicRmwAdd, align: 3),
              ..._i64Const(1000),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._i32Const(40),
              ..._feMem(Opcodes.i64AtomicLoad, align: 3),
              ..._i64Const(1024),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              ..._i32Const(40),
              ..._i64Const(4),
              ..._feMem(Opcodes.i64AtomicRmwSub, align: 3),
              ..._i64Const(1024),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._i32Const(40),
              ..._feMem(Opcodes.i64AtomicLoad, align: 3),
              ..._i64Const(1020),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              ..._i32Const(40),
              ..._i64Const(255),
              ..._feMem(Opcodes.i64AtomicRmwAnd, align: 3),
              ..._i64Const(1020),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._i32Const(40),
              ..._feMem(Opcodes.i64AtomicLoad, align: 3),
              ..._i64Const(252),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              ..._i32Const(40),
              ..._i64Const(256),
              ..._feMem(Opcodes.i64AtomicRmwOr, align: 3),
              ..._i64Const(252),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._i32Const(40),
              ..._feMem(Opcodes.i64AtomicLoad, align: 3),
              ..._i64Const(508),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              ..._i32Const(40),
              ..._i64Const(15),
              ..._feMem(Opcodes.i64AtomicRmwXor, align: 3),
              ..._i64Const(508),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._i32Const(40),
              ..._feMem(Opcodes.i64AtomicLoad, align: 3),
              ..._i64Const(499),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              ..._i32Const(40),
              ..._i64Const(123),
              ..._feMem(Opcodes.i64AtomicRmwXchg, align: 3),
              ..._i64Const(499),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._i32Const(40),
              ..._feMem(Opcodes.i64AtomicLoad, align: 3),
              ..._i64Const(123),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              ..._i32Const(56),
              ..._i32Const(1),
              ..._feMem(Opcodes.i32AtomicRmw8AddU, align: 0),
              ..._i32Const(0x34),
              Opcodes.i32Eq,
              Opcodes.i32Add,
              ..._i32Const(56),
              ..._feMem(Opcodes.i32AtomicLoad8U, align: 0),
              ..._i32Const(0x35),
              Opcodes.i32Eq,
              Opcodes.i32Add,

              ..._i32Const(56),
              ..._i32Const(0x00ff),
              ..._feMem(Opcodes.i32AtomicRmw16XorU, align: 1),
              ..._i32Const(0x1235),
              Opcodes.i32Eq,
              Opcodes.i32Add,
              ..._i32Const(56),
              ..._feMem(Opcodes.i32AtomicLoad16U, align: 1),
              ..._i32Const(0x12ca),
              Opcodes.i32Eq,
              Opcodes.i32Add,

              ..._i32Const(60),
              ..._i64Const(0x0000ffff),
              ..._feMem(Opcodes.i64AtomicRmw32XorU, align: 2),
              ..._i64Const(0x12345678),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._i32Const(60),
              ..._feMem(Opcodes.i64AtomicLoad32U, align: 2),
              ..._i64Const(0x1234a987),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              ..._i32Const(64),
              ..._i64Const(1),
              ..._feMem(Opcodes.i64AtomicRmw8AddU, align: 0),
              ..._i64Const(170),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._i32Const(64),
              ..._feMem(Opcodes.i64AtomicLoad8U, align: 0),
              ..._i64Const(171),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        exports: const [
          _ExportSpec(
            name: 'wrapAtomicRmw',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(threads: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapAtomicRmw'), 32);
    });

    test(
      'supports atomic cmpxchg opcodes in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
            _funcType([], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [1],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._i32Const(0),
                ..._call(0),
                Opcodes.drop,
                ..._i32Const(0),

                ..._i32Const(0),
                ..._i32Const(5),
                ..._memInstr(Opcodes.i32Store, align: 2),
                ..._i32Const(8),
                ..._i32Const(0x1234),
                ..._memInstr(Opcodes.i32Store, align: 2),
                ..._i32Const(16),
                ..._i64Const(9),
                ..._memInstr(Opcodes.i64Store, align: 3),
                ..._i32Const(24),
                ..._i32Const(0x7f),
                ..._memInstr(Opcodes.i32Store, align: 2),
                ..._i32Const(28),
                ..._i32Const(0x1234),
                ..._memInstr(Opcodes.i32Store, align: 2),
                ..._i32Const(32),
                ..._i32Const(0x12345678),
                ..._memInstr(Opcodes.i32Store, align: 2),

                ..._i32Const(0),
                ..._i32Const(4),
                ..._i32Const(8),
                ..._feMem(Opcodes.i32AtomicRmwCmpxchg, align: 2),
                ..._i32Const(5),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(0),
                ..._feMem(Opcodes.i32AtomicLoad, align: 2),
                ..._i32Const(5),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._i32Const(0),
                ..._i32Const(5),
                ..._i32Const(8),
                ..._feMem(Opcodes.i32AtomicRmwCmpxchg, align: 2),
                ..._i32Const(5),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(0),
                ..._feMem(Opcodes.i32AtomicLoad, align: 2),
                ..._i32Const(8),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._i32Const(8),
                ..._i32Const(0x35),
                ..._i32Const(0xaa),
                ..._feMem(Opcodes.i32AtomicRmw8CmpxchgU, align: 0),
                ..._i32Const(0x34),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(8),
                ..._feMem(Opcodes.i32AtomicLoad8U, align: 0),
                ..._i32Const(0x34),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._i32Const(8),
                ..._i32Const(0x34),
                ..._i32Const(0xaa),
                ..._feMem(Opcodes.i32AtomicRmw8CmpxchgU, align: 0),
                ..._i32Const(0x34),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(8),
                ..._feMem(Opcodes.i32AtomicLoad8U, align: 0),
                ..._i32Const(0xaa),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._i32Const(8),
                ..._i32Const(0x1234),
                ..._i32Const(0xbeef),
                ..._feMem(Opcodes.i32AtomicRmw16CmpxchgU, align: 1),
                ..._i32Const(0x12aa),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(8),
                ..._feMem(Opcodes.i32AtomicLoad16U, align: 1),
                ..._i32Const(0x12aa),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._i32Const(8),
                ..._i32Const(0x12aa),
                ..._i32Const(0xbeef),
                ..._feMem(Opcodes.i32AtomicRmw16CmpxchgU, align: 1),
                ..._i32Const(0x12aa),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(8),
                ..._feMem(Opcodes.i32AtomicLoad16U, align: 1),
                ..._i32Const(0xbeef),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._i32Const(16),
                ..._i64Const(8),
                ..._i64Const(12),
                ..._feMem(Opcodes.i64AtomicRmwCmpxchg, align: 3),
                ..._i64Const(9),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(16),
                ..._feMem(Opcodes.i64AtomicLoad, align: 3),
                ..._i64Const(9),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                ..._i32Const(16),
                ..._i64Const(9),
                ..._i64Const(12),
                ..._feMem(Opcodes.i64AtomicRmwCmpxchg, align: 3),
                ..._i64Const(9),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(16),
                ..._feMem(Opcodes.i64AtomicLoad, align: 3),
                ..._i64Const(12),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                ..._i32Const(24),
                ..._i64Const(0x7e),
                ..._i64Const(0x55),
                ..._feMem(Opcodes.i64AtomicRmw8CmpxchgU, align: 0),
                ..._i64Const(0x7f),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(24),
                ..._feMem(Opcodes.i64AtomicLoad8U, align: 0),
                ..._i64Const(0x7f),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                ..._i32Const(24),
                ..._i64Const(0x7f),
                ..._i64Const(0x55),
                ..._feMem(Opcodes.i64AtomicRmw8CmpxchgU, align: 0),
                ..._i64Const(0x7f),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(24),
                ..._feMem(Opcodes.i64AtomicLoad8U, align: 0),
                ..._i64Const(0x55),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                ..._i32Const(28),
                ..._i64Const(0x1235),
                ..._i64Const(0x0f0f),
                ..._feMem(Opcodes.i64AtomicRmw16CmpxchgU, align: 1),
                ..._i64Const(0x1234),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(28),
                ..._feMem(Opcodes.i64AtomicLoad16U, align: 1),
                ..._i64Const(0x1234),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                ..._i32Const(28),
                ..._i64Const(0x1234),
                ..._i64Const(0x0f0f),
                ..._feMem(Opcodes.i64AtomicRmw16CmpxchgU, align: 1),
                ..._i64Const(0x1234),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(28),
                ..._feMem(Opcodes.i64AtomicLoad16U, align: 1),
                ..._i64Const(0x0f0f),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                ..._i32Const(32),
                ..._i64Const(0x12345679),
                ..._i64Const(0x89abcdef),
                ..._feMem(Opcodes.i64AtomicRmw32CmpxchgU, align: 2),
                ..._i64Const(0x12345678),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(32),
                ..._feMem(Opcodes.i64AtomicLoad32U, align: 2),
                ..._i64Const(0x12345678),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                ..._i32Const(32),
                ..._i64Const(0x12345678),
                ..._i64Const(0x89abcdef),
                ..._feMem(Opcodes.i64AtomicRmw32CmpxchgU, align: 2),
                ..._i64Const(0x12345678),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i32Const(32),
                ..._feMem(Opcodes.i64AtomicLoad32U, align: 2),
                ..._i64Const(0x89abcdef),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                Opcodes.end,
              ],
            ),
          ],
          memoryMinPages: 1,
          exports: const [
            _ExportSpec(
              name: 'wrapAtomicCmpxchg',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          features: const WasmFeatureSet(threads: true),
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapAtomicCmpxchg'), 28);
      },
    );

    test(
      'supports br_on_null and br_on_non_null in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
            _funcType([], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [1],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._i32Const(0),
                ..._call(0),
                Opcodes.drop,
                ..._i32Const(0),

                Opcodes.block,
                0x70,
                Opcodes.refFunc,
                ..._u32Leb(1),
                Opcodes.refNull,
                0x70,
                ..._brOnNull(0),
                Opcodes.drop,
                Opcodes.end,
                Opcodes.drop,
                ..._i32Const(1),
                Opcodes.i32Add,

                Opcodes.block,
                0x70,
                Opcodes.refFunc,
                ..._u32Leb(1),
                ..._brOnNonNull(0),
                Opcodes.refNull,
                0x70,
                Opcodes.end,
                Opcodes.drop,
                ..._i32Const(2),
                Opcodes.i32Add,

                Opcodes.block,
                0x70,
                Opcodes.refNull,
                0x70,
                Opcodes.refFunc,
                ..._u32Leb(1),
                ..._brOnNull(0),
                Opcodes.drop,
                Opcodes.end,
                Opcodes.drop,
                ..._i32Const(4),
                Opcodes.i32Add,

                Opcodes.block,
                0x70,
                Opcodes.refFunc,
                ..._u32Leb(1),
                Opcodes.refNull,
                0x70,
                ..._brOnNonNull(0),
                Opcodes.end,
                Opcodes.drop,
                ..._i32Const(8),
                Opcodes.i32Add,

                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapBrOnNullNonNull',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapBrOnNullNonNull'), 15);
      },
    );

    test(
      'supports i64 wide-arithmetic proposal opcodes in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
            _funcType([0x7e, 0x7e, 0x7e, 0x7e], [0x7e, 0x7e]),
            _funcType([0x7e, 0x7e], [0x7e, 0x7e]),
            _funcType([], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [1, 1, 2, 2, 3],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._localGet(1),
                ..._localGet(2),
                ..._localGet(3),
                ..._fc0(Opcodes.i64Add128),
                Opcodes.end,
              ],
            ),
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._localGet(1),
                ..._localGet(2),
                ..._localGet(3),
                ..._fc0(Opcodes.i64Sub128),
                Opcodes.end,
              ],
            ),
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._localGet(1),
                ..._fc0(Opcodes.i64MulWideS),
                Opcodes.end,
              ],
            ),
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._localGet(1),
                ..._fc0(Opcodes.i64MulWideU),
                Opcodes.end,
              ],
            ),
            _FunctionBodySpec(
              locals: const [_LocalDeclSpec(1, 0x7f)],
              instructions: [
                ..._i32Const(0),
                ..._call(0),
                Opcodes.drop,
                ..._i32Const(0),
                ..._localSet(0),

                ..._i64Const(0),
                ..._i64Const(1),
                ..._i64Const(1),
                ..._i64Const(0),
                ..._call(1),
                ..._i64Const(1),
                Opcodes.i64Eq,
                ..._localGet(0),
                Opcodes.i32Add,
                ..._localSet(0),
                ..._i64Const(1),
                Opcodes.i64Eq,
                ..._localGet(0),
                Opcodes.i32Add,
                ..._localSet(0),

                ..._i64Const(0),
                ..._i64Const(0),
                ..._i64Const(1),
                ..._i64Const(1),
                ..._call(2),
                ..._i64Const(-2),
                Opcodes.i64Eq,
                ..._localGet(0),
                Opcodes.i32Add,
                ..._localSet(0),
                ..._i64Const(-1),
                Opcodes.i64Eq,
                ..._localGet(0),
                Opcodes.i32Add,
                ..._localSet(0),

                ..._i64Const(-1),
                ..._i64Const(1),
                ..._call(3),
                ..._i64Const(-1),
                Opcodes.i64Eq,
                ..._localGet(0),
                Opcodes.i32Add,
                ..._localSet(0),
                ..._i64Const(-1),
                Opcodes.i64Eq,
                ..._localGet(0),
                Opcodes.i32Add,
                ..._localSet(0),

                ..._i64Const(-1),
                ..._i64Const(1),
                ..._call(4),
                ..._i64Const(0),
                Opcodes.i64Eq,
                ..._localGet(0),
                Opcodes.i32Add,
                ..._localSet(0),
                ..._i64Const(-1),
                Opcodes.i64Eq,
                ..._localGet(0),
                Opcodes.i32Add,
                ..._localSet(0),

                ..._localGet(0),
                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapI64WideOps',
              kind: WasmExportKind.function,
              index: 5,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapI64WideOps'), 8);
      },
    );

    test('supports i32 bitwise opcodes in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._call(0),
              Opcodes.i32Popcnt,
              ..._i32Const(1),
              Opcodes.i32Shl,
              ..._i32Const(1),
              Opcodes.i32ShrU,
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'wrapBits',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      // 41 -> inc => 42 (0b101010), popcnt=3.
      expect(await instance.invokeI32Async('wrapBits', [41]), 3);
    });

    test(
      'supports i32 compare/div/rem opcodes in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [0],
          functionBodies: [
            _FunctionBodySpec(
              locals: const [_LocalDeclSpec(1, 0x7f)],
              instructions: [
                ..._localGet(0),
                ..._call(0),
                ..._localSet(1),
                ..._i32Const(0),

                ..._localGet(1),
                ..._i32Const(100),
                Opcodes.i32LtS,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(100),
                Opcodes.i32LtU,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(0),
                Opcodes.i32GtS,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(0),
                Opcodes.i32GtU,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(42),
                Opcodes.i32LeS,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(42),
                Opcodes.i32LeU,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(42),
                Opcodes.i32GeS,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(42),
                Opcodes.i32GeU,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(43),
                Opcodes.i32Ne,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._localGet(1),
                ..._i32Const(2),
                Opcodes.i32DivS,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(5),
                Opcodes.i32DivU,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(5),
                Opcodes.i32RemS,
                Opcodes.i32Add,
                ..._localGet(1),
                ..._i32Const(5),
                Opcodes.i32RemU,
                Opcodes.i32Add,
                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapCmpDiv',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapCmpDiv', [41]), 43);
      },
    );

    test('supports i64 integer opcodes in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7e], [0x7e]),
          _funcType([0x7e], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc64', typeIndex: 0),
        ],
        functionTypeIndices: const [1],
        functionBodies: [
          _FunctionBodySpec(
            locals: const [_LocalDeclSpec(1, 0x7e)],
            instructions: [
              ..._localGet(0),
              ..._call(0),
              ..._localSet(1),
              ..._i32Const(0),

              ..._localGet(1),
              Opcodes.i64Clz,
              ..._i64Const(60),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              Opcodes.i64Ctz,
              ..._i64Const(1),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              Opcodes.i64Popcnt,
              ..._i64Const(2),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              ..._localGet(1),
              ..._i64Const(6),
              Opcodes.i64And,
              ..._i64Const(2),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(5),
              Opcodes.i64Or,
              ..._i64Const(15),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(3),
              Opcodes.i64Xor,
              ..._i64Const(9),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(1),
              Opcodes.i64Shl,
              ..._i64Const(20),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(1),
              Opcodes.i64ShrS,
              ..._i64Const(5),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(1),
              Opcodes.i64ShrU,
              ..._i64Const(5),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(1),
              Opcodes.i64Rotl,
              ..._i64Const(20),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(1),
              Opcodes.i64Rotr,
              ..._i64Const(5),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              ..._localGet(1),
              ..._i64Const(3),
              Opcodes.i64DivS,
              ..._i64Const(3),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(3),
              Opcodes.i64DivU,
              ..._i64Const(3),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(3),
              Opcodes.i64RemS,
              ..._i64Const(1),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(3),
              Opcodes.i64RemU,
              ..._i64Const(1),
              Opcodes.i64Eq,
              Opcodes.i32Add,

              ..._localGet(1),
              ..._i64Const(10),
              Opcodes.i64Eq,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(11),
              Opcodes.i64Ne,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(11),
              Opcodes.i64LtS,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(11),
              Opcodes.i64LtU,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(9),
              Opcodes.i64GtS,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(9),
              Opcodes.i64GtU,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(10),
              Opcodes.i64LeS,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(10),
              Opcodes.i64LeU,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(10),
              Opcodes.i64GeS,
              Opcodes.i32Add,
              ..._localGet(1),
              ..._i64Const(10),
              Opcodes.i64GeU,
              Opcodes.i32Add,
              ..._localGet(1),
              Opcodes.i64Eqz,
              Opcodes.i32Eqz,
              Opcodes.i32Add,
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(name: 'wrapI64', kind: WasmExportKind.function, index: 1),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc64'): (args) async {
              final value = args.single;
              final base = value is BigInt ? value : BigInt.from(value as int);
              return base + BigInt.one;
            },
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapI64', [9]), 26);
    });

    test(
      'supports global and select opcodes in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [0],
          globals: [
            _GlobalSpec(
              valueType: 0x7f,
              mutable: true,
              initExpr: [..._i32Const(0), Opcodes.end],
            ),
          ],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._call(0),
                ..._globalSet(0),

                ..._i32Const(100),
                ..._i32Const(7),
                ..._globalGet(0),
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.select,

                ..._i32Const(30),
                ..._i32Const(5),
                ..._globalGet(0),
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.selectT,
                ..._u32Leb(1),
                0x7f,
                Opcodes.i32Add,

                ..._globalGet(0),
                Opcodes.i32Add,
                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapGlobalSelect',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapGlobalSelect', [41]), 172);
      },
    );

    test(
      'supports call_indirect and return_call_indirect in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          tables: const [_TableSpec(refType: 0x70, min: 1)],
          functionTypeIndices: const [1, 1, 1],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [..._localGet(0), ..._call(0), Opcodes.end],
            ),
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._i32Const(0),
                ..._callIndirect(1, 0),
                Opcodes.end,
              ],
            ),
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._i32Const(0),
                Opcodes.returnCallIndirect,
                ..._u32Leb(1),
                ..._u32Leb(0),
                Opcodes.end,
              ],
            ),
          ],
          elements: [
            _ElementSegmentSpec.active(
              tableIndex: 0,
              offsetExpr: [..._i32Const(0), Opcodes.end],
              functionIndices: const [1],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapIndirect',
              kind: WasmExportKind.function,
              index: 2,
            ),
            _ExportSpec(
              name: 'wrapReturnIndirect',
              kind: WasmExportKind.function,
              index: 3,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapIndirect', [41]), 42);
        expect(await instance.invokeI32Async('wrapReturnIndirect', [41]), 42);
      },
    );

    test('supports br_table in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._call(0),
              Opcodes.drop,

              Opcodes.block,
              0x40,
              Opcodes.block,
              0x40,
              Opcodes.block,
              0x40,
              ..._localGet(0),
              Opcodes.brTable,
              ..._u32Leb(2),
              ..._u32Leb(0),
              ..._u32Leb(1),
              ..._u32Leb(2),
              Opcodes.end,
              ..._i32Const(10),
              Opcodes.return_,
              Opcodes.end,
              ..._i32Const(20),
              Opcodes.return_,
              Opcodes.end,
              ..._i32Const(30),
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'wrapBrTable',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('wrapBrTable', [0]), 10);
      expect(await instance.invokeI32Async('wrapBrTable', [1]), 20);
      expect(await instance.invokeI32Async('wrapBrTable', [2]), 30);
      expect(await instance.invokeI32Async('wrapBrTable', [99]), 30);
    });

    test(
      'supports reinterpret and sign-extension conversions in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [0],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._call(0),
                Opcodes.drop,

                ..._i32Const(-1),
                Opcodes.i64ExtendI32U,
                Opcodes.i64Extend32S,
                Opcodes.i32WrapI64,
                ..._i32Const(43),
                Opcodes.i32Add,
                Opcodes.i32Extend8S,
                Opcodes.i32Extend16S,

                Opcodes.i64ExtendI32S,
                Opcodes.i64Extend8S,
                Opcodes.i64Extend16S,
                Opcodes.i64Extend32S,
                Opcodes.i32WrapI64,

                Opcodes.f32ReinterpretI32,
                Opcodes.i32ReinterpretF32,

                Opcodes.i64ExtendI32U,
                Opcodes.f64ReinterpretI64,
                Opcodes.i64ReinterpretF64,
                Opcodes.i32WrapI64,
                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapConvert',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapConvert', [41]), 42);
      },
    );

    test(
      'supports trunc/convert/promote/demote in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [0],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._call(0),
                Opcodes.drop,
                ..._i32Const(0),

                ..._f64Const(42.9),
                Opcodes.i32TruncF64S,
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(42.9),
                Opcodes.i32TruncF64U,
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(42.9),
                Opcodes.f32DemoteF64,
                Opcodes.i32TruncF32S,
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(42.9),
                Opcodes.f32DemoteF64,
                Opcodes.i32TruncF32U,
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._f64Const(9.9),
                Opcodes.i64TruncF64S,
                ..._i64Const(9),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._f64Const(9.9),
                Opcodes.i64TruncF64U,
                ..._i64Const(9),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._f64Const(9.9),
                Opcodes.f32DemoteF64,
                Opcodes.i64TruncF32S,
                ..._i64Const(9),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._f64Const(9.9),
                Opcodes.f32DemoteF64,
                Opcodes.i64TruncF32U,
                ..._i64Const(9),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                ..._i32Const(-7),
                Opcodes.f64ConvertI32S,
                Opcodes.i32TruncF64S,
                ..._i32Const(-7),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(16777215),
                Opcodes.f64ConvertI32U,
                Opcodes.i32TruncF64U,
                ..._i32Const(16777215),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(-7),
                Opcodes.f32ConvertI32S,
                Opcodes.i32TruncF32S,
                ..._i32Const(-7),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._i32Const(16777215),
                Opcodes.f32ConvertI32U,
                Opcodes.i32TruncF32U,
                ..._i32Const(16777215),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._i64Const(-9),
                Opcodes.f64ConvertI64S,
                Opcodes.i64TruncF64S,
                ..._i64Const(-9),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i64Const(9007199254740991),
                Opcodes.f64ConvertI64U,
                Opcodes.i64TruncF64U,
                ..._i64Const(9007199254740991),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i64Const(-9),
                Opcodes.f32ConvertI64S,
                Opcodes.i64TruncF32S,
                ..._i64Const(-9),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._i64Const(1234567),
                Opcodes.f32ConvertI64U,
                Opcodes.i64TruncF32U,
                ..._i64Const(1234567),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                ..._f64Const(42.5),
                Opcodes.f32DemoteF64,
                Opcodes.f64PromoteF32,
                Opcodes.i32TruncF64S,
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(42.5),
                Opcodes.f32DemoteF64,
                Opcodes.i32TruncF32S,
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapNumericConvert',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapNumericConvert', [41]), 18);
      },
    );

    test(
      'supports f32/f64 unary and compare ops in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [0],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._call(0),
                Opcodes.drop,
                ..._i32Const(0),

                ..._f64Const(-1.5),
                Opcodes.f32DemoteF64,
                Opcodes.f32Abs,
                Opcodes.i32TruncF32S,
                ..._i32Const(1),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1.5),
                Opcodes.f32DemoteF64,
                Opcodes.f32Neg,
                Opcodes.i32TruncF32S,
                ..._i32Const(-1),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1.2),
                Opcodes.f32DemoteF64,
                Opcodes.f32Ceil,
                Opcodes.i32TruncF32S,
                ..._i32Const(2),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1.8),
                Opcodes.f32DemoteF64,
                Opcodes.f32Floor,
                Opcodes.i32TruncF32S,
                ..._i32Const(1),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(-1.8),
                Opcodes.f32DemoteF64,
                Opcodes.f32Trunc,
                Opcodes.i32TruncF32S,
                ..._i32Const(-1),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1.5),
                Opcodes.f32DemoteF64,
                Opcodes.f32Nearest,
                Opcodes.i32TruncF32S,
                ..._i32Const(2),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(4.0),
                Opcodes.f32DemoteF64,
                Opcodes.f32Sqrt,
                Opcodes.i32TruncF32S,
                ..._i32Const(2),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(3.0),
                Opcodes.f32DemoteF64,
                ..._f64Const(5.0),
                Opcodes.f32DemoteF64,
                Opcodes.f32Min,
                Opcodes.i32TruncF32S,
                ..._i32Const(3),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(3.0),
                Opcodes.f32DemoteF64,
                ..._f64Const(5.0),
                Opcodes.f32DemoteF64,
                Opcodes.f32Max,
                Opcodes.i32TruncF32S,
                ..._i32Const(5),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1.0),
                Opcodes.f32DemoteF64,
                ..._f64Const(-0.0),
                Opcodes.f32DemoteF64,
                Opcodes.f32CopySign,
                Opcodes.i32TruncF32S,
                ..._i32Const(-1),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._f64Const(2.0),
                Opcodes.f32DemoteF64,
                ..._f64Const(2.0),
                Opcodes.f32DemoteF64,
                Opcodes.f32Eq,
                Opcodes.i32Add,
                ..._f64Const(2.0),
                Opcodes.f32DemoteF64,
                ..._f64Const(3.0),
                Opcodes.f32DemoteF64,
                Opcodes.f32Ne,
                Opcodes.i32Add,
                ..._f64Const(2.0),
                Opcodes.f32DemoteF64,
                ..._f64Const(3.0),
                Opcodes.f32DemoteF64,
                Opcodes.f32Lt,
                Opcodes.i32Add,
                ..._f64Const(3.0),
                Opcodes.f32DemoteF64,
                ..._f64Const(2.0),
                Opcodes.f32DemoteF64,
                Opcodes.f32Gt,
                Opcodes.i32Add,
                ..._f64Const(2.0),
                Opcodes.f32DemoteF64,
                ..._f64Const(2.0),
                Opcodes.f32DemoteF64,
                Opcodes.f32Le,
                Opcodes.i32Add,
                ..._f64Const(2.0),
                Opcodes.f32DemoteF64,
                ..._f64Const(2.0),
                Opcodes.f32DemoteF64,
                Opcodes.f32Ge,
                Opcodes.i32Add,

                ..._f64Const(-1.5),
                Opcodes.f64Abs,
                Opcodes.i32TruncF64S,
                ..._i32Const(1),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1.5),
                Opcodes.f64Neg,
                Opcodes.i32TruncF64S,
                ..._i32Const(-1),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1.2),
                Opcodes.f64Ceil,
                Opcodes.i32TruncF64S,
                ..._i32Const(2),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1.8),
                Opcodes.f64Floor,
                Opcodes.i32TruncF64S,
                ..._i32Const(1),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(-1.8),
                Opcodes.f64Trunc,
                Opcodes.i32TruncF64S,
                ..._i32Const(-1),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1.5),
                Opcodes.f64Nearest,
                Opcodes.i32TruncF64S,
                ..._i32Const(2),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(4.0),
                Opcodes.f64Sqrt,
                Opcodes.i32TruncF64S,
                ..._i32Const(2),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(3.0),
                ..._f64Const(5.0),
                Opcodes.f64Min,
                Opcodes.i32TruncF64S,
                ..._i32Const(3),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(3.0),
                ..._f64Const(5.0),
                Opcodes.f64Max,
                Opcodes.i32TruncF64S,
                ..._i32Const(5),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1.0),
                ..._f64Const(-0.0),
                Opcodes.f64CopySign,
                Opcodes.i32TruncF64S,
                ..._i32Const(-1),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._f64Const(2.0),
                ..._f64Const(2.0),
                Opcodes.f64Eq,
                Opcodes.i32Add,
                ..._f64Const(2.0),
                ..._f64Const(3.0),
                Opcodes.f64Ne,
                Opcodes.i32Add,
                ..._f64Const(2.0),
                ..._f64Const(3.0),
                Opcodes.f64Lt,
                Opcodes.i32Add,
                ..._f64Const(3.0),
                ..._f64Const(2.0),
                Opcodes.f64Gt,
                Opcodes.i32Add,
                ..._f64Const(2.0),
                ..._f64Const(2.0),
                Opcodes.f64Le,
                Opcodes.i32Add,
                ..._f64Const(2.0),
                ..._f64Const(2.0),
                Opcodes.f64Ge,
                Opcodes.i32Add,

                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapFloatOps',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapFloatOps', [41]), 32);
      },
    );

    test(
      'supports trunc_sat conversions in async import call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [0],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._call(0),
                Opcodes.drop,
                ..._i32Const(0),

                ..._f64Const(double.nan),
                ..._fc0(Opcodes.i32TruncSatF64S),
                ..._i32Const(0),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1e20),
                ..._fc0(Opcodes.i32TruncSatF64S),
                ..._i32Const(2147483647),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(-1e20),
                ..._fc0(Opcodes.i32TruncSatF64S),
                ..._i32Const(-2147483648),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(-1.0),
                ..._fc0(Opcodes.i32TruncSatF64U),
                ..._i32Const(0),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(1e20),
                ..._fc0(Opcodes.i32TruncSatF64U),
                ..._i32Const(-1),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(42.9),
                ..._fc0(Opcodes.i32TruncSatF64U),
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.i32Add,

                ..._f64Const(double.nan),
                ..._fc0(Opcodes.i64TruncSatF64S),
                ..._i64Const(0),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._f64Const(1e30),
                ..._fc0(Opcodes.i64TruncSatF64S),
                ..._i64Const(9223372036854775807),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._f64Const(-1e30),
                ..._fc0(Opcodes.i64TruncSatF64S),
                ..._i64Const(-9223372036854775808),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._f64Const(-1.0),
                ..._fc0(Opcodes.i64TruncSatF64U),
                ..._i64Const(0),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._f64Const(1e30),
                ..._fc0(Opcodes.i64TruncSatF64U),
                ..._i64Const(-1),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._f64Const(42.9),
                ..._fc0(Opcodes.i64TruncSatF64U),
                ..._i64Const(42),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                ..._f64Const(42.9),
                Opcodes.f32DemoteF64,
                ..._fc0(Opcodes.i32TruncSatF32S),
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(42.9),
                Opcodes.f32DemoteF64,
                ..._fc0(Opcodes.i32TruncSatF32U),
                ..._i32Const(42),
                Opcodes.i32Eq,
                Opcodes.i32Add,
                ..._f64Const(42.9),
                Opcodes.f32DemoteF64,
                ..._fc0(Opcodes.i64TruncSatF32S),
                ..._i64Const(42),
                Opcodes.i64Eq,
                Opcodes.i32Add,
                ..._f64Const(42.9),
                Opcodes.f32DemoteF64,
                ..._fc0(Opcodes.i64TruncSatF32U),
                ..._i64Const(42),
                Opcodes.i64Eq,
                Opcodes.i32Add,

                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'wrapTruncSat',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        expect(await instance.invokeI32Async('wrapTruncSat', [41]), 16);
      },
    );

    test('supports v128.const in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._fdBytes(Opcodes.v128Const, List<int>.filled(16, 0x00)),
              Opcodes.drop,
              ..._call(0),
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'supportsV128Const',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(simd: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('supportsV128Const', [41]), 42);
    });

    test('supports i8x16 SIMD opcodes in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [0, 0, 0, 0, 0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(0x7f),
              ..._fdBytes(Opcodes.i8x16Splat, []),
              ..._fdBytes(Opcodes.v128AnyTrue, []),
              ..._i32Const(1),
              Opcodes.i32Eq,
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(0x55),
              ..._fdBytes(Opcodes.i8x16Splat, []),
              ..._i32Const(0x55),
              ..._fdBytes(Opcodes.i8x16Splat, []),
              ..._fdBytes(Opcodes.i8x16Eq, []),
              ..._fdBytes(Opcodes.i8x16Bitmask, []),
              ..._i32Const(0xffff),
              Opcodes.i32Eq,
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(0x80),
              ..._fdBytes(Opcodes.i8x16Splat, []),
              ..._fdBytes(Opcodes.i8x16Abs, []),
              ..._i32Const(0x80),
              ..._fdBytes(Opcodes.i8x16Splat, []),
              ..._fdBytes(Opcodes.i8x16Eq, []),
              ..._fdBytes(Opcodes.i8x16Bitmask, []),
              ..._i32Const(0xffff),
              Opcodes.i32Eq,
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(0x0f),
              ..._fdBytes(Opcodes.i8x16Splat, []),
              ..._fdBytes(Opcodes.i8x16Neg, []),
              ..._i32Const(0xf1),
              ..._fdBytes(Opcodes.i8x16Splat, []),
              ..._fdBytes(Opcodes.i8x16Eq, []),
              ..._fdBytes(Opcodes.i8x16Bitmask, []),
              ..._i32Const(0xffff),
              Opcodes.i32Eq,
              Opcodes.end,
            ],
          ),
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._call(0),
              Opcodes.drop,
              ..._i32Const(0x0f),
              ..._fdBytes(Opcodes.i8x16Splat, []),
              ..._fdBytes(Opcodes.i8x16Popcnt, []),
              ..._i32Const(4),
              ..._fdBytes(Opcodes.i8x16Splat, []),
              ..._fdBytes(Opcodes.i8x16Eq, []),
              ..._fdBytes(Opcodes.i8x16Bitmask, []),
              ..._i32Const(0xffff),
              Opcodes.i32Eq,
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'supportsI8x16SplatAnyTrue',
            kind: WasmExportKind.function,
            index: 1,
          ),
          _ExportSpec(
            name: 'supportsI8x16Eq',
            kind: WasmExportKind.function,
            index: 2,
          ),
          _ExportSpec(
            name: 'supportsI8x16Abs',
            kind: WasmExportKind.function,
            index: 3,
          ),
          _ExportSpec(
            name: 'supportsI8x16Neg',
            kind: WasmExportKind.function,
            index: 4,
          ),
          _ExportSpec(
            name: 'supportsI8x16Popcnt',
            kind: WasmExportKind.function,
            index: 5,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(simd: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(
        await instance.invokeI32Async('supportsI8x16SplatAnyTrue', [41]),
        1,
      );
      expect(await instance.invokeI32Async('supportsI8x16Eq', [41]), 1);
      expect(await instance.invokeI32Async('supportsI8x16Abs', [41]), 1);
      expect(await instance.invokeI32Async('supportsI8x16Neg', [41]), 1);
      expect(await instance.invokeI32Async('supportsI8x16Popcnt', [41]), 1);
    });

    test('supports i16x8 SIMD opcodes in async import call chains', () async {
      final wasm = _buildModule(
        types: [
          _funcType([0x7f], [0x7f]),
        ],
        imports: const [
          _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
        ],
        functionTypeIndices: const [0],
        functionBodies: [
          _FunctionBodySpec(
            instructions: [
              ..._localGet(0),
              ..._call(0),
              Opcodes.drop,
              ..._fdBytes(Opcodes.v128Const, <int>[
                0x00,
                0x80,
                0x00,
                0x80,
                0x00,
                0x80,
                0x00,
                0x80,
                0x00,
                0x80,
                0x00,
                0x80,
                0x00,
                0x80,
                0x00,
                0x80,
              ]),
              ..._fdBytes(Opcodes.i16x8Abs, []),
              ..._fdBytes(Opcodes.i16x8Bitmask, []),
              ..._i32Const(0xff),
              Opcodes.i32Eq,
              Opcodes.end,
            ],
          ),
        ],
        exports: const [
          _ExportSpec(
            name: 'supportsI16x8AbsBitmask',
            kind: WasmExportKind.function,
            index: 1,
          ),
        ],
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        features: const WasmFeatureSet(simd: true),
        imports: WasmImports(
          asyncFunctions: {
            WasmImports.key('host', 'inc'): (args) async =>
                (args.single as int) + 1,
          },
        ),
      );

      expect(await instance.invokeI32Async('supportsI16x8AbsBitmask', [41]), 1);
    });

    test(
      'reports explicit boundary for unsupported async call chains',
      () async {
        final wasm = _buildModule(
          types: [
            _funcType([0x7f], [0x7f]),
          ],
          imports: const [
            _ImportFunctionSpec(module: 'host', name: 'inc', typeIndex: 0),
          ],
          functionTypeIndices: const [0],
          functionBodies: [
            _FunctionBodySpec(
              instructions: [
                ..._localGet(0),
                ..._call(0),
                Opcodes.drop,
                ..._fdBytes(Opcodes.v128Const, List<int>.filled(16, 0)),
                ..._fdBytes(Opcodes.v128Const, List<int>.filled(16, 0)),
                ..._fdBytes(Opcodes.i16x8Ne, []),
                Opcodes.drop,
                ..._i32Const(0),
                Opcodes.end,
              ],
            ),
          ],
          exports: const [
            _ExportSpec(
              name: 'unsupportedWrap',
              kind: WasmExportKind.function,
              index: 1,
            ),
          ],
        );

        final instance = WasmInstance.fromBytes(
          wasm,
          features: const WasmFeatureSet(simd: true),
          imports: WasmImports(
            asyncFunctions: {
              WasmImports.key('host', 'inc'): (args) async =>
                  (args.single as int) + 1,
            },
          ),
        );

        await expectLater(
          () async => instance.invokeI32Async('unsupportedWrap', [41]),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains('wasm-defined functions'),
            ),
          ),
        );
      },
    );

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
  List<int> tagTypeIndices = const [],
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

  if (tagTypeIndices.isNotEmpty) {
    final payload = <int>[..._u32Leb(tagTypeIndices.length)];
    for (final typeIndex in tagTypeIndices) {
      payload
        ..add(0x00)
        ..addAll(_u32Leb(typeIndex));
    }
    bytes.addAll(_section(13, payload));
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

  if (dataCount != null) {
    bytes.addAll(_section(12, _u32Leb(dataCount)));
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
List<int> _tableGet(int tableIndex) => <int>[
  Opcodes.tableGet,
  ..._u32Leb(tableIndex),
];
List<int> _tableSet(int tableIndex) => <int>[
  Opcodes.tableSet,
  ..._u32Leb(tableIndex),
];
List<int> _br(int depth) => <int>[Opcodes.br, ..._u32Leb(depth)];
List<int> _brIf(int depth) => <int>[Opcodes.brIf, ..._u32Leb(depth)];
List<int> _brOnNull(int depth) => <int>[Opcodes.brOnNull, ..._u32Leb(depth)];
List<int> _brOnNonNull(int depth) => <int>[
  Opcodes.brOnNonNull,
  ..._u32Leb(depth),
];
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
List<int> _fc0(int pseudoOpcode) => <int>[
  0xfc,
  ..._u32Leb(pseudoOpcode & 0xff),
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
List<int> _fdBytes(int pseudoOpcode, List<int> payload) => <int>[
  0xfd,
  ..._u32Leb(pseudoOpcode & 0xff),
  ...payload,
];
List<int> _feMem(int pseudoOpcode, {int align = 0, int offset = 0}) => <int>[
  0xfe,
  ..._u32Leb(pseudoOpcode & 0xff),
  ..._u32Leb(align),
  ..._u32Leb(offset),
];
List<int> _fe0(int pseudoOpcode, [int immediate = 0]) => <int>[
  0xfe,
  ..._u32Leb(pseudoOpcode & 0xff),
  ..._u32Leb(immediate),
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
  var remaining = BigInt.from(value);

  while (true) {
    var byte = (remaining & BigInt.from(0x7f)).toInt();
    remaining >>= 7;

    final signBitSet = (byte & 0x40) != 0;
    final done =
        (remaining == BigInt.zero && !signBitSet) ||
        (remaining == -BigInt.one && signBitSet);
    if (!done) {
      byte |= 0x80;
    }
    bytes.add(byte);
    if (done) {
      break;
    }
  }

  return bytes;
}

List<int> _i64Leb(int value) {
  final bytes = <int>[];
  var remaining = BigInt.from(value);

  while (true) {
    var byte = (remaining & BigInt.from(0x7f)).toInt();
    remaining >>= 7;

    final signBitSet = (byte & 0x40) != 0;
    final done =
        (remaining == BigInt.zero && !signBitSet) ||
        (remaining == -BigInt.one && signBitSet);
    if (!done) {
      byte |= 0x80;
    }
    bytes.add(byte);
    if (done) {
      break;
    }
  }

  return bytes;
}
