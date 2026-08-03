import '../../wasm/backend/native/interpreter/component.dart';
import 'resource_table.dart';
import 'waitable_set.dart';

/// Canonical return value used when a subtask operation has not resolved yet.
const int wasiComponentSubtaskBlocked = 0xffffffff;

/// Component Model subtask states.
enum WASIComponentSubtaskState {
  /// The subtask has been created but has not started receiving arguments.
  starting(0),

  /// The subtask has started running.
  started(1),

  /// The subtask returned through `task.return`.
  returned(2),

  /// The subtask was cancelled before it started.
  cancelledBeforeStarted(3),

  /// The subtask was cancelled before returning a value.
  cancelledBeforeReturned(4);

  const WASIComponentSubtaskState(this.code);

  /// Canonical ABI integer state code.
  final int code;

  /// Whether this state is a final subtask state.
  bool get isResolved => code >= returned.code;
}

/// Caller-side state for a Component Model subtask.
final class WASIComponentSubtask {
  /// Creates a subtask in [state].
  WASIComponentSubtask({
    String name = 'subtask',
    WASIComponentSubtaskState state = WASIComponentSubtaskState.starting,
    void Function(WASIComponentSubtask subtask)? onCancel,
  }) : _name = name,
       _state = state,
       _onCancel = onCancel,
       waitable = WASIComponentWaitable(name);

  final String _name;
  int? _handle;
  WASIComponentSubtaskState _state;
  void Function(WASIComponentSubtask subtask)? _onCancel;
  bool _cancellationRequested = false;
  bool _resolveDelivered = false;
  bool _hasResult = false;
  Object? _result;
  Object? _failure;
  StackTrace? _failureStackTrace;

  /// Waitable used for `waitable.join` and `SUBTASK` events.
  final WASIComponentWaitable waitable;

  /// Debug label used in diagnostics.
  String get name => _name;

  /// Current subtask state.
  WASIComponentSubtaskState get state => _state;

  /// Whether cancellation has already been requested.
  bool get cancellationRequested => _cancellationRequested;

  /// Whether the final subtask state has been delivered to the caller.
  bool get resolveDelivered => _resolveDelivered;

  /// Whether the subtask is in a final state.
  bool get resolved => _state.isResolved;

  /// Whether the subtask returned a result value.
  bool get hasResult => _hasResult;

  /// Result value returned by the callee task.
  Object? get result {
    if (!_hasResult) {
      throw StateError('WASI component subtask $name has no returned result.');
    }
    return _result;
  }

  /// Replaces the cancellation callback.
  set onCancel(void Function(WASIComponentSubtask subtask)? callback) {
    _onCancel = callback;
  }

  /// Adds a cancellation callback without replacing an existing callback.
  void addCancellationListener(
    void Function(WASIComponentSubtask subtask) callback,
  ) {
    final previous = _onCancel;
    if (previous == null) {
      _onCancel = callback;
      return;
    }
    _onCancel = (subtask) {
      previous(subtask);
      callback(subtask);
    };
  }

  /// Marks the subtask as started.
  void markStarted() {
    _requireNotDelivered();
    if (_state != WASIComponentSubtaskState.starting) {
      throw StateError(
        'WASI component subtask $name cannot start from $_state.',
      );
    }
    if (_cancellationRequested) {
      throw StateError(
        'WASI component subtask $name was asked to cancel before starting.',
      );
    }
    _state = WASIComponentSubtaskState.started;
    _publishProgress();
  }

  /// Resolves the subtask as returned.
  void markReturned({Object? result, bool hasResult = false}) {
    _requireNotDelivered();
    if (resolved) {
      throw StateError('WASI component subtask $name is already resolved.');
    }
    _hasResult = hasResult;
    _result = result;
    _state = WASIComponentSubtaskState.returned;
    _publishProgress();
  }

