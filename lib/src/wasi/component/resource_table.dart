/// A nominal resource type for future WASI component hosts.
///
/// Component Model resources are nominal, so two resource definitions with the
/// same Dart representation type must still have different handle spaces.
final class WASIComponentResourceType<T extends Object> {
  const WASIComponentResourceType._(
    this._tableId,
    this.id,
    this.name,
    this._onDrop,
  );

  final int _tableId;
  final void Function(T resource)? _onDrop;

  /// Table-local resource type identifier.
  final int id;

  /// Debug label used in diagnostics.
  final String name;

  @override
  String toString() => name;

  void _drop(T resource) {
    _onDrop?.call(resource);
  }
}

/// A typed resource table for future WASI component hosts.
///
/// Component resources are represented as opaque integer handles. The table
/// keeps the host objects typed, rejects stale handles, and prevents dropping a
/// resource while it is borrowed by host code.
final class WASIComponentResourceTable {
  static int _nextTableId = 0;

  final int _tableId = _nextTableId++;
  final List<_WASIComponentResourceSlot> _slots =
      <_WASIComponentResourceSlot>[];
  final List<int> _freeSlots = <int>[];
  final Map<int, int> _handleToSlot = <int, int>{};
  int _nextResourceTypeId = 0;
  int _nextHandle = 1;
  int _activeCount = 0;

  /// Number of live resources in the table.
  int get activeCount => _activeCount;

  /// Defines a nominal component resource type backed by Dart values of [T].
  ///
  /// [onDrop] is invoked whenever a handle for this resource type is dropped.
  WASIComponentResourceType<T> defineType<T extends Object>(
    String name, {
    void Function(T resource)? onDrop,
  }) {
    return WASIComponentResourceType<T>._(
      _tableId,
      _nextResourceTypeId++,
      name,
      onDrop,
    );
  }

  /// Inserts [resource] and returns an opaque component handle.
  int insert<T extends Object>(WASIComponentResourceType<T> type, T resource) {
    _validateResourceType(type);
    final slotIndex = _allocateSlot();
    final handle = _allocateHandle();
    final slot = _slots[slotIndex];
    slot.entry = _WASIComponentResourceEntry<T>(type, resource);
    _handleToSlot[handle] = slotIndex;
    _activeCount++;
    return handle;
  }

  /// Implements the canonical ABI `resource.new` operation.
  int resourceNew<T extends Object>(
    WASIComponentResourceType<T> type,
    T representation,
  ) {
    return insert<T>(type, representation);
  }

  /// Returns `true` when [handle] currently refers to a live resource.
  bool contains(int handle) => _entryForHandle(handle) != null;

  /// Returns `true` when [handle] currently refers to a live [type] resource.
  bool containsType<T extends Object>(
    WASIComponentResourceType<T> type,
    int handle,
  ) {
    _validateResourceType(type);
    final entry = _entryForHandle(handle);
    return entry != null && identical(entry.type, type);
  }

  /// Returns the resource for [handle] when it has type [T].
  T get<T extends Object>(WASIComponentResourceType<T> type, int handle) =>
      _typedEntry<T>(type, handle).resource;

  /// Implements the canonical ABI `resource.rep` operation.
  T resourceRep<T extends Object>(
    WASIComponentResourceType<T> type,
    int handle,
  ) {
    return get<T>(type, handle);
  }

  /// Runs [callback] with the resource for [handle] while marking it borrowed.
  R borrow<T extends Object, R>(
    WASIComponentResourceType<T> type,
    int handle,
    R Function(T resource) callback,
  ) {
    final entry = _typedEntry<T>(type, handle);
    entry.borrowCount++;
    try {
      return callback(entry.resource);
    } finally {
      entry.borrowCount--;
    }
  }

  /// Runs async [callback] with the resource for [handle] while it is borrowed.
  ///
  /// The borrow is held until the returned future completes, preventing drops
  /// from invalidating resources that are still used by pending canonical async
  /// operations.
  Future<R> borrowAsync<T extends Object, R>(
    WASIComponentResourceType<T> type,
    int handle,
    Future<R> Function(T resource) callback,
  ) {
    final entry = _typedEntry<T>(type, handle);
    entry.borrowCount++;
    try {
      return callback(entry.resource).whenComplete(() {
        entry.borrowCount--;
      });
    } catch (_) {
      entry.borrowCount--;
      rethrow;
    }
  }

  /// Drops the resource for [handle].
  ///
  /// The optional `onDrop` callback passed to [defineType] is invoked at most
  /// once per handle.
  void drop<T extends Object>(WASIComponentResourceType<T> type, int handle) {
    final entry = _typedEntry<T>(type, handle);
    if (entry.borrowCount != 0) {
      throw StateError(
        'Cannot drop borrowed WASI component resource: $handle.',
      );
    }

    final slotIndex = _handleToSlot.remove(handle)!;
    final slot = _slots[slotIndex];
    slot.entry = null;
    _freeSlots.add(slotIndex);
    _activeCount--;
    entry.drop();
  }

  /// Implements the canonical ABI `resource.drop` operation.
  void resourceDrop<T extends Object>(
    WASIComponentResourceType<T> type,
    int handle,
  ) {
    drop<T>(type, handle);
  }

  int _allocateSlot() {
    if (_freeSlots.isNotEmpty) {
      return _freeSlots.removeLast();
    }
    _slots.add(_WASIComponentResourceSlot());
    return _slots.length - 1;
  }

  int _allocateHandle() {
    if (_nextHandle > _maxComponentResourceHandle) {
      throw StateError('WASI component resource table exhausted u32 handles.');
    }
    return _nextHandle++;
  }

  _WASIComponentResourceEntry? _entryForHandle(int handle) {
    final slotIndex = _handleToSlot[handle];
    if (slotIndex == null) {
      return null;
    }

    final slot = _slots[slotIndex];
    return slot.entry;
  }

  _WASIComponentResourceEntry<T> _typedEntry<T extends Object>(
    WASIComponentResourceType<T> type,
    int handle,
  ) {
    _validateResourceType(type);
    final entry = _entryForHandle(handle);
    if (entry == null) {
      throw StateError('Unknown WASI component resource handle: $handle.');
    }
    if (!identical(entry.type, type)) {
      throw StateError(
        'WASI component resource handle $handle does not contain $type.',
      );
    }
    return entry as _WASIComponentResourceEntry<T>;
  }

  void _validateResourceType(WASIComponentResourceType<Object> type) {
    if (type._tableId != _tableId) {
      throw StateError(
        'WASI component resource type ${type.name} belongs to another table.',
      );
    }
  }
}

const int _maxComponentResourceHandle = 0xffffffff;

final class _WASIComponentResourceSlot {
  _WASIComponentResourceEntry? entry;
}

final class _WASIComponentResourceEntry<T extends Object> {
  _WASIComponentResourceEntry(this.type, this.resource);

  final WASIComponentResourceType<T> type;
  final T resource;
  int borrowCount = 0;

  void drop() {
    type._drop(resource);
  }
}
