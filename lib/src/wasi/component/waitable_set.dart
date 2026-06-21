import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'resource_table.dart';

/// Resolves an externally owned component handle to a waitable, when possible.
typedef WASIComponentWaitableResolver =
    WASIComponentWaitable? Function(int handle);

/// Component Model waitable event codes.
///
/// These integer values are the Canonical ABI event discriminants returned by
/// `waitable-set.wait` and `waitable-set.poll`.
enum WASIComponentWaitableEventCode {
  /// No event is currently available.
  none(0),

  /// A subtask state update is ready.
  subtask(1),

  /// A stream read copy completed or changed state.
  streamRead(2),

  /// A stream write copy completed or changed state.
  streamWrite(3),

  /// A future read copy completed or changed state.
  futureRead(4),

  /// A future write copy completed or changed state.
  futureWrite(5),

  /// The current task observed cancellation.
  taskCancelled(6);

  const WASIComponentWaitableEventCode(this.value);

  /// Canonical ABI integer discriminant.
  final int value;
}

/// A Canonical ABI waitable event tuple.
final class WASIComponentWaitableEvent {
  /// Creates an event with two canonical `u32` payload fields.
  const WASIComponentWaitableEvent({
    required this.code,
    this.payload1 = 0,
    this.payload2 = 0,
  });

  /// No event is currently ready.
  static const none = WASIComponentWaitableEvent(
    code: WASIComponentWaitableEventCode.none,
  );

  /// The current task observed cancellation.
  static const taskCancelled = WASIComponentWaitableEvent(
    code: WASIComponentWaitableEventCode.taskCancelled,
  );

  /// Event discriminant.
  final WASIComponentWaitableEventCode code;

  /// First canonical `u32` payload.
  final int payload1;

  /// Second canonical `u32` payload.
  final int payload2;

  /// Whether this event represents no ready work.
  bool get isNone => code == WASIComponentWaitableEventCode.none;

  /// Writes the two canonical `u32` payload fields to [memory].
  void writePayloadToMemory(wasm.Memory memory, int pointer) {
    RangeError.checkNotNegative(pointer, 'pointer');
    RangeError.checkValueInInterval(payload1, 0, _maxU32, 'payload1');
    RangeError.checkValueInInterval(payload2, 0, _maxU32, 'payload2');
    final data = ByteData.view(memory.buffer);
    data.setUint32(pointer, payload1, Endian.little);
    data.setUint32(pointer + 4, payload2, Endian.little);
  }
}

/// Host-side representation of a Component Model waitable.
final class WASIComponentWaitable {
  /// Creates a waitable with a debug [name].
  WASIComponentWaitable(String name) : _name = name;

  final String _name;
  WASIComponentWaitableSet? _set;
  WASIComponentWaitableEvent Function()? _pendingEvent;
  bool _hasSyncWaiter = false;
  bool _hasActiveCopy = false;

  /// Debug label used in diagnostics.
  String get name => _name;

  /// Whether an event is ready for delivery.
  bool get hasPendingEvent => _pendingEvent != null;

  /// Whether this waitable currently belongs to a waitable set.
  bool get inWaitableSet => _set != null;

  /// Whether a synchronous canonical operation is waiting on this waitable.
  bool get hasSyncWaiter => _hasSyncWaiter;

  /// Whether an async copy is active and waiting for event delivery.
  bool get hasActiveCopy => _hasActiveCopy;

  /// Validates this waitable can be dropped.
  void requireDroppable() {
    if (_hasActiveCopy) {
      throw StateError('WASI component waitable $name has an active copy.');
    }
    if (hasPendingEvent) {
      throw StateError('WASI component waitable $name has a pending event.');
    }
    if (_hasSyncWaiter) {
      throw StateError(
        'WASI component waitable $name has a synchronous waiter.',
      );
    }
  }

  /// Marks this waitable as owning an active async copy.
  void beginCopy() {
    if (_hasActiveCopy || hasPendingEvent) {
      throw StateError('WASI component waitable $name is not idle.');
    }
    _hasActiveCopy = true;
  }

  /// Sets the pending event delivered by the next wait or poll.
  void setPendingEvent(WASIComponentWaitableEvent Function() event) {
    _pendingEvent = event;
    _set?._completePendingWaiters();
  }

  /// Runs [callback] while this waitable is synchronously waited on.
  Future<T> withSyncWaiter<T>(Future<T> Function() callback) async {
    if (inWaitableSet) {
      throw StateError('WASI component waitable $name is in a waitable set.');
    }
    if (_hasSyncWaiter) {
      throw StateError(
        'WASI component waitable $name already has a synchronous waiter.',
      );
    }
    _hasSyncWaiter = true;
    try {
      return await callback();
    } finally {
      _hasSyncWaiter = false;
    }
  }

