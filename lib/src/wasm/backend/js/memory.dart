@JS()
library;

import 'dart:typed_data';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../memory.dart' as wasm;

class Memory implements wasm.Memory {
  Memory(wasm.MemoryDescriptor descriptor)
    : host = JSMemory(_toHostMemoryDescriptor(descriptor));

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

MemoryDescriptor _toHostMemoryDescriptor(wasm.MemoryDescriptor descriptor) {
  final object = JSObject()..['initial'] = descriptor.initial.toJS;
  final maximum = descriptor.maximum;
  if (maximum != null) {
    object['maximum'] = maximum.toJS;
  }
  final shared = descriptor.shared;
  if (shared != null) {
    object['shared'] = shared.toJS;
  }
  return MemoryDescriptor._(object);
}
