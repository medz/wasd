import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/memory.dart';

void main() {
  group('WasmMemory.grow', () {
    test('grow by zero returns the current size without changing memory', () {
      final memory = WasmMemory(minPages: 1);
      memory.storeI32(0, 42);

      final previousPages = memory.grow(0);

      expect(previousPages, 1);
      expect(memory.pageCount, 1);
      expect(memory.lengthInBytes, wasmPageSize);
      expect(memory.loadI32(0), 42);
    });
  });
}
