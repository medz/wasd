import 'dart:typed_data';

import 'package:wasd/wasd.dart';

void main() {
  final add = WasmInstance.fromBytes(_buildI32AddModule());
  print('i32 add: 20 + 22 = ${add.invokeI32('add', [20, 22])}');

  final add64 = WasmInstance.fromBytes(_buildI64AddModule());
  print(
    'i64 add: 9000000000 + 5 = ${add64.invokeI64('add64', [9000000000, 5])}',
  );

  final mul64 = WasmInstance.fromBytes(_buildF64MulModule());
  print('f64 mul: 2.5 * 4.0 = ${mul64.invokeF64('mul64', [2.5, 4.0])}');

  final pair = WasmInstance.fromBytes(_buildMultiReturnModule());
  print('multi return pair(7, 11) = ${pair.invokeMulti('pair', [7, 11])}');

  final indirect = WasmInstance.fromBytes(_buildCallIndirectModule());
  print(
    'call_indirect dispatch(0, 3, 4) = ${indirect.invokeI32('dispatch', [0, 3, 4])}',
  );
  print(
    'call_indirect dispatch(1, 3, 4) = ${indirect.invokeI32('dispatch', [1, 3, 4])}',
  );
}

Uint8List _buildI32AddModule() {
  return _buildModule(
    types: [
      _funcType([0x7f, 0x7f], [0x7f]),
    ],
    functionTypeIndices: [0],
    functionBodies: [
      [..._localGet(0), ..._localGet(1), Opcodes.i32Add, Opcodes.end],
    ],
    exports: [('add', WasmExportKind.function, 0)],
  );
}

Uint8List _buildI64AddModule() {
  return _buildModule(
    types: [
      _funcType([0x7e, 0x7e], [0x7e]),
    ],
    functionTypeIndices: [0],
    functionBodies: [
      [..._localGet(0), ..._localGet(1), Opcodes.i64Add, Opcodes.end],
    ],
    exports: [('add64', WasmExportKind.function, 0)],
  );
}

Uint8List _buildF64MulModule() {
  return _buildModule(
    types: [
      _funcType([0x7c, 0x7c], [0x7c]),
    ],
    functionTypeIndices: [0],
    functionBodies: [
      [..._localGet(0), ..._localGet(1), Opcodes.f64Mul, Opcodes.end],
    ],
    exports: [('mul64', WasmExportKind.function, 0)],
  );
}

Uint8List _buildMultiReturnModule() {
  return _buildModule(
    types: [
      _funcType([0x7f, 0x7f], [0x7f, 0x7f]),
    ],
    functionTypeIndices: [0],
    functionBodies: [
      [..._localGet(0), ..._localGet(1), Opcodes.end],
    ],
    exports: [('pair', WasmExportKind.function, 0)],
  );
}

Uint8List _buildCallIndirectModule() {
  return _buildModule(
    types: [
      _funcType([0x7f, 0x7f], [0x7f]),
      _funcType([0x7f, 0x7f, 0x7f], [0x7f]),
    ],
    functionTypeIndices: [0, 0, 1],
    tableSpecs: const [(0x70, 2, 2)],
    elementSpecs: [
      (0, [..._i32Const(0), Opcodes.end], [0, 1]),
    ],
    functionBodies: [
      [..._localGet(0), ..._localGet(1), Opcodes.i32Add, Opcodes.end],
      [..._localGet(0), ..._localGet(1), Opcodes.i32Mul, Opcodes.end],
      [
        ..._localGet(1),
        ..._localGet(2),
        ..._localGet(0),
        ..._callIndirect(0, 0),
        Opcodes.end,
      ],
    ],
    exports: [('dispatch', WasmExportKind.function, 2)],
  );
}

Uint8List _buildModule({
  required List<List<int>> types,
  required List<int> functionTypeIndices,
  required List<List<int>> functionBodies,
  List<(String, int, int)> exports = const [],
  List<(int, int, int?)> tableSpecs = const [],
  List<(int, List<int>, List<int>)> elementSpecs = const [],
}) {
  final bytes = <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

  bytes.addAll(
    _section(1, <int>[..._u32Leb(types.length), ...types.expand((e) => e)]),
  );
  bytes.addAll(
    _section(3, <int>[
      ..._u32Leb(functionTypeIndices.length),
      ...functionTypeIndices.expand(_u32Leb),
    ]),
  );

  if (tableSpecs.isNotEmpty) {
    final payload = <int>[..._u32Leb(tableSpecs.length)];
    for (final table in tableSpecs) {
      payload
        ..add(table.$1)
        ..addAll(_limits(table.$2, table.$3));
    }
    bytes.addAll(_section(4, payload));
  }

  if (exports.isNotEmpty) {
    final payload = <int>[..._u32Leb(exports.length)];
    for (final export in exports) {
      payload
        ..addAll(_name(export.$1))
        ..add(export.$2)
        ..addAll(_u32Leb(export.$3));
    }
    bytes.addAll(_section(7, payload));
  }

  if (elementSpecs.isNotEmpty) {
    final payload = <int>[..._u32Leb(elementSpecs.length)];
    for (final element in elementSpecs) {
      if (element.$1 == 0) {
        payload
          ..addAll(_u32Leb(0))
          ..addAll(element.$2)
          ..addAll(_u32Leb(element.$3.length))
          ..addAll(element.$3.expand(_u32Leb));
      } else {
        payload
          ..addAll(_u32Leb(2))
          ..addAll(_u32Leb(element.$1))
          ..addAll(element.$2)
          ..add(0x00)
          ..addAll(_u32Leb(element.$3.length))
          ..addAll(element.$3.expand(_u32Leb));
      }
    }
    bytes.addAll(_section(9, payload));
  }

  final code = <int>[..._u32Leb(functionBodies.length)];
  for (final body in functionBodies) {
    final functionBody = <int>[0x00, ...body];
    code
      ..addAll(_u32Leb(functionBody.length))
      ..addAll(functionBody);
  }
  bytes.addAll(_section(10, code));

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
  final encoded = value.codeUnits;
  return <int>[..._u32Leb(encoded.length), ...encoded];
}

List<int> _limits(int min, int? max) {
  if (max == null) {
    return <int>[0x00, ..._u32Leb(min)];
  }
  return <int>[0x01, ..._u32Leb(min), ..._u32Leb(max)];
}

List<int> _localGet(int index) => <int>[Opcodes.localGet, ..._u32Leb(index)];
List<int> _callIndirect(int typeIndex, int tableIndex) => <int>[
  Opcodes.callIndirect,
  ..._u32Leb(typeIndex),
  ..._u32Leb(tableIndex),
];
List<int> _i32Const(int value) => <int>[Opcodes.i32Const, ..._i32Leb(value)];

List<int> _u32Leb(int value) {
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
