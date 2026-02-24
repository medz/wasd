import 'dart:convert';
import 'dart:typed_data';

import 'package:pure_wasm_runtime/pure_wasm_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('WasiRunner', () {
    test('returns proc_exit code from _start', () {
      final runner = WasiRunner();
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
            instructions: [..._i32Const(7), ..._call(0), Opcodes.end],
          ),
        ],
        exports: const [
          _ExportSpec(name: '_start', kind: WasmExportKind.function, index: 1),
        ],
      );

      expect(runner.runStartFromBytes(wasm), 7);
    });

    test('auto-binds memory and runs wasi fd_write _start', () {
      final out = <int>[];
      final wasi = WasiPreview1(stdoutSink: (bytes) => out.addAll(bytes));
      final runner = WasiRunner(wasi: wasi);
      final wasm = _buildModule(
        types: [
          _funcType([0x7f, 0x7f, 0x7f, 0x7f], [0x7f]),
          _funcType([], []),
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
              ..._i32Const(32),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(4),
              ..._i32Const(3),
              ..._memInstr(Opcodes.i32Store),
              ..._i32Const(1),
              ..._i32Const(0),
              ..._i32Const(1),
              ..._i32Const(8),
              ..._call(0),
              Opcodes.drop,
              Opcodes.end,
            ],
          ),
        ],
        memoryMinPages: 1,
        dataSegments: [
          _DataSegmentSpec.active(
            memoryIndex: 0,
            offsetExpr: [..._i32Const(32), Opcodes.end],
            bytes: utf8.encode('OK\n'),
          ),
        ],
        exports: const [
          _ExportSpec(name: '_start', kind: WasmExportKind.function, index: 1),
          _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
        ],
      );

      expect(runner.runStartFromBytes(wasm), 0);
      expect(utf8.decode(out), 'OK\n');
    });
  });
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