  /// Delivers and clears the pending event.
  WASIComponentWaitableEvent takePendingEvent() {
    final event = _pendingEvent;
    if (event == null) {
      throw StateError('WASI component waitable $name has no pending event.');
    }
    _pendingEvent = null;
    _hasActiveCopy = false;
    return event();
  }

  /// Moves this waitable into [set], or removes it from any set when null.
  void join(WASIComponentWaitableSet? set) {
    if (_hasSyncWaiter) {
      throw StateError(
        'WASI component waitable $name has a synchronous waiter.',
      );
    }
    final currentSet = _set;
    if (identical(currentSet, set)) {
      return;
    }
    currentSet?._remove(this);
    _set = set;
    set?._add(this);
    if (hasPendingEvent) {
      set?._completePendingWaiters();
    }
  }

  /// Drops this waitable after validating it has no pending event or waiter.
  void drop() {
    requireDroppable();
    join(null);
  }
}

/// A Component Model waitable set.
final class WASIComponentWaitableSet {
  /// Creates an empty waitable set with a debug [name].
  WASIComponentWaitableSet(String name) : _name = name;

  final String _name;
  final LinkedHashSet<WASIComponentWaitable> _waitables =
      LinkedHashSet<WASIComponentWaitable>.identity();
  final Queue<Completer<WASIComponentWaitableEvent>> _waiters =
      Queue<Completer<WASIComponentWaitableEvent>>();

  /// Debug label used in diagnostics.
  String get name => _name;

  /// Number of waitables in this set.
  int get length => _waitables.length;

  /// Whether this set contains no waitables.
  bool get isEmpty => _waitables.isEmpty;

  /// Whether any member has a pending event.
  bool get hasPendingEvent => _firstPendingWaitable() != null;

  /// Returns the next pending event, or [WASIComponentWaitableEvent.none].
  WASIComponentWaitableEvent poll() {
    final waitable = _firstPendingWaitable();
    if (waitable == null) {
      return WASIComponentWaitableEvent.none;
    }
    return waitable.takePendingEvent();
  }

  /// Waits until any member has a pending event.
  Future<WASIComponentWaitableEvent> wait() {
    final event = poll();
    if (!event.isNone) {
      return Future<WASIComponentWaitableEvent>.value(event);
    }

    final completer = Completer<WASIComponentWaitableEvent>();
    _waiters.addLast(completer);
    return completer.future;
  }

  /// Validates this set can be dropped.
  void requireDroppable() {
    if (_waitables.isNotEmpty) {
      throw StateError(
        'WASI component waitable set $name still contains waitables.',
      );
    }
    if (_waiters.isNotEmpty) {
      throw StateError('WASI component waitable set $name has active waiters.');
    }
  }

  void _add(WASIComponentWaitable waitable) {
    _waitables.add(waitable);
  }

  void _remove(WASIComponentWaitable waitable) {
    _waitables.remove(waitable);
  }

  WASIComponentWaitable? _firstPendingWaitable() {
    for (final waitable in _waitables) {
      if (waitable.hasPendingEvent) {
        return waitable;
      }
    }
    return null;
  }

  void _completePendingWaiters() {
    while (_waiters.isNotEmpty) {
      final event = poll();
      if (event.isNone) {
        return;
      }
      final waiter = _waiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete(event);
      }
    }
  }
}

/// Table-backed host for canonical waitable-set operations.
final class WASIComponentWaitableHost {
  /// Creates a waitable host backed by [table] or a new resource table.
  WASIComponentWaitableHost({
    WASIComponentResourceTable? table,
    Iterable<WASIComponentWaitableResolver> waitableResolvers = const [],
  }) : table = table ?? WASIComponentResourceTable(),
       _waitableResolvers = <WASIComponentWaitableResolver>[
         ...waitableResolvers,
       ] {
    _waitableType = this.table.defineType<WASIComponentWaitable>('waitable');
    _waitableSetType = this.table.defineType<WASIComponentWaitableSet>(
      'waitable-set',
    );
  }

  /// Resource table used for waitables and waitable sets.
  final WASIComponentResourceTable table;

  late final WASIComponentResourceType<WASIComponentWaitable> _waitableType;
  late final WASIComponentResourceType<WASIComponentWaitableSet>
  _waitableSetType;
  final List<WASIComponentWaitableResolver> _waitableResolvers;

  /// Adds a resolver for waitables owned by another component host layer.
  void addWaitableResolver(WASIComponentWaitableResolver resolver) {
    _waitableResolvers.add(resolver);
  }

  /// Inserts a waitable and returns its component table handle.
  int insertWaitable(WASIComponentWaitable waitable) {
    return table.insert<WASIComponentWaitable>(_waitableType, waitable);
  }

