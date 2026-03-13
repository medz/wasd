import 'dart:typed_data';

import '../../memory.dart' as wasm;
import 'interpreter/memory.dart' as ir;

class Memory implements wasm.Memory {
  Memory(wasm.MemoryDescriptor descriptor)
    : _host = ir.WasmMemory(
        minPages: descriptor.initial,
        maxPages: descriptor.maximum,
        shared: descriptor.shared ?? false,
      );

  Memory.fromRuntime(this._host);

  final ir.WasmMemory _host;

  ir.WasmMemory get host => _host;

  @override
  ByteBuffer get buffer => _host.buffer;

  @override
  int grow(int delta) => _host.grow(delta);
}
