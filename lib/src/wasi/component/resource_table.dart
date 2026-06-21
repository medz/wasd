/// A typed resource table for future WASI component hosts.
///
/// Component resources are represented as opaque integer handles. The table
/// keeps the host objects typed, rejects stale handles, and prevents dropping a
/// resource while it is borrowed by host code.
final class WASIComponentResourceTable {
  final List<_WASIComponentResourceSlot> _slots =
      <_WASIComponentResourceSlot>[];
  final List<int> _freeSlots = <int>[];
  int _activeCount = 0;

  /// Number of live resources in the table.
  int get activeCount => _activeCount;

  /// Inserts [resource] and returns an opaque component handle.
  int insert<T extends Object>(
    T resource, {
    void Function(T resource)? onDrop,
  }) {
    final slotIndex = _allocateSlot();
    final slot = _slots[slotIndex];
    slot.generation++;
    slot.entry = _WASIComponentResourceEntry<T>(resource, onDrop);
    _activeCount++;
    return _handleFor(slotIndex, slot.generation);
  }

  /// Returns `true` when [handle] currently refers to a live resource.
  bool contains(int handle) => _entryForHandle(handle) != null;

  /// Returns the resource for [handle] when it has type [T].
  T get<T extends Object>(int handle) => _typedEntry<T>(handle).resource;

  /// Runs [callback] with the resource for [handle] while marking it borrowed.
  R borrow<T extends Object, R>(int handle, R Function(T resource) callback) {
    final entry = _typedEntry<T>(handle);
    entry.borrowCount++;
    try {
      return callback(entry.resource);
    } finally {
      entry.borrowCount--;
    }
  }

  /// Drops the resource for [handle].
  ///
  /// The optional `onDrop` callback passed to [insert] is invoked at most once.
  void drop<T extends Object>(int handle) {
    final entry = _typedEntry<T>(handle);
    if (entry.borrowCount != 0) {
      throw StateError(
        'Cannot drop borrowed WASI component resource: $handle.',
      );
    }

    final slotIndex = _slotIndexForHandle(handle);
    final slot = _slots[slotIndex];
    slot.entry = null;
    _freeSlots.add(slotIndex);
    _activeCount--;
    entry.drop();
  }

  int _allocateSlot() {
    if (_freeSlots.isNotEmpty) {
      return _freeSlots.removeLast();
    }
    _slots.add(_WASIComponentResourceSlot());
    return _slots.length - 1;
  }

  _WASIComponentResourceEntry? _entryForHandle(int handle) {
    final slotIndex = _slotIndexForHandle(handle);
    if (slotIndex < 0 || slotIndex >= _slots.length) {
      return null;
    }

    final generation = _generationForHandle(handle);
    final slot = _slots[slotIndex];
    if (slot.generation != generation) {
      return null;
    }
    return slot.entry;
  }

  _WASIComponentResourceEntry<T> _typedEntry<T extends Object>(int handle) {
    final entry = _entryForHandle(handle);
    if (entry == null) {
      throw StateError('Unknown WASI component resource handle: $handle.');
    }
    if (entry is! _WASIComponentResourceEntry<T>) {
      throw StateError(
        'WASI component resource handle $handle does not contain $T.',
      );
    }
    return entry;
  }
}

const int _slotBase = 1 << 26;

int _handleFor(int slotIndex, int generation) =>
    generation * _slotBase + slotIndex;

int _slotIndexForHandle(int handle) => handle % _slotBase;

int _generationForHandle(int handle) => handle ~/ _slotBase;

final class _WASIComponentResourceSlot {
  int generation = 0;
  _WASIComponentResourceEntry? entry;
}

final class _WASIComponentResourceEntry<T extends Object> {
  _WASIComponentResourceEntry(this.resource, this.onDrop);

  final T resource;
  final void Function(T resource)? onDrop;
  int borrowCount = 0;

  void drop() {
    onDrop?.call(resource);
  }
}