  /// Creates a waitable handle with a debug [name].
  int createWaitable(String name) {
    return insertWaitable(WASIComponentWaitable(name));
  }

  /// Binds a decoded canonical waitable-set definition.
  WASIComponentCanonicalWaitableOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    if (!_isWaitableCanonicalKind(definition.kind)) {
      throw UnsupportedError(
        'Wasm component canonical ${definition.kind.name} is not a waitable-set operation.',
      );
    }
    return WASIComponentCanonicalWaitableOperation._(
      kind: definition.kind,
      cancellable: definition.isCancellable,
      host: this,
    );
  }

  /// Binds all decoded canonical waitable-set definitions in [component].
  WASIComponentCanonicalWaitableProgram bindCanonicalDefinitions(
    WasmComponent component,
  ) {
    return WASIComponentCanonicalWaitableProgram(
      operations: List<WASIComponentCanonicalWaitableOperation>.unmodifiable([
        for (final definition in component.canonicalDefinitions)
          bindCanonicalDefinition(definition),
      ]),
    );
  }

  /// Executes `waitable-set.new`.
  int waitableSetNew() {
    return table.insert<WASIComponentWaitableSet>(
      _waitableSetType,
      WASIComponentWaitableSet('waitable-set'),
    );
  }

  /// Executes `waitable.join`.
  void waitableJoin(int waitable, int waitableSet) {
    final value = _waitableForHandle(waitable);
    if (value == null) {
      throw StateError('Unknown WASI component waitable handle: $waitable.');
    }
    void join(WASIComponentWaitableSet? set) {
      if (waitableSet == 0) {
        value.join(null);
        return;
      }
      value.join(set);
    }

    if (waitableSet == 0) {
      join(null);
    } else {
      table.borrow<WASIComponentWaitableSet, void>(
        _waitableSetType,
        waitableSet,
        join,
      );
    }
  }

  /// Executes `waitable-set.poll`.
  int waitableSetPollToMemory(
    int waitableSet,
    wasm.Memory memory,
    int pointer,
  ) {
    final event = table
        .borrow<WASIComponentWaitableSet, WASIComponentWaitableEvent>(
          _waitableSetType,
          waitableSet,
          (set) => set.poll(),
        );
    return _writeEventToMemory(event, memory, pointer);
  }

  /// Executes `waitable-set.wait`.
  Future<int> waitableSetWaitToMemory(
    int waitableSet,
    wasm.Memory memory,
    int pointer,
  ) async {
    final event = await table
        .borrowAsync<WASIComponentWaitableSet, WASIComponentWaitableEvent>(
          _waitableSetType,
          waitableSet,
          (set) => set.wait(),
        );
    return _writeEventToMemory(event, memory, pointer);
  }

  /// Executes `waitable-set.drop`.
  void waitableSetDrop(int waitableSet) {
    final set = table.get<WASIComponentWaitableSet>(
      _waitableSetType,
      waitableSet,
    );
    set.requireDroppable();
    table.drop<WASIComponentWaitableSet>(_waitableSetType, waitableSet);
  }

  /// Drops a host-created waitable handle.
  void dropWaitable(int waitable) {
    final value = table.get<WASIComponentWaitable>(_waitableType, waitable);
    value.drop();
    table.drop<WASIComponentWaitable>(_waitableType, waitable);
  }

  int _writeEventToMemory(
    WASIComponentWaitableEvent event,
    wasm.Memory memory,
    int pointer,
  ) {
    event.writePayloadToMemory(memory, pointer);
    return event.code.value;
  }

  WASIComponentWaitable? _waitableForHandle(int handle) {
    if (table.containsType<WASIComponentWaitable>(_waitableType, handle)) {
      return table.get<WASIComponentWaitable>(_waitableType, handle);
    }
    for (final resolver in _waitableResolvers) {
      final waitable = resolver(handle);
      if (waitable != null) {
        return waitable;
      }
    }
    return null;
  }
}

/// Executable waitable-set canonical program for a decoded component.
final class WASIComponentCanonicalWaitableProgram {
  /// Creates a canonical waitable program from ordered [operations].
  const WASIComponentCanonicalWaitableProgram({required this.operations});

  /// Waitable operations in component canonical definition order.
  final List<WASIComponentCanonicalWaitableOperation> operations;

