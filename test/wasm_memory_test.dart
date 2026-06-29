import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/memory.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/runtime_ops.dart';

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

  group('RuntimeMemoryOps.initFromDataSegment', () {
    test('validates zero-length source bounds after data.drop', () {
      final memory = WasmMemory(minPages: 1);

      expect(
        () => RuntimeMemoryOps.initFromDataSegment(
          segment: null,
          segmentIndex: 0,
          memory: memory,
          sourceOffset: 0,
          destinationOffset: memory.lengthInBytes,
          length: 0,
        ),
        returnsNormally,
      );

      expect(
        () => RuntimeMemoryOps.initFromDataSegment(
          segment: null,
          segmentIndex: 0,
          memory: memory,
          sourceOffset: 1,
          destinationOffset: 0,
          length: 0,
        ),
        throwsStateError,
      );

      expect(
        () => RuntimeMemoryOps.initFromDataSegment(
          segment: null,
          segmentIndex: 0,
          memory: memory,
          sourceOffset: 0,
          destinationOffset: memory.lengthInBytes + 1,
          length: 0,
        ),
        throwsStateError,
      );
    });
  });
}
