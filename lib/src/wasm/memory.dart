import 'dart:typed_data';

import 'backend/memory.dart'
    if (dart.library.js_interop) 'backend/memory.js.dart'
    as backend;

/// Describes limits and behavior of a WebAssembly linear memory.
class MemoryDescriptor {
  /// Creates a memory descriptor.
  const MemoryDescriptor({required this.initial, this.maximum, this.shared});

  /// Initial memory size in WebAssembly pages (64 KiB per page).
  final int initial;

  /// Optional maximum memory size in pages.
  final int? maximum;

  /// Whether this memory is shared between agents/threads.
  final bool? shared;
}

/// Minimal linear memory interface.
abstract interface class Memory {
  /// Creates a memory from [descriptor].
  factory Memory(MemoryDescriptor descriptor) = backend.Memory;

  /// Raw underlying buffer of the memory.
  ByteBuffer get buffer;

  /// Grows memory by [delta] pages and returns previous size.
  int grow(int delta);
}
