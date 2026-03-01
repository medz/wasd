import 'dart:convert';
import 'dart:typed_data';

import '../features.dart';
import '../imports.dart';
import '../instance.dart';
import '../module.dart';
import '../opcode.dart';

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

final class _DefinedMemorySpec {
  const _DefinedMemorySpec({
    required this.minPages,
    required this.maxPages,
    required this.shared,
  });

  final int minPages;
  final int maxPages;
  final bool shared;
}

final class _ImportedMemorySpec {
  const _ImportedMemorySpec({
    required this.module,
    required this.name,
    required this.minPages,
    required this.maxPages,
    required this.shared,
  });

  final String module;
  final String name;
  final int minPages;
  final int maxPages;
  final bool shared;
}

void runThreadsPortableChecks() {
  final features = WasmFeatureSet.layeredDefaults(
    profile: WasmFeatureProfile.full,
  );

  final atomic = WasmInstance.fromBytes(
    _buildThreadsAtomicModule(),
    features: features,
  );

  const operand = 0xbeef;
  atomic.invoke('seed', const []);
  final previous = atomic.invokeI64('rmw16_add_u', [operand]);
  if (_u64Hex(previous) != '0000000000001111') {
    throw StateError(
      'threads portable check failed: rmw16 previous expected=0x0000000000001111 '
      'actual=0x${_u64Hex(previous)}',
    );
  }

  final loaded64 = atomic.invokeI64('load64');
  if (_u64Hex(loaded64) != '000000001111d000') {
    throw StateError(
      'threads portable check failed: load64 expected=0x000000001111d000 '
      'actual=0x${_u64Hex(loaded64)}',
    );
  }

  final loaded32 = atomic.invokeI32('load32');
  final waitMismatch = atomic.invokeI32('wait32', [0, 0, 0]);
  if (waitMismatch != 1) {
    throw StateError(
      'threads portable check failed: wait32 mismatch expected=1 '
      'actual=$waitMismatch',
    );
  }

  final waitMatch = atomic.invokeI32('wait32', [0, loaded32, 0]);
  if (waitMatch != 2) {
    throw StateError(
      'threads portable check failed: wait32 match expected=2 '
      'actual=$waitMatch',
    );
  }

  final notify = atomic.invokeI32('notify', [0, 1]);
  if (notify != 0) {
    throw StateError(
      'threads portable check failed: notify expected=0 actual=$notify',
    );
  }

  final sharedMemory = atomic.exportedMemory('memory');
  if (!sharedMemory.shared) {
    throw StateError(
      'threads portable check failed: exported memory must be shared',
    );
  }

  final probe = WasmInstance.fromBytes(
    _buildThreadsMemoryImportProbeModule(),
    features: features,
    imports: WasmImports(
      memories: {WasmImports.key('env', 'memory'): sharedMemory},
    ),
  );
  final probed = probe.invokeI32('load32');
  if (probed.toUnsigned(32) != loaded32.toUnsigned(32)) {
    throw StateError(
      'threads portable check failed: imported memory read mismatch '
      'expected=${loaded32.toUnsigned(32)} actual=${probed.toUnsigned(32)}',
    );
  }
}

Uint8List _buildThreadsAtomicModule() {
  return _buildModule(
    types: [
      _funcType([], []),
      _funcType([0x7e], [0x7e]),
      _funcType([], [0x7e]),
      _funcType([], [0x7f]),
      _funcType([0x7f, 0x7f, 0x7e], [0x7f]),
      _funcType([0x7f, 0x7f], [0x7f]),
    ],
    functionTypeIndices: [0, 1, 2, 3, 4, 5],
    functionBodies: [
      [
        ..._i32Const(0),
        ..._i64ConstHexBits('0000000011111111'),
        ..._memInstr(Opcodes.i64AtomicStore, align: 3),
        Opcodes.end,
      ],
      [
        ..._i32Const(0),
        ..._localGet(0),
        ..._memInstr(Opcodes.i64AtomicRmw16AddU, align: 1),
        Opcodes.end,
      ],
      [
        ..._i32Const(0),
        ..._memInstr(Opcodes.i64AtomicLoad, align: 3),
        Opcodes.end,
      ],
      [
        ..._i32Const(0),
        ..._memInstr(Opcodes.i32AtomicLoad, align: 2),
        Opcodes.end,
      ],
      [
        ..._localGet(0),
        ..._localGet(1),
        ..._localGet(2),
        ..._memInstr(Opcodes.memoryAtomicWait32, align: 2),
        Opcodes.end,
      ],
      [
        ..._localGet(0),
        ..._localGet(1),
        ..._memInstr(Opcodes.memoryAtomicNotify, align: 2),
        Opcodes.end,
      ],
    ],
    definedMemory: const _DefinedMemorySpec(
      minPages: 1,
      maxPages: 1,
      shared: true,
    ),
    exports: const [
      _ExportSpec(name: 'seed', kind: WasmExportKind.function, index: 0),
      _ExportSpec(name: 'rmw16_add_u', kind: WasmExportKind.function, index: 1),
      _ExportSpec(name: 'load64', kind: WasmExportKind.function, index: 2),
      _ExportSpec(name: 'load32', kind: WasmExportKind.function, index: 3),
      _ExportSpec(name: 'wait32', kind: WasmExportKind.function, index: 4),
      _ExportSpec(name: 'notify', kind: WasmExportKind.function, index: 5),
      _ExportSpec(name: 'memory', kind: WasmExportKind.memory, index: 0),
    ],
  );
}

