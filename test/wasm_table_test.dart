import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/module.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/table.dart';

void main() {
  group('WasmTable.copyEntries', () {
    test('copies overlapping ranges as if through a temporary snapshot', () {
      final table = WasmTable(refType: WasmRefType.funcref, min: 6)
        ..initialize(0, <int?>[0, 1, 2, 3, 4, 5]);

      table.copyEntries(
        source: table,
        destinationOffset: 2,
        sourceOffset: 0,
        length: 4,
      );

      expect(table.snapshot(), <int?>[0, 1, 0, 1, 2, 3]);

      table.copyEntries(
        source: table,
        destinationOffset: 0,
        sourceOffset: 2,
        length: 4,
      );

      expect(table.snapshot(), <int?>[0, 1, 2, 3, 2, 3]);
    });

    test('copies entries between tables', () {
      final source = WasmTable(refType: WasmRefType.funcref, min: 4)
        ..initialize(0, <int?>[7, null, 9, 10]);
      final target = WasmTable(refType: WasmRefType.funcref, min: 4);

      target.copyEntries(
        source: source,
        destinationOffset: 1,
        sourceOffset: 0,
        length: 3,
      );

      expect(target.snapshot(), <int?>[null, 7, null, 9]);
    });
  });
}