  /// Resolves this subtask with a trapped host or component failure.
  void markFailed(Object error, StackTrace stackTrace) {
    _requireNotDelivered();
    if (resolved) {
      throw StateError('WASI component subtask $name is already resolved.');
    }
    _failure = error;
    _failureStackTrace = stackTrace;
    _state = WASIComponentSubtaskState.returned;
    _publishProgress();
  }

  /// Confirms cancellation before the subtask started.
  void cancelBeforeStarted() {
    if (!_cancellationRequested) {
      throw StateError(
        'WASI component subtask $name has no cancellation request.',
      );
    }
    _resolve(WASIComponentSubtaskState.cancelledBeforeStarted);
  }

  /// Confirms cancellation after the subtask started but before returning.
  void cancelBeforeReturned() {
    if (!_cancellationRequested) {
      throw StateError(
        'WASI component subtask $name has no cancellation request.',
      );
    }
    _resolve(WASIComponentSubtaskState.cancelledBeforeReturned);
  }

  void _attachHandle(int handle) {
    _handle = handle;
    if (resolved && !resolveDelivered) {
      _publishProgress();
    }
  }

  void _requestCancellation() {
    _requireNotDelivered();
    if (_cancellationRequested) {
      throw StateError(
        'WASI component subtask $name was already asked to cancel.',
      );
    }
    _cancellationRequested = true;
    _onCancel?.call(this);
  }

  void _resolve(WASIComponentSubtaskState state) {
    _requireNotDelivered();
    if (resolved) {
      throw StateError('WASI component subtask $name is already resolved.');
    }
    _state = state;
    _publishProgress();
  }

  int _deliverResolve() {
    if (!resolved || _resolveDelivered) {
      throw StateError(
        'WASI component subtask $name has no unresolved final state.',
      );
    }
    _resolveDelivered = true;
    final failure = _failure;
    if (failure != null) {
      Error.throwWithStackTrace(
        failure,
        _failureStackTrace ?? StackTrace.empty,
      );
    }
    return _state.code;
  }

  void _drop() {
    if (!_resolveDelivered) {
      throw StateError(
        'WASI component subtask $name has not delivered its final state.',
      );
    }
    waitable.drop();
  }

  void _publishProgress() {
    final handle = _handle;
    if (handle == null) {
      return;
    }
    waitable.setPendingEvent(
      () => WASIComponentWaitableEvent(
        code: WASIComponentWaitableEventCode.subtask,
        payload1: handle,
        payload2: resolved ? _deliverResolve() : _state.code,
      ),
    );
  }

  void _requireNotDelivered() {
    if (_resolveDelivered) {
      throw StateError(
        'WASI component subtask $name has already delivered its final state.',
      );
    }
  }
}

/// Table-backed host for canonical subtask operations.
final class WASIComponentSubtaskHost {
  /// Creates a subtask host backed by [table] or a new resource table.
  WASIComponentSubtaskHost({WASIComponentResourceTable? table})
    : table = table ?? WASIComponentResourceTable() {
    _subtaskType = this.table.defineType<WASIComponentSubtask>('subtask');
  }

  /// Resource table used for subtasks.
  final WASIComponentResourceTable table;

  late final WASIComponentResourceType<WASIComponentSubtask> _subtaskType;

  /// Inserts [subtask] and returns its canonical handle.
  int insertSubtask(WASIComponentSubtask subtask) {
    final handle = table.insert<WASIComponentSubtask>(_subtaskType, subtask);
    subtask._attachHandle(handle);
    return handle;
  }

  /// Creates a subtask and returns its canonical handle.
  int createSubtask({
    String name = 'subtask',
    WASIComponentSubtaskState state = WASIComponentSubtaskState.starting,
    void Function(WASIComponentSubtask subtask)? onCancel,
  }) {
    return insertSubtask(
      WASIComponentSubtask(name: name, state: state, onCancel: onCancel),
    );
  }

  /// Resolves a subtask handle to its waitable, for `waitable.join`.
  WASIComponentWaitable? waitableForHandle(int handle) {
    if (!table.containsType<WASIComponentSubtask>(_subtaskType, handle)) {
      return null;
    }
    return table.get<WASIComponentSubtask>(_subtaskType, handle).waitable;
  }