  /// Invokes a non-memory waitable operation.
  Object? invoke(int canonicalIndex, List<Object?> args) {
    final operation = _operationAt(canonicalIndex);
    switch (operation.kind) {
      case WasmComponentCanonicalKind.waitableSetNew:
        _expectArity(canonicalIndex, args, 0);
        return operation.waitableSetNew();
      case WasmComponentCanonicalKind.waitableSetDrop:
        _expectArity(canonicalIndex, args, 1);
        operation.waitableSetDrop(_expectHandle(canonicalIndex, args[0]));
        return null;
      case WasmComponentCanonicalKind.waitableJoin:
        _expectArity(canonicalIndex, args, 2);
        operation.waitableJoin(
          _expectHandle(canonicalIndex, args[0]),
          _expectNonNegativeInt(canonicalIndex, args[1], 'waitableSet'),
        );
        return null;
      default:
        throw StateError(
          'WASI component canonical ${operation.kind.name} requires memory invocation.',
        );
    }
  }

  /// Invokes a waitable operation that writes an event payload to memory.
  Object? invokeWithMemory(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args,
  ) {
    final operation = _operationAt(canonicalIndex);
    switch (operation.kind) {
      case WasmComponentCanonicalKind.waitableSetPoll:
        _expectArity(canonicalIndex, args, 2);
        return operation.waitableSetPollToMemory(
          _expectHandle(canonicalIndex, args[0]),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
        );
      default:
        return invoke(canonicalIndex, args);
    }
  }

  /// Invokes a waitable operation and waits for an event when required.
  Future<Object?> invokeWithMemoryAsync(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args,
  ) async {
    final operation = _operationAt(canonicalIndex);
    switch (operation.kind) {
      case WasmComponentCanonicalKind.waitableSetWait:
        _expectArity(canonicalIndex, args, 2);
        return operation.waitableSetWaitToMemory(
          _expectHandle(canonicalIndex, args[0]),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
        );
      default:
        return invokeWithMemory(canonicalIndex, memory, args);
    }
  }

  WASIComponentCanonicalWaitableOperation _operationAt(int canonicalIndex) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical waitable index: $canonicalIndex.',
      );
    }
    return operations[canonicalIndex];
  }
}

/// Executable form of a canonical waitable-set operation.
final class WASIComponentCanonicalWaitableOperation {
  const WASIComponentCanonicalWaitableOperation._({
    required this.kind,
    required this.cancellable,
    required WASIComponentWaitableHost host,
  }) : _host = host;

  /// Canonical waitable-set operation kind.
  final WasmComponentCanonicalKind kind;

  /// Whether this wait or poll definition was decoded with cancellability.
  final bool cancellable;

  final WASIComponentWaitableHost _host;

  /// Executes `waitable-set.new`.
  int waitableSetNew() {
    _requireKind(WasmComponentCanonicalKind.waitableSetNew);
    return _host.waitableSetNew();
  }

  /// Executes `waitable-set.poll`.
  int waitableSetPollToMemory(
    int waitableSet,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.waitableSetPoll);
    return _host.waitableSetPollToMemory(waitableSet, memory, pointer);
  }

  /// Executes `waitable-set.wait`.
  Future<int> waitableSetWaitToMemory(
    int waitableSet,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.waitableSetWait);
    return _host.waitableSetWaitToMemory(waitableSet, memory, pointer);
  }

  /// Executes `waitable-set.drop`.
  void waitableSetDrop(int waitableSet) {
    _requireKind(WasmComponentCanonicalKind.waitableSetDrop);
    _host.waitableSetDrop(waitableSet);
  }

  /// Executes `waitable.join`.
  void waitableJoin(int waitable, int waitableSet) {
    _requireKind(WasmComponentCanonicalKind.waitableJoin);
    _host.waitableJoin(waitable, waitableSet);
  }

  void _requireKind(WasmComponentCanonicalKind expected) {
    if (kind != expected) {
      throw StateError(
        'WASI component canonical ${kind.name} cannot execute ${expected.name}.',
      );
    }
  }
}

bool _isWaitableCanonicalKind(WasmComponentCanonicalKind kind) {
  return kind == WasmComponentCanonicalKind.waitableSetNew ||
      kind == WasmComponentCanonicalKind.waitableSetWait ||
      kind == WasmComponentCanonicalKind.waitableSetPoll ||
      kind == WasmComponentCanonicalKind.waitableSetDrop ||
      kind == WasmComponentCanonicalKind.waitableJoin;
}

void _expectArity(int canonicalIndex, List<Object?> args, int expected) {
  if (args.length != expected) {
    throw StateError(
      'WASI component canonical waitable index $canonicalIndex expected '
      '$expected arguments, got ${args.length}.',
    );
  }
}

int _expectHandle(int canonicalIndex, Object? value) {
  return _expectNonNegativeInt(canonicalIndex, value, 'handle');
}

int _expectNonNegativeInt(int canonicalIndex, Object? value, String name) {
  if (value is! int || value < 0) {
    throw StateError(
      'WASI component canonical waitable index $canonicalIndex expected '
      '$name to be a non-negative int.',
    );
  }
  return value;
}

const int _maxU32 = 0xffffffff;
