import 'dart:async';

/// A nominal resource type for WASI component hosts.
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

/// A typed resource table for WASI component hosts.
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
  final _WASIComponentResourceTypeCounts _unscopedResourceTypeCounts =
      <String, Map<WASIComponentResourceType<Object>, int>>{};
  final Object _scopeZoneKey = Object();
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
    return _insert<T>(type, resource, scoped: true);
  }

  /// Inserts a host-owned resource that outlives the current runtime scope.
  int insertPersistent<T extends Object>(
    WASIComponentResourceType<T> type,
    T resource,
  ) {
    return _insert<T>(type, resource, scoped: false);
  }

  int _insert<T extends Object>(
    WASIComponentResourceType<T> type,
    T resource, {
    required bool scoped,
  }) {
    _validateResourceType(type);
    final ambientScope = _currentScope;
    if (ambientScope?.isClosed ?? false) {
      throw StateError(
        'Cannot allocate a WASI component resource after its scope closed.',
      );
    }
    final slotIndex = _allocateSlot();
    final handle = _allocateHandle();
    final slot = _slots[slotIndex];
    final scope = scoped ? ambientScope : null;
    slot.entry = _WASIComponentResourceEntry<T>(type, resource, scope);
    _handleToSlot[handle] = slotIndex;
    _activeCount++;
    scope?._handles.add(handle);
    _recordResourceType(type, scope);
    return handle;
  }

  /// Runs [callback] in an allocation scope and drops any handles it leaks.
  ///
  /// Scopes use Dart's asynchronous zone context, so concurrent component
  /// executions over one shared host keep their allocations isolated.
  Future<T> runScoped<T>(FutureOr<T> Function() callback) {
    final scope = _WASIComponentResourceScope(this);
    return runZoned<Future<T>>(() async {
      var callbackCompleted = false;
      try {
        final result = await callback();
        callbackCompleted = true;
        scope.close();
        return result;
      } catch (error, stackTrace) {
        if (!callbackCompleted) {
          try {
            scope.close();
          } catch (_) {
            // Preserve the component failure after making a best-effort cleanup.
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
        rethrow;
      }
    }, zoneValues: <Object, Object>{_scopeZoneKey: scope});
  }

  /// Implements the canonical ABI `resource.new` operation.
  int resourceNew<T extends Object>(
    WASIComponentResourceType<T> type,
    T representation,
  ) {
    return insert<T>(type, representation);
  }

  /// Returns `true` when [handle] currently refers to a live resource.
  bool contains(int handle) {
    final entry = _entryForHandle(handle);
    return entry != null && _canAccessEntry(entry);
  }

  /// Returns `true` when [handle] currently refers to a live [type] resource.
  bool containsType<T extends Object>(
    WASIComponentResourceType<T> type,
    int handle,
  ) {
    _validateResourceType(type);
    final entry = _entryForHandle(handle);
    return entry != null &&
        _canAccessEntry(entry) &&
        identical(entry.type, type);
  }

  /// Returns the resource for [handle] when it has type [T].
  T get<T extends Object>(WASIComponentResourceType<T> type, int handle) =>
      _typedEntry<T>(type, handle).resource;

  /// Removes an owned [handle] and returns its host representation.
  ///
  /// Ownership transfer invalidates the handle without invoking the resource
  /// destructor registered through [defineType].
  T take<T extends Object>(WASIComponentResourceType<T> type, int handle) {
    final entry = _typedEntry<T>(type, handle);
    _removeEntry(handle, entry);
    return entry.resource;
  }

  /// Records that [childHandle] must be released before [parentHandle].
  void attachChild(int parentHandle, int childHandle) {
    if (parentHandle == childHandle) {
      throw StateError('A WASI component resource cannot be its own child.');
    }
    final parent = _entryForHandle(parentHandle);
    final child = _entryForHandle(childHandle);
    if (parent == null) {
      throw StateError(
        'Unknown WASI component resource handle: $parentHandle.',
      );
    }
    if (child == null) {
      throw StateError('Unknown WASI component resource handle: $childHandle.');
    }
    _validateScopeAccess(parentHandle, parent);
    _validateScopeAccess(childHandle, child);
    if (!identical(parent.scope, child.scope)) {
      throw StateError(
        'WASI component parent and child resources must belong to the same '
        'runtime scope.',
      );
    }
    if (child.parentHandle != null) {
      throw StateError(
        'WASI component resource $childHandle already has a parent.',
      );
    }
    var ancestorHandle = parentHandle;
    while (true) {
      if (ancestorHandle == childHandle) {
        throw StateError('WASI component resource child cycle detected.');
      }
      final ancestor = _entryForHandle(ancestorHandle);
      final next = ancestor?.parentHandle;
      if (next == null) {
        break;
      }
      ancestorHandle = next;
    }
    child.parentHandle = parentHandle;
    parent.childHandles.add(childHandle);
  }

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
    _dropEntry(handle, entry);
  }

  /// Drops [handle] when its nominal type has [expectedTypeName].
  ///
  /// This is used when a validated component imports an abstract resource and
  /// the concrete host type is identified by its canonical WIT resource name.
  void dropNamed(String expectedTypeName, int handle) {
    final entry = _entryForHandle(handle);
    if (entry == null) {
      throw StateError('Unknown WASI component resource handle: $handle.');
    }
    _validateScopeAccess(handle, entry);
    if (entry.type.name != expectedTypeName) {
      throw StateError(
        'WASI component resource handle $handle does not contain '
        '$expectedTypeName.',
      );
    }
    final namedTypes = _resourceTypeCounts(entry.scope)[expectedTypeName];
    if (namedTypes == null || namedTypes.length != 1) {
      throw StateError(
        'WASI component resource type name $expectedTypeName is ambiguous.',
      );
    }
    if (!identical(entry.type, namedTypes.keys.single)) {
      throw StateError(
        'WASI component resource handle $handle has a different nominal '
        '$expectedTypeName type.',
      );
    }
    _dropEntry(handle, entry);
  }

  void _dropEntry(int handle, _WASIComponentResourceEntry entry) {
    _removeEntry(handle, entry);
    entry.drop();
  }

  void _removeEntry(int handle, _WASIComponentResourceEntry entry) {
    if (entry.borrowCount != 0) {
      throw StateError(
        'Cannot release borrowed WASI component resource: $handle.',
      );
    }
    if (entry.childHandles.isNotEmpty) {
      throw StateError(
        'Cannot release WASI component resource $handle while child handles '
        '${entry.childHandles.join(', ')} are live.',
      );
    }

    final slotIndex = _handleToSlot.remove(handle)!;
    final slot = _slots[slotIndex];
    slot.entry = null;
    _freeSlots.add(slotIndex);
    _activeCount--;
    entry.scope?._handles.remove(handle);
    _forgetResourceType(entry.type, entry.scope);
    final parentHandle = entry.parentHandle;
    if (parentHandle != null) {
      _entryForHandle(parentHandle)?.childHandles.remove(handle);
    }
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
    _validateScopeAccess(handle, entry);
    if (!identical(entry.type, type)) {
      throw StateError(
        'WASI component resource handle $handle does not contain $type.',
      );
    }
    return entry as _WASIComponentResourceEntry<T>;
  }

  bool _canAccessEntry(_WASIComponentResourceEntry entry) {
    final scope = _currentScope;
    return scope == null || (!scope.isClosed && identical(entry.scope, scope));
  }

  void _validateScopeAccess(int handle, _WASIComponentResourceEntry entry) {
    if (!_canAccessEntry(entry)) {
      throw StateError(
        'WASI component resource handle $handle belongs to another runtime '
        'scope.',
      );
    }
  }

  _WASIComponentResourceTypeCounts _resourceTypeCounts(
    _WASIComponentResourceScope? scope,
  ) => scope?._resourceTypeCounts ?? _unscopedResourceTypeCounts;

  void _recordResourceType(
    WASIComponentResourceType<Object> type,
    _WASIComponentResourceScope? scope,
  ) {
    final counts = _resourceTypeCounts(scope);
    final namedTypes = counts[type.name] ??=
        <WASIComponentResourceType<Object>, int>{};
    namedTypes[type] = (namedTypes[type] ?? 0) + 1;
  }

  void _forgetResourceType(
    WASIComponentResourceType<Object> type,
    _WASIComponentResourceScope? scope,
  ) {
    final counts = _resourceTypeCounts(scope);
    final namedTypes = counts[type.name]!;
    final count = namedTypes[type]!;
    if (count == 1) {
      namedTypes.remove(type);
      if (namedTypes.isEmpty) {
        counts.remove(type.name);
      }
      return;
    }
    namedTypes[type] = count - 1;
  }

  void _validateResourceType(WASIComponentResourceType<Object> type) {
    if (type._tableId != _tableId) {
      throw StateError(
        'WASI component resource type ${type.name} belongs to another table.',
      );
    }
  }

  _WASIComponentResourceScope? get _currentScope {
    final value = Zone.current[_scopeZoneKey];
    return value is _WASIComponentResourceScope && identical(value.table, this)
        ? value
        : null;
  }
}

