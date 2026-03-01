import 'dart:typed_data';

import '../../memory.dart' as wasm;

class Memory implements wasm.Memory {
  Memory(wasm.MemoryDescriptor descriptor);

  @override
  ByteBuffer get buffer => throw UnimplementedError();

  @override
  int grow(int delta) {
    throw UnimplementedError();
  }
}
