import 'dart:typed_data';

import '../../memory.dart' as wasm;
import 'interpreter/memory.dart' as old;

class Memory implements wasm.Memory {
  Memory(wasm.MemoryDescriptor descriptor)
    : host = old.WasmMemory(
        minPages: descriptor.initial,
        maxPages: descriptor.maximum,
      );

  Memory.fromHost(this.host);

  final old.WasmMemory host;

  /// Returns a live view of the current underlying buffer.
  ///
  /// The returned [ByteBuffer] is re-fetched on every access so that it
  /// reflects the correct allocation after a [grow] call.
  @override
  ByteBuffer get buffer => host.viewBytes(0, host.lengthInBytes).buffer;

  @override
  int grow(int delta) => host.grow(delta);
}
