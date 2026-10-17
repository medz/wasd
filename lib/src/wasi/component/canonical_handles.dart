// Internal execution state; deliberately absent from package entrypoints.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'adapter_host.dart';
import 'adapter_plan.dart';
import 'async_host.dart';
import 'async_values.dart';
import 'context.dart';
import 'error_context.dart';
import 'resource_table.dart';
import 'waitable_set.dart';

final _errorCarrierKey = Object();
final _ownedReadableEndpoints = Expando<bool>(
  'canonical readable endpoint owner',
);

/// Runtime resource provenance. Aliases forward this object; instances create it.
final class WASIComponentCanonicalResourceIdentity {
  WASIComponentCanonicalResourceIdentity(this.type, this.implementor);
  WASIComponentResourceType<Object>? type;
  final WASIComponentCanonicalHandles? implementor;
}

enum WASIComponentCanonicalHandleKind {
  resource,
  streamReadable,
  streamWritable,
  futureReadable,
  futureWritable,
  subtask,
  waitableSet,
  errorContext,
}

final class _Handle {
  const _Handle(this.host, this.kind);
  final int host;
  final WASIComponentCanonicalHandleKind kind;
}

/// The normative reserved-zero/LIFO index space, independent of host handles.
final class WASIComponentCanonicalIndexTable<T extends Object> {
  final List<T?> _entries = [null];
  final List<int> _free = [];
  void requireCapacity(int count) {
    if (count > _free.length + 0x10000000 - _entries.length) {
      throw StateError('Component handle table exhausted.');
    }
  }

  int add(T value) {
    if (_free.isNotEmpty) {
      final index = _free.removeLast();
      _entries[index] = value;
      return index;
    }
    if (_entries.length > 0x0fffffff) {
      throw StateError('Component handle table exhausted.');
    }
    _entries.add(value);
    return _entries.length - 1;
  }

  T get(int index) {
    if (index <= 0 || index >= _entries.length || _entries[index] == null) {
      throw StateError('Unknown component handle index: $index.');
    }
    return _entries[index]!;
  }

  T remove(int index) {
    final value = get(index);
    _entries[index] = null;
    _free.add(index);
    return value;
  }
}

