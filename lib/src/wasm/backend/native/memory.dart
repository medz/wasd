import 'dart:typed_data';

import '../../memory.dart' as wasm;
import 'runtime.dart' as rt;

class Memory implements wasm.Memory {
  Memory(wasm.MemoryDescriptor descriptor)
    : _host = rt.LinearMemory(
        minPages: descriptor.initial,
        maxPages: descriptor.maximum,
      );

  Memory.fromRuntime(this._host);

  final rt.LinearMemory _host;

  @override
  ByteBuffer get buffer => _host.buffer;

  @override
  int grow(int delta) => _host.grow(delta);
}
