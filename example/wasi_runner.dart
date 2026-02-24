import 'dart:convert';
import 'dart:typed_data';

import 'package:pure_wasm_runtime/pure_wasm_runtime.dart';

void main() {
  final runner = WasiRunner();
  final exitCode = runner.runStartFromBytes(_buildProcExitModule());
  print('wasi _start exit code = $exitCode');
}

Uint8List _buildProcExitModule() {
  return _buildModule(
    types: [
      _funcType([0x7f], []),
      _funcType([], []),
    ],
    imports: const [('wasi_snapshot_preview1', 'proc_exit', 0)],
    functionTypeIndices: [1],
    functionBodies: [
      [..._i32Const(7), ..._call(0), Opcodes.end],
    ],
    exports: const [('_start', WasmExportKind.function, 1)],
  );
}

Uint8List _buildModule({
  required List<List<int>> types,
  required List<(String, String, int)> imports,
  required List<int> functionTypeIndices,
  required List<List<int>> functionBodies,
  List<(String, int, int)> exports = const [],
}) {
  final bytes = <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

  bytes.addAll(
    _section(1, <int>[..._u32Leb(types.length), ...types.expand((it) => it)]),
  );

  if (imports.isNotEmpty) {
    final payload = <int>[..._u32Leb(imports.length)];
    for (final import in imports) {
      payload
        ..addAll(_name(import.$1))
        ..addAll(_name(import.$2))
        ..add(WasmImportKind.function)
        ..addAll(_u32Leb(import.$3));
    }
    bytes.addAll(_section(2, payload));
  }

  bytes.addAll(
    _section(3, <int>[
      ..._u32Leb(functionTypeIndices.length),
      ...functionTypeIndices.expand(_u32Leb),
    ]),
  );

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

  final codePayload = <int>[..._u32Leb(functionBodies.length)];
  for (final instructions in functionBodies) {
    final functionBody = <int>[0x00, ...instructions];
    codePayload
      ..addAll(_u32Leb(functionBody.length))
      ..addAll(functionBody);
  }
  bytes.addAll(_section(10, codePayload));

  return Uint8List.fromList(bytes);
}

List<int> _section(int id, List<int> payload) => <int>[
  id,
  ..._u32Leb(payload.length),
  ...payload,
];

List<int> _funcType(List<int> params, List<int> results) => <int>[
  0x60,
  ..._u32Leb(params.length),
  ...params,
  ..._u32Leb(results.length),
  ...results,
];

List<int> _name(String value) {
  final encoded = utf8.encode(value);
  return <int>[..._u32Leb(encoded.length), ...encoded];
}

List<int> _call(int index) => <int>[Opcodes.call, ..._u32Leb(index)];

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