/// One executing instance's guest handles over its store's shared host table.
final class WASIComponentCanonicalHandles
    implements
        WASIComponentCanonicalHandleBindings,
        WASIComponentCanonicalHandleOwner {
  WASIComponentCanonicalHandles({
    required this.table,
    required this.errorContexts,
    required this.resourceIdentity,
    required this.adapterResourceIdentity,
    required this.contextHost,
    this.collectErrorCarriers,
  });
  final WASIComponentResourceTable table;
  final WASIComponentErrorContextHost errorContexts;
  final WASIComponentContextHost contextHost;
  final bool Function(int canonicalIndex)? collectErrorCarriers;
  final WASIComponentCanonicalResourceIdentity Function(int index)
  resourceIdentity;
  final WASIComponentCanonicalResourceIdentity Function(
    int canonicalIndex,
    int typeIndex,
  )
  adapterResourceIdentity;
  late WASIComponentAsyncEndpointBindings asyncBindings;
  final _handles = WASIComponentCanonicalIndexTable<_Handle>();
  final _hostToGuest = <int, int>{};
  final _endpointByHost = <int, Object>{};
  final _callKey = Object();
  final threads = WASIComponentCanonicalIndexTable<WASIComponentContext>();
  final _threadKey = Object();

  void requireCapacity(int count) => _handles.requireCapacity(count);

  int get currentThread =>
      Zone.current[_threadKey] as int? ??
      (throw StateError('No active component implicit thread.'));

  T withThread<T>(T Function() callback) {
    final context = WASIComponentContext();
    final index = threads.add(context);
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      threads.remove(index);
    }

    try {
      final result = runZoned(
        () => contextHost.runWithCanonicalContext(context, callback),
        zoneValues: {_threadKey: index},
      );
      if (result is Future) return result.whenComplete(close) as T;
      close();
      return result;
    } catch (_) {
      close();
      rethrow;
    }
  }

  @override
  T withHandleCall<T>(
    T Function() callback, {
    void Function(void Function() close)? retain,
    bool? internalCall,
  }) {
    final scope = table.createBorrowCallScope();
    final errorCarriers = internalCall == true
        ? <(WASIComponentErrorContextHost, int)>[]
        : null;
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      try {
        scope.close();
      } finally {
        if (errorCarriers != null) {
          for (final (host, handle) in errorCarriers.reversed) {
            if (host.table.contains(handle)) host.drop(handle);
          }
        }
      }
    }

    try {
      final result = runZoned(
        callback,
        zoneValues: {
          _callKey: scope,
          if (internalCall != null) _errorCarrierKey: errorCarriers,
        },
      );
      if (retain != null) {
        retain(close);
        return result;
      }
      if (result is Future) return result.whenComplete(close) as T;
      close();
      return result;
    } catch (_) {
      close();
      rethrow;
    }
  }

  /// Installs typed copy conversion once for this instance's binding registry.
  void bindAsyncValues(
    WASIComponentAsyncValueBindingSet bindings,
    Iterable<WASIComponentAsyncValueBinding> descriptors,
    WASIComponentCanonicalResourceIdentity Function(
      WASIComponentAsyncValueBinding binding,
      int index,
    )
    identity,
  ) {
    final layouts = <int, WASIComponentCanonicalAdapterFlatValuePlan?>{};
    final handleLayouts = <int>{};
    bool containsHandle(WASIComponentCanonicalAdapterFlatValuePlan? layout) =>
        layout != null &&
        (layout.kind == WASIComponentCanonicalAdapterFlatValueKind.resource ||
            layout.kind ==
                WASIComponentCanonicalAdapterFlatValueKind.errorContext ||
            layout.kind == WASIComponentCanonicalAdapterFlatValueKind.stream ||
            layout.kind == WASIComponentCanonicalAdapterFlatValueKind.future ||
            layout.fields.any((field) => containsHandle(field.value)) ||
            layout.cases.any((item) => containsHandle(item.value)) ||
            containsHandle(layout.element) ||
            containsHandle(layout.ok) ||
            containsHandle(layout.error));
    for (final descriptor in descriptors) {
      final element = descriptor.canonicalElementType;
      final layout = element == null
          ? null
          : componentCanonicalFlatLayout(
              element,
              descriptor.canonicalReferenceDefinitions,
            );
      layouts[descriptor.componentTypeIndex] = layout;
      if (containsHandle(layout)) {
        handleLayouts.add(descriptor.componentTypeIndex);
      }
    }
    _PayloadHandleBindings boundary(
      WASIComponentAsyncValueBinding binding,
      _PayloadMode mode,
    ) =>
        _PayloadHandleBindings(this, (index) => identity(binding, index), mode);
    Object? convert(
      WASIComponentAsyncValueBinding binding,
      Object? value,
      _PayloadHandleBindings converter, {
      required bool lift,
    }) {
      final layout = layouts[binding.componentTypeIndex];
      if (layout == null) return value;
      return lift
          ? liftWASIComponentCanonicalMemoryHandles(layout, value, converter)
          : lowerWASIComponentCanonicalMemoryHandles(layout, value, converter);
    }

    void discard(WASIComponentAsyncValueBinding binding, Object? value) {
      if (!handleLayouts.contains(binding.componentTypeIndex)) return;
      final release = boundary(binding, _PayloadMode.discard);
      convert(binding, value, release, lift: false);
      release.finishDiscard();
    }

    bindings.bindCanonicalValues(
      owner: this,
      typeKey: (binding) {
        final parts = <Object?>[binding.kind];
        _payloadTypeParts(
          layouts[binding.componentTypeIndex],
          (index) => identity(binding, index),
          parts,
        );
        return _PayloadTypeKey(parts);
      },
      lift: (binding, values) {
        if (!handleLayouts.contains(binding.componentTypeIndex)) return values;
        // Validate every accepted owner, including duplicates, before removing any G.
        final check = boundary(binding, _PayloadMode.checkLift);
        for (final value in values) {
          convert(binding, value, check, lift: true);
        }
        final move = boundary(binding, _PayloadMode.lift);
        return [
          for (final value in values) convert(binding, value, move, lift: true),
        ];
      },
      lower: (binding, values, store) {
        if (!handleLayouts.contains(binding.componentTypeIndex)) {
          store(values);
          return;
        }
        final check = boundary(binding, _PayloadMode.checkLower);
        final move = boundary(binding, _PayloadMode.lower);
        try {
          for (final value in values) {
            convert(binding, value, check, lift: false);
          }
          final raw = [
            for (final value in values)
              convert(binding, value, move, lift: false),
          ];
          store(raw);
        } catch (error, stackTrace) {
          for (final index in move.created) {
            remove(index);
          }
          for (final value in values) {
            try {
              discard(binding, value);
            } catch (_) {
              /* Preserve the copy failure after releasing every accepted owner. */
            }
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      },
      discard: discard,
    );
  }

  @override
  void canonicalHandleRemoved(int backing) {
    final guest = _hostToGuest.remove(backing);
    _releaseEndpoint(backing);
    if (guest != null) _handles.remove(guest);
  }

  void _releaseEndpoint(int host) {
    final endpoint = _endpointByHost.remove(host);
    if (endpoint != null) _ownedReadableEndpoints[endpoint] = null;
  }

  int add(int host, WASIComponentCanonicalHandleKind kind) {
    final endpoint =
        kind == WASIComponentCanonicalHandleKind.streamReadable ||
            kind == WASIComponentCanonicalHandleKind.futureReadable
        ? table.canonicalValueOf(host)
        : null;
    if (endpoint != null && _ownedReadableEndpoints[endpoint] == true) {
      throw StateError(
        'Readable endpoint is already owned by a component instance.',
      );
    }
    table.canonicalClaim(host, this);
    try {
      final guest = _handles.add(_Handle(host, kind));
      _hostToGuest[host] = guest;
      if (endpoint != null) {
        _ownedReadableEndpoints[endpoint] = true;
        _endpointByHost[host] = endpoint;
      }
      return guest;
    } catch (_) {
      table.canonicalRelease(host, this);
      rethrow;
    }
  }

  int host(int guest, {WASIComponentCanonicalHandleKind? kind}) {
    final entry = _handles.get(guest);
    if (kind != null && entry.kind != kind) {
      throw StateError('Component handle $guest has a different kind.');
    }
    if (!table.contains(entry.host)) {
      throw StateError('Unknown component handle index: $guest.');
    }
    return entry.host;
  }

  int guest(int host) =>
      _hostToGuest[host] ??
      (throw StateError('Waitable belongs to a different component instance.'));

  int remove(int guest) {
    final entry = _handles.remove(guest);
    _hostToGuest.remove(entry.host);
    _releaseEndpoint(entry.host);
    if (table.contains(entry.host)) table.canonicalRelease(entry.host, this);
    return entry.host;
  }

  @override
  WASIComponentCanonicalHandleBindings forCanonicalAdapter(
    int canonicalIndex,
  ) => _AdapterHandleBindings(this, canonicalIndex);

  WASIComponentCanonicalResourceIdentity _identity(
    int index,
    int? canonicalIndex,
  ) => canonicalIndex == null
      ? resourceIdentity(index)
      : adapterResourceIdentity(canonicalIndex, index);

  WASIComponentResourceType<Object> _type(
    int index,
    int host, [
    int? canonicalIndex,
  ]) {
    final identity = _identity(index, canonicalIndex);
    final expected = identity.type;
    if (expected == null) {
      throw StateError('Unbound runtime resource type: $index.');
    }
    if (!identical(table.canonicalTypeOf(host), expected)) {
      throw StateError(
        'WASI component resource handle $host does not contain $expected.',
      );
    }
    return expected;
  }

  int newResource(int index, Object representation) {
    requireCapacity(1);
    final type = resourceIdentity(index).type;
    if (type == null) {
      throw StateError('Unbound runtime resource type: $index.');
    }
    final backing = table.resourceNew(type, representation);
    try {
      return add(backing, WASIComponentCanonicalHandleKind.resource);
    } catch (_) {
      table.drop(type, backing);
      rethrow;
    }
  }

  Object resourceRep(int index, int guest) {
    final backing = host(
      guest,
      kind: WASIComponentCanonicalHandleKind.resource,
    );
    return table.resourceRep(_type(index, backing), backing);
  }

  void resourceDrop(int index, int guest) {
    final backing = host(
      guest,
      kind: WASIComponentCanonicalHandleKind.resource,
    );
    final type = _type(index, backing);
    table.canonicalRequireReleasable(backing);
    remove(guest);
    table.drop(type, backing);
  }

  @override
  int liftResourceHandle(
    int index,
    int guest, {
    required bool owned,
    String? path,
  }) => _liftResource(index, guest, owned: owned);

  int _liftResource(
    int index,
    int guest, {
    required bool owned,
    int? canonicalIndex,
  }) {
    final backing = host(
      guest,
      kind: WASIComponentCanonicalHandleKind.resource,
    );
    _type(index, backing, canonicalIndex);
    if (owned) {
      table.canonicalRequireOwned(backing);
      remove(guest);
      return backing;
    }
    final scope =
        Zone.current[_callKey] as WASIComponentCanonicalBorrowCallScope?;
    if (scope == null) throw StateError('No active canonical borrow call.');
    return scope.lowerHandle(backing);
  }

  @override
  int lowerResourceHandle(
    int index,
    int backing, {
    required bool owned,
    String? path,
  }) => _lowerResource(index, backing, owned: owned);

  int _lowerResource(
    int index,
    int backing, {
    required bool owned,
    int? canonicalIndex,
  }) {
    final type = _type(index, backing, canonicalIndex);
    if (!owned && !table.canonicalIsBorrow(backing)) {
      final scope =
          Zone.current[_callKey] as WASIComponentCanonicalBorrowCallScope?;
      if (scope == null) throw StateError('No active canonical borrow call.');
      backing = scope.lowerHandle(backing);
    }
    if (!owned &&
        identical(_identity(index, canonicalIndex).implementor, this)) {
      return table.resourceRep(type, backing) as int;
    }
    if (owned) table.canonicalRequireOwned(backing);
    return add(backing, WASIComponentCanonicalHandleKind.resource);
  }

  @override
  int lowerReadableEndpoint(int typeIndex, Object endpoint) {
    requireCapacity(1);
    final readable = switch (endpoint) {
      WASIComponentStream() => endpoint.readable,
      WASIComponentFuture() => endpoint.readable,
      _ => endpoint,
    };
    if (_ownedReadableEndpoints[readable] == true) {
      throw StateError(
        'Readable endpoint is already owned by a component instance.',
      );
    }
    final backing = asyncBindings.lowerReadableEndpoint(typeIndex, endpoint);
    try {
      return add(backing, _endpointKind(typeIndex));
    } catch (_) {
      // Failed installation leaves the caller's endpoint object host-owned.
      table.take(table.canonicalTypeOf(backing), backing);
      rethrow;
    }
  }

  /// Registers the kind of a local endpoint type without merging its identity.
  final Map<int, WASIComponentCanonicalHandleKind> endpointKinds = {};
  WASIComponentCanonicalHandleKind _endpointKind(int index) =>
      endpointKinds[index] ??
      (throw StateError('Unknown component endpoint type: $index.'));

  @override
  Object liftReadableEndpoint(int typeIndex, int guest) {
    final backing = host(guest, kind: _endpointKind(typeIndex));
    return asyncBindings.liftReadableEndpoint(typeIndex, backing);
  }

  @override
  int liftErrorContextHandle(int guest) {
    final backing = errorContexts.copyHandle(
      host(guest, kind: WASIComponentCanonicalHandleKind.errorContext),
    );
    final temporaries =
        Zone.current[_errorCarrierKey]
            as List<(WASIComponentErrorContextHost, int)>?;
    temporaries?.add((errorContexts, backing));
    return backing;
  }

  @override
  int lowerErrorContextHandle(int backing) {
    requireCapacity(1);
    return add(
      errorContexts.copyHandle(backing),
      WASIComponentCanonicalHandleKind.errorContext,
    );
  }

  WASIComponentWaitableEvent event(WASIComponentWaitableEvent value) =>
      value.isNone || value.code == WASIComponentWaitableEventCode.taskCancelled
      ? value
      : WASIComponentWaitableEvent(
          code: value.code,
          payload1: guest(value.payload1),
          payload2: value.payload2,
        );
}

final class _AdapterHandleBindings
    implements
        WASIComponentCanonicalHandleBindings,
        WASIComponentCanonicalValueDiscard {
  _AdapterHandleBindings(this.owner, this.canonicalIndex);
  final WASIComponentCanonicalHandles owner;
  final int canonicalIndex;
  bool? _collectErrors;
  @override
  void discardCanonicalValue(
    WASIComponentCanonicalAdapterFlatValuePlan layout,
    Object? value,
  ) {
    final bindings = _PayloadHandleBindings(
      owner,
      (index) => owner.adapterResourceIdentity(canonicalIndex, index),
      _PayloadMode.discard,
    );
    lowerWASIComponentCanonicalMemoryHandles(layout, value, bindings);
    bindings.finishDiscard();
  }

  @override
  WASIComponentCanonicalHandleBindings forCanonicalAdapter(int index) =>
      owner.forCanonicalAdapter(index);
  @override
  int liftResourceHandle(
    int index,
    int handle, {
    required bool owned,
    String? path,
  }) => owner._liftResource(
    index,
    handle,
    owned: owned,
    canonicalIndex: canonicalIndex,
  );
  @override
  int lowerResourceHandle(
    int index,
    int handle, {
    required bool owned,
    String? path,
  }) => owner._lowerResource(
    index,
    handle,
    owned: owned,
    canonicalIndex: canonicalIndex,
  );
  @override
  int liftErrorContextHandle(int handle) =>
      owner.liftErrorContextHandle(handle);
  @override
  int lowerErrorContextHandle(int handle) =>
      owner.lowerErrorContextHandle(handle);
  @override
  int lowerReadableEndpoint(int index, Object endpoint) =>
      owner.lowerReadableEndpoint(index, endpoint);
  @override
  Object liftReadableEndpoint(int index, int handle) =>
      owner.liftReadableEndpoint(index, handle);
  @override
  T withHandleCall<T>(
    T Function() callback, {
    void Function(void Function() close)? retain,
  }) => owner.withHandleCall(
    callback,
    retain: retain,
    internalCall: _collectErrors ??=
        owner.collectErrorCarriers?.call(canonicalIndex) ?? false,
  );
}

enum _PayloadMode { checkLift, lift, checkLower, lower, discard }

final class _PayloadHandleBindings
    implements WASIComponentCanonicalHandleBindings {
  _PayloadHandleBindings(this.owner, this.identity, this.mode);
  final WASIComponentCanonicalHandles owner;
  final WASIComponentCanonicalResourceIdentity Function(int index) identity;
  final _PayloadMode mode;
  final Set<int> seen = {};
  final List<int> created = [];
  Object? _discardError;
  StackTrace? _discardStackTrace;

  void _discard(void Function() release) {
    try {
      release();
    } catch (error, stackTrace) {
      _discardError ??= error;
      _discardStackTrace ??= stackTrace;
    }
  }

  void finishDiscard() {
    final error = _discardError;
    if (error != null) Error.throwWithStackTrace(error, _discardStackTrace!);
  }

  WASIComponentResourceType<Object> _type(int index, int backing) {
    final expected = identity(index).type;
    if (expected == null ||
        !identical(owner.table.canonicalTypeOf(backing), expected)) {
      throw StateError(
        'Canonical async owner has a different runtime resource type.',
      );
    }
    return expected;
  }

  @override
  int liftResourceHandle(
    int index,
    int handle, {
    required bool owned,
    String? path,
  }) {
    if (!owned) {
      throw StateError('Canonical async payload cannot borrow a resource.');
    }
    final backing = owner.host(
      handle,
      kind: WASIComponentCanonicalHandleKind.resource,
    );
    _type(index, backing);
    owner.table.canonicalRequireOwned(backing);
    if (!seen.add(handle)) {
      throw StateError('Canonical async copy repeats an owned resource.');
    }
    if (mode == _PayloadMode.lift) owner.remove(handle);
    return backing;
  }

  @override
  int lowerResourceHandle(
    int index,
    int backing, {
    required bool owned,
    String? path,
  }) {
    if (!owned) {
      throw StateError('Canonical async payload cannot borrow a resource.');
    }
    if (mode == _PayloadMode.discard) {
      _discard(() {
        if (!owner.table.contains(backing)) return;
        owner.table.canonicalRequireOwned(backing);
        owner.table.canonicalRequireUnclaimed(backing);
        owner.table.drop(owner.table.canonicalTypeOf(backing), backing);
      });
      return backing;
    }
    _type(index, backing);
    owner.table.canonicalRequireOwned(backing);
    owner.table.canonicalRequireUnclaimed(backing);
    if (!seen.add(backing)) {
      throw StateError('Canonical async copy repeats an owned resource.');
    }
    if (mode == _PayloadMode.checkLower) return backing;
    final guest = owner.add(backing, WASIComponentCanonicalHandleKind.resource);
    created.add(guest);
    return guest;
  }

  @override
  WASIComponentCanonicalHandleBindings forCanonicalAdapter(int index) => this;
  @override
  T withHandleCall<T>(
    T Function() callback, {
    void Function(void Function() close)? retain,
  }) => owner.withHandleCall(callback, retain: retain);
  @override
  int liftErrorContextHandle(int handle) =>
      throw StateError('Unsupported async payload handle.');
  @override
  int lowerErrorContextHandle(int handle) {
    if (mode != _PayloadMode.discard) {
      throw StateError('Unsupported async payload handle.');
    }
    _discard(() {
      if (owner.table.contains(handle)) owner.errorContexts.drop(handle);
    });
    return handle;
  }

  @override
  int lowerReadableEndpoint(int index, Object endpoint) {
    if (mode != _PayloadMode.discard) {
      throw StateError('Unsupported nested async payload.');
    }
    _discard(() {
      switch (endpoint) {
        case WASIComponentStream():
          endpoint.readable.dispose();
        case WASIComponentReadableStream():
          endpoint.dispose();
        case WASIComponentFuture():
          endpoint.readable.dispose();
        case WASIComponentReadableFuture():
          endpoint.dispose();
        default:
          throw StateError('Expected an owned readable endpoint result.');
      }
    });
    return 0;
  }

  @override
  Object liftReadableEndpoint(int index, int handle) =>
      throw StateError('Unsupported nested async payload.');
}

void _payloadTypeParts(
  WASIComponentCanonicalAdapterFlatValuePlan? layout,
  WASIComponentCanonicalResourceIdentity Function(int index) identity,
  List<Object?> parts,
) {
  if (layout == null) {
    parts.add(null);
    return;
  }
  parts.addAll([
    layout.kind,
    layout.primitive,
    layout.handleKind,
    layout.labels.length,
    ...layout.labels,
  ]);
  if (layout.resourceTypeIndex != null) {
    final type = identity(layout.resourceTypeIndex!).type;
    if (type == null) {
      throw StateError('Unbound canonical async payload resource.');
    }
    parts.add(type);
  }
  parts.add(layout.fields.length);
  for (final field in layout.fields) {
    parts.add(field.label);
    _payloadTypeParts(field.value, identity, parts);
  }
  parts.add(layout.cases.length);
  for (final item in layout.cases) {
    parts.add(item.label);
    _payloadTypeParts(item.value, identity, parts);
  }
  _payloadTypeParts(layout.element, identity, parts);
  _payloadTypeParts(layout.ok, identity, parts);
  _payloadTypeParts(layout.error, identity, parts);
}

final class _PayloadTypeKey {
  _PayloadTypeKey(this.parts);
  final List<Object?> parts;
  @override
  int get hashCode => Object.hashAll(parts);
  @override
  bool operator ==(Object other) {
    if (other is! _PayloadTypeKey || parts.length != other.parts.length) {
      return false;
    }
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] != other.parts[i]) return false;
    }
    return true;
  }
}