const int _maxComponentResourceHandle = 0xffffffff;

typedef _WASIComponentResourceTypeCounts =
    Map<String, Map<WASIComponentResourceType<Object>, int>>;

final class _WASIComponentResourceSlot {
  _WASIComponentResourceEntry? entry;
}

final class _WASIComponentResourceEntry<T extends Object> {
  _WASIComponentResourceEntry(this.type, this.resource, this.scope);

  final WASIComponentResourceType<T> type;
  final T resource;
  final _WASIComponentResourceScope? scope;
  final Set<int> childHandles = <int>{};
  int? parentHandle;
  int borrowCount = 0;

  void drop() {
    type._drop(resource);
  }
}

final class _WASIComponentResourceScope {
  _WASIComponentResourceScope(this.table);

  final WASIComponentResourceTable table;
  final Set<int> _handles = <int>{};
  final _WASIComponentResourceTypeCounts _resourceTypeCounts =
      <String, Map<WASIComponentResourceType<Object>, int>>{};
  bool _closing = false;
  bool _closed = false;

  bool get isClosed => _closed;

  void close() {
    if (_closed || _closing) {
      return;
    }
    _closing = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      while (_handles.isNotEmpty) {
        var released = false;
        final handles = _handles.toList(growable: false).reversed;
        for (final handle in handles) {
          final entry = table._entryForHandle(handle);
          if (entry == null) {
            _handles.remove(handle);
            released = true;
            continue;
          }
          if (entry.borrowCount != 0 || entry.childHandles.isNotEmpty) {
            continue;
          }
          try {
            table._dropEntry(handle, entry);
          } catch (error, stackTrace) {
            firstError ??= error;
            firstStackTrace ??= stackTrace;
          }
          released = table._entryForHandle(handle) == null || released;
        }
        if (!released) {
          firstError ??= StateError(
            'Cannot close WASI component resource scope with live borrows or '
            'child handles: ${_handles.join(', ')}.',
          );
          firstStackTrace ??= StackTrace.current;
          break;
        }
      }
    } finally {
      _closing = false;
      _closed = true;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }
}