Uint8List _buildThreadsMemoryImportProbeModule() {
  return _buildModule(
    types: [
      _funcType([], [0x7f]),
    ],
    functionTypeIndices: [0],
    functionBodies: [
      [
        ..._i32Const(0),
        ..._memInstr(Opcodes.i32AtomicLoad, align: 2),
        Opcodes.end,
      ],
    ],
    importedMemory: const _ImportedMemorySpec(
      module: 'env',
      name: 'memory',
      minPages: 1,
      maxPages: 1,
      shared: true,
    ),
    exports: const [
      _ExportSpec(name: 'load32', kind: WasmExportKind.function, index: 0),
    ],
  );
}

Uint8List _buildModule({
  required List<List<int>> types,
  required List<int> functionTypeIndices,
  required List<List<int>> functionBodies,
  required List<_ExportSpec> exports,
  _DefinedMemorySpec? definedMemory,
  _ImportedMemorySpec? importedMemory,
}) {
  if (functionTypeIndices.length != functionBodies.length) {
    throw ArgumentError('Function type and body count mismatch.');
  }
  if (definedMemory != null && importedMemory != null) {
    throw ArgumentError('Module cannot define and import memory together.');
  }

  final bytes = <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

  bytes.addAll(
    _section(1, <int>[..._u32Leb(types.length), ...types.expand((t) => t)]),
  );

  if (importedMemory != null) {
    final payload = <int>[
      ..._u32Leb(1),
      ..._name(importedMemory.module),
      ..._name(importedMemory.name),
      WasmImportKind.memory,
      ..._memoryLimits(
        min: importedMemory.minPages,
        max: importedMemory.maxPages,
        shared: importedMemory.shared,
      ),
    ];
    bytes.addAll(_section(2, payload));
  }

  bytes.addAll(
    _section(3, <int>[
      ..._u32Leb(functionTypeIndices.length),
      ...functionTypeIndices.expand(_u32Leb),
    ]),
  );

  if (definedMemory != null) {
    bytes.addAll(
      _section(5, <int>[
        ..._u32Leb(1),
        ..._memoryLimits(
          min: definedMemory.minPages,
          max: definedMemory.maxPages,
          shared: definedMemory.shared,
        ),
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
    if (body.isEmpty || body.last != Opcodes.end) {
      throw ArgumentError('Function body must end with Opcodes.end.');
    }
    final functionBytes = <int>[0x00, ...body];
    codePayload
      ..addAll(_u32Leb(functionBytes.length))
      ..addAll(functionBytes);
  }
  bytes.addAll(_section(10, codePayload));

  return Uint8List.fromList(bytes);
}

List<int> _funcType(List<int> params, List<int> results) => <int>[
  0x60,
  ..._u32Leb(params.length),
  ...params,
  ..._u32Leb(results.length),
  ...results,
];

List<int> _section(int id, List<int> payload) => <int>[
  id,
  ..._u32Leb(payload.length),
  ...payload,
];

List<int> _name(String value) {
  final encoded = utf8.encode(value);
  return <int>[..._u32Leb(encoded.length), ...encoded];
}

List<int> _memoryLimits({
  required int min,
  required int max,
  required bool shared,
}) {
  if (shared) {
    return <int>[0x03, ..._u32Leb(min), ..._u32Leb(max)];
  }
  return <int>[0x01, ..._u32Leb(min), ..._u32Leb(max)];
}

List<int> _localGet(int index) => <int>[Opcodes.localGet, ..._u32Leb(index)];
List<int> _i32Const(int value) => <int>[Opcodes.i32Const, ..._i32Leb(value)];
List<int> _i64ConstHexBits(String hexBits) => <int>[
  Opcodes.i64Const,
  ..._i64LebFromHexBits(hexBits),
];

List<int> _memInstr(int opcode, {required int align, int offset = 0}) {
  final bytes = <int>[];
  if (opcode <= 0xff) {
    bytes.add(opcode);
  } else {
    bytes
      ..add((opcode >> 8) & 0xff)
      ..addAll(_u32Leb(opcode & 0xff));
  }
  bytes
    ..addAll(_u32Leb(align))
    ..addAll(_u32Leb(offset));
  return bytes;
}

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

List<int> _i64LebFromHexBits(String hex) {
  var current = BigInt.parse(hex, radix: 16) & _u64Mask;
  if ((current & _i64SignBit) != BigInt.zero) {
    current -= _i64Width;
  }

  final bytes = <int>[];
  while (true) {
    var byte = (current & BigInt.from(0x7f)).toInt();
    current >>= 7;

    final signBitSet = (byte & 0x40) != 0;
    final done =
        (current == BigInt.zero && !signBitSet) ||
        (current == BigInt.from(-1) && signBitSet);
    if (!done) {
      byte |= 0x80;
    }

    bytes.add(byte);
    if (done) {
      return bytes;
    }
  }
}

String _u64Hex(int value) {
  return (BigInt.from(value) & _u64Mask).toRadixString(16).padLeft(16, '0');
}

final BigInt _u64Mask = (BigInt.one << 64) - BigInt.one;
final BigInt _i64SignBit = BigInt.one << 63;
final BigInt _i64Width = BigInt.one << 64;