  /// Binds a decoded canonical subtask definition.
  WASIComponentCanonicalSubtaskOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    if (!_isSubtaskCanonicalKind(definition.kind)) {
      throw UnsupportedError(
        'Wasm component canonical ${definition.kind.name} is not a subtask operation.',
      );
    }
    return WASIComponentCanonicalSubtaskOperation._(
      kind: definition.kind,
      isAsync: definition.isAsync,
      host: this,
    );
  }

  /// Binds all decoded canonical subtask definitions in [component].
  WASIComponentCanonicalSubtaskProgram bindCanonicalDefinitions(
    WasmComponent component,
  ) {
    return WASIComponentCanonicalSubtaskProgram(
      operations: List<WASIComponentCanonicalSubtaskOperation>.unmodifiable([
        for (final definition in component.canonicalDefinitions)
          bindCanonicalDefinition(definition),
      ]),
    );
  }

  /// Executes `subtask.cancel`.
  int subtaskCancel(int subtask, {required bool isAsync}) {
    final value = table.get<WASIComponentSubtask>(_subtaskType, subtask);
    final event = _requestSubtaskCancellation(value, subtask, isAsync: isAsync);
    if (event != null) {
      return event;
    }
    if (isAsync) {
      return wasiComponentSubtaskBlocked;
    }
    throw UnsupportedError(
      'Synchronous WASI component subtask cancellation waits require invokeAsync.',
    );
  }

  /// Executes `subtask.cancel` and waits when the operation is non-async.
  Future<int> subtaskCancelWhenReady(
    int subtask, {
    required bool isAsync,
  }) async {
    final value = table.get<WASIComponentSubtask>(_subtaskType, subtask);
    final event = _requestSubtaskCancellation(value, subtask, isAsync: isAsync);
    if (event != null) {
      return event;
    }
    if (isAsync) {
      return wasiComponentSubtaskBlocked;
    }
    return value.waitable.withSyncWaiter(
      () => _waitForResolvedSubtaskEvent(value, subtask),
    );
  }

  /// Executes `subtask.drop`.
  void subtaskDrop(int subtask) {
    final value = table.get<WASIComponentSubtask>(_subtaskType, subtask);
    value._drop();
    table.drop<WASIComponentSubtask>(_subtaskType, subtask);
  }

  int? _requestSubtaskCancellation(
    WASIComponentSubtask subtask,
    int handle, {
    required bool isAsync,
  }) {
    if (subtask.resolveDelivered) {
      throw StateError(
        'WASI component subtask ${subtask.name} already delivered its state.',
      );
    }
    if (subtask.cancellationRequested) {
      throw StateError(
        'WASI component subtask ${subtask.name} was already asked to cancel.',
      );
    }
    if (subtask.waitable.inWaitableSet && !isAsync) {
      throw StateError(
        'WASI component subtask ${subtask.name} is in a waitable set.',
      );
    }
    if (!subtask.resolved) {
      subtask._requestCancellation();
    }
    if (subtask.resolved && subtask.waitable.hasPendingEvent) {
      return _expectSubtaskEvent(
        subtask,
        handle,
        subtask.waitable.takePendingEvent(),
      );
    }
    return null;
  }

  Future<int> _waitForResolvedSubtaskEvent(
    WASIComponentSubtask subtask,
    int handle,
  ) async {
    while (true) {
      final event = await subtask.waitable.waitForPendingEvent();
      final state = _expectSubtaskEvent(subtask, handle, event);
      if (state >= WASIComponentSubtaskState.returned.code) {
        return state;
      }
    }
  }

  int _expectSubtaskEvent(
    WASIComponentSubtask subtask,
    int handle,
    WASIComponentWaitableEvent event,
  ) {
    if (event.code != WASIComponentWaitableEventCode.subtask ||
        event.payload1 != handle) {
      throw StateError(
        'WASI component subtask ${subtask.name} produced ${event.code.name} '
        'for handle ${event.payload1}, expected subtask for handle $handle.',
      );
    }
    return event.payload2;
  }
}

