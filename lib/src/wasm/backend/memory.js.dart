library;

import 'dart:typed_data';
import 'dart:js_interop';

import '../memory.dart' as wasm;

class Memory implements wasm.Memory {
  Memory(wasm.MemoryDescriptor descriptor)
    : host = JSMemory(
        MemoryDescriptor(
          initial: descriptor.initial,
          maximum: descriptor.maximum,
          shared: descriptor.shared,
        ),
      );

  final JSMemory host;

  @override
  ByteBuffer get buffer => host.buffer.toDart;

  @override
  int grow(int delta) => host.grow(delta);
}

extension type MemoryDescriptor._(JSObject _) implements JSObject {
  external factory MemoryDescriptor({
    required int initial,
    int? maximum,
    bool? shared,
  });
}

@JS('WebAssembly.Memory')
extension type JSMemory._(JSObject _) implements JSObject {
  external factory JSMemory(MemoryDescriptor descriptor);

  external int grow(int delta);
  external JSArrayBuffer get buffer;
}