/// Executable subtask canonical program for a decoded component.
final class WASIComponentCanonicalSubtaskProgram {
  /// Creates a canonical subtask program from ordered [operations].
  const WASIComponentCanonicalSubtaskProgram({required this.operations});

  /// Subtask operations in component canonical definition order.
  final List<WASIComponentCanonicalSubtaskOperation> operations;

  /// Invokes a subtask operation.
  Object? invoke(int canonicalIndex, List<Object?> args) {
    final operation = _operationAt(canonicalIndex);
    switch (operation.kind) {
      case WasmComponentCanonicalKind.subtaskCancel:
        _expectArity(canonicalIndex, args, 1);
        return operation.subtaskCancel(
          _expectHandle(canonicalIndex, args.single),
        );
      case WasmComponentCanonicalKind.subtaskDrop:
        _expectArity(canonicalIndex, args, 1);
        operation.subtaskDrop(_expectHandle(canonicalIndex, args.single));
        return null;
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the subtask program.',
        );
    }
  }

  /// Invokes a subtask operation and waits for non-async cancellation.
  Future<Object?> invokeAsync(int canonicalIndex, List<Object?> args) async {
    final operation = _operationAt(canonicalIndex);
    switch (operation.kind) {
      case WasmComponentCanonicalKind.subtaskCancel:
        _expectArity(canonicalIndex, args, 1);
        return operation.subtaskCancelWhenReady(
          _expectHandle(canonicalIndex, args.single),
        );
      default:
        return invoke(canonicalIndex, args);
    }
  }

  WASIComponentCanonicalSubtaskOperation _operationAt(int canonicalIndex) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical subtask index: $canonicalIndex.',
      );
    }
    return operations[canonicalIndex];
  }
}

/// Executable form of a canonical subtask operation.
final class WASIComponentCanonicalSubtaskOperation {
  const WASIComponentCanonicalSubtaskOperation._({
    required this.kind,
    required this.isAsync,
    required WASIComponentSubtaskHost host,
  }) : _host = host;

  /// Canonical subtask operation kind.
  final WasmComponentCanonicalKind kind;

  /// Whether this canonical operation was decoded with the async flag.
  final bool isAsync;

  final WASIComponentSubtaskHost _host;

  /// Executes `subtask.cancel`.
  int subtaskCancel(int subtask) {
    _requireKind(WasmComponentCanonicalKind.subtaskCancel);
    return _host.subtaskCancel(subtask, isAsync: isAsync);
  }

  /// Executes `subtask.cancel`, waiting when the operation is non-async.
  Future<int> subtaskCancelWhenReady(int subtask) {
    _requireKind(WasmComponentCanonicalKind.subtaskCancel);
    return _host.subtaskCancelWhenReady(subtask, isAsync: isAsync);
  }

  /// Executes `subtask.drop`.
  void subtaskDrop(int subtask) {
    _requireKind(WasmComponentCanonicalKind.subtaskDrop);
    _host.subtaskDrop(subtask);
  }

  void _requireKind(WasmComponentCanonicalKind expected) {
    if (kind != expected) {
      throw StateError(
        'WASI component canonical ${kind.name} cannot execute ${expected.name}.',
      );
    }
  }
}

bool _isSubtaskCanonicalKind(WasmComponentCanonicalKind kind) {
  return kind == WasmComponentCanonicalKind.subtaskCancel ||
      kind == WasmComponentCanonicalKind.subtaskDrop;
}

void _expectArity(int canonicalIndex, List<Object?> args, int expected) {
  if (args.length != expected) {
    throw StateError(
      'WASI component canonical subtask index $canonicalIndex expected '
      '$expected arguments, got ${args.length}.',
    );
  }
}

int _expectHandle(int canonicalIndex, Object? value) {
  if (value is int && value > 0) {
    return value;
  }
  throw StateError(
    'WASI component canonical subtask index $canonicalIndex expected handle.',
  );
}
