import 'dart:async';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'adapter_plan.dart';
import 'current.dart';
import 'string_memory.dart';
import 'subtask.dart';
import 'waitable_set.dart';

const int _canonicalMaxFlatTaskReturnValues = 16;

/// Callee-side Component Model task state.
enum WASIComponentTaskState {
  /// The task exists but has not observed its start boundary yet.
  created,

  /// The task has started executing guest code.
  started,

  /// The task resolved with `task.return`.
  returned,

  /// The task resolved with `task.cancel`.
  cancelled;

  /// Whether the task has reached a final state.
  bool get isResolved =>
      this == WASIComponentTaskState.returned ||
      this == WASIComponentTaskState.cancelled;
}

/// Callee-side state for Component Model `task.*` canonical operations.
final class WASIComponentTask {
  /// Creates a task optionally linked to its caller-side [subtask].
  WASIComponentTask({
    String name = 'task',
    WASIComponentSubtask? subtask,
    void Function(WASIComponentTask task)? onCancellationRequested,
  }) : _name = name,
       _subtask = subtask,
       _onCancellationRequested = onCancellationRequested {
    subtask?.addCancellationListener((_) => requestCancellation());
  }

  final String _name;
  final WASIComponentSubtask? _subtask;
  final void Function(WASIComponentTask task)? _onCancellationRequested;
  WASIComponentTaskState _state = WASIComponentTaskState.created;
  bool _cancellationRequested = false;
  Completer<void>? _cancellationRequestedCompleter;
  int _borrowCount = 0;
  bool _hasResult = false;
  Object? _result;

  /// Debug label used in diagnostics.
  String get name => _name;

  /// Current task state.
  WASIComponentTaskState get state => _state;

  /// Whether the caller requested cancellation.
  bool get cancellationRequested => _cancellationRequested;

  /// Completes when cooperative cancellation is requested for this task.
  Future<void> get whenCancellationRequested {
    if (_cancellationRequested) {
      return Future<void>.value();
    }
    return (_cancellationRequestedCompleter ??= Completer<void>()).future;
  }

  /// Number of outstanding borrows lent to this task.
  int get borrowCount => _borrowCount;

  /// Whether `task.return` stored a result value.
  bool get hasResult => _hasResult;

  /// Result value stored by `task.return`.
  Object? get result {
    if (!_hasResult) {
      throw StateError('WASI component task $name has no returned result.');
    }
    return _result;
  }

  /// Marks the task as started and publishes caller-side subtask progress.
  void markStarted() {
    _requireNotResolved();
    if (_state != WASIComponentTaskState.created) {
      throw StateError('WASI component task $name already started.');
    }
    if (_cancellationRequested) {
      throw StateError(
        'WASI component task $name was cancelled before it started.',
      );
    }
    _state = WASIComponentTaskState.started;
    _subtask?.markStarted();
  }

  /// Records a borrow lent to this task.
  void addBorrow() {
    _requireNotResolved();
    _borrowCount++;
  }

  /// Releases a borrow lent to this task.
  void releaseBorrow() {
    if (_borrowCount == 0) {
      throw StateError('WASI component task $name has no active borrows.');
    }
    _borrowCount--;
  }

  /// Requests cooperative cancellation of this task.
  void requestCancellation() {
    _requireNotResolved();
    if (_cancellationRequested) {
      return;
    }
    _cancellationRequested = true;
    _cancellationRequestedCompleter?.complete();
    _onCancellationRequested?.call(this);
  }

  /// Executes `task.return`.
  void returnResult({Object? result, bool hasResult = false}) {
    _requireNotResolved();
    _requireNoBorrows('return');
    _state = WASIComponentTaskState.returned;
    _hasResult = hasResult;
    _result = result;
    _subtask?.markReturned(result: result, hasResult: hasResult);
  }

  /// Executes `task.cancel`.
  void cancel() {
    _requireNotResolved();
    if (!_cancellationRequested) {
      throw StateError(
        'WASI component task $name cannot cancel before cancellation was requested.',
      );
    }
    _requireNoBorrows('cancel');
    _state = WASIComponentTaskState.cancelled;
    final subtask = _subtask;
    if (subtask == null) {
      return;
    }
    if (subtask.state == WASIComponentSubtaskState.starting) {
      subtask.cancelBeforeStarted();
    } else {
      subtask.cancelBeforeReturned();
    }
  }

  void _requireNoBorrows(String operation) {
    if (_borrowCount != 0) {
      throw StateError(
        'WASI component task $name cannot $operation with $_borrowCount active borrows.',
      );
    }
  }

  void _requireNotResolved() {
    if (_state.isResolved) {
      throw StateError('WASI component task $name already resolved.');
    }
  }
}

/// Host for canonical `task.*` operations for the current component task.
final class WASIComponentTaskHost {
  /// Creates a task host.
  WASIComponentTaskHost({WASIComponentWaitableHost? waitableHost})
    : _waitableHost = waitableHost;

  final WASIComponentWaitableHost? _waitableHost;
  final WASIComponentCurrent<WASIComponentTask> _currentTask =
      WASIComponentCurrent<WASIComponentTask>();

  /// The task currently executing canonical `task.*` operations.
  WASIComponentTask? get currentTask => _currentTask.current;

  /// Creates a task linked to [subtask] and this host's cancellation delivery.
  WASIComponentTask createTask({
    String name = 'task',
    WASIComponentSubtask? subtask,
  }) {
    return WASIComponentTask(
      name: name,
      subtask: subtask,
      onCancellationRequested: (task) =>
          _waitableHost?.requestTaskCancellation(task),
    );
  }

  /// Runs [callback] with [task] as the current task.
  T runWithTask<T>(WASIComponentTask task, T Function() callback) {
    final waitableHost = _waitableHost;
    if (waitableHost == null) {
      return _currentTask.run(task, callback);
    }
    try {
      return waitableHost.runWithTask(
        task,
        () => _currentTask.run(task, callback),
      );
    } finally {
      if (task.state.isResolved) {
        waitableHost.releaseTask(task);
      }
    }
  }

  /// Runs [callback] with [task] as the current task until it completes.
  Future<T> runWithTaskAsync<T>(
    WASIComponentTask task,
    Future<T> Function() callback,
  ) async {
    final waitableHost = _waitableHost;
    if (waitableHost == null) {
      return await _currentTask.runAsync(task, callback);
    }
    return await waitableHost.runWithTaskAsync(
      task,
      () => _currentTask.runAsync(task, callback),
    );
  }

  /// Executes `task.return` on the current task.
  void taskReturn({Object? result, bool hasResult = false}) {
    _requireCurrentTask().returnResult(result: result, hasResult: hasResult);
  }

  /// Executes `task.cancel` on the current task.
  void taskCancel() {
    _requireCurrentTask().cancel();
  }

  /// Binds a decoded canonical task definition.
  WASIComponentCanonicalTaskOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition, {
    List<WasmComponentTypeDefinition> typeDefinitions = const [],
    WasmComponentTypeScope? typeScope,
  }) {
    if (!_isTaskCanonicalKind(definition.kind)) {
      throw UnsupportedError(
        'Wasm component canonical ${definition.kind.name} is not a task operation.',
      );
    }
    return WASIComponentCanonicalTaskOperation._(
      host: this,
      kind: definition.kind,
      result: definition.result,
      resultFlatLength: _taskReturnResultFlatLength(
        definition,
        typeDefinitions,
        typeScope,
      ),
      stringEncoding: WASIComponentCanonicalStringEncoding.fromCanonicalOptions(
        definition.options,
      ),
    );
  }

  /// Binds all decoded canonical task definitions in [component].
  WASIComponentCanonicalTaskProgram bindCanonicalDefinitions(
    WasmComponent component,
  ) {
    return WASIComponentCanonicalTaskProgram(
      operations: List<WASIComponentCanonicalTaskOperation>.unmodifiable([
        for (final definition in component.canonicalDefinitions)
          bindCanonicalDefinition(
            definition,
            typeDefinitions: component.componentTypeIndexDefinitions,
            typeScope: component.componentTypeIndexScope,
          ),
      ]),
    );
  }

  WASIComponentTask _requireCurrentTask() {
    final task = currentTask;
    if (task == null) {
      throw StateError('No current WASI component task.');
    }
    return task;
  }
}

/// Executable task-only canonical program for a decoded component.
final class WASIComponentCanonicalTaskProgram {
  /// Creates a canonical task program from ordered [operations].
  const WASIComponentCanonicalTaskProgram({required this.operations});

  /// Task operations in component canonical definition order.
  final List<WASIComponentCanonicalTaskOperation> operations;

  /// Invokes the canonical task operation at [canonicalIndex].
  Object? invoke(int canonicalIndex, List<Object?> args) {
    final operation = _operationAt(canonicalIndex);
    switch (operation.kind) {
      case WasmComponentCanonicalKind.taskReturn:
        final hasResult = operation.hasResult;
        if (operation.isResultIndirect) {
          throw StateError(
            'WASI component canonical task index $canonicalIndex requires '
            'memory-backed invocation for its indirect result.',
          );
        }
        final expected = operation.resultFlatLength ?? 0;
        _expectArity(canonicalIndex, args, hasResult ? expected : 0);
        operation.taskReturn(
          result: hasResult
              ? (args.length == 1
                    ? args.single
                    : List<Object?>.unmodifiable(args))
              : null,
        );
        return null;
      case WasmComponentCanonicalKind.taskCancel:
        _expectArity(canonicalIndex, args, 0);
        operation.taskCancel();
        return null;
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the task program.',
        );
    }
  }

  /// Invokes the canonical task operation with canonical memory arguments.
  Object? invokeWithMemory(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args,
  ) {
    final operation = _operationAt(canonicalIndex);
    switch (operation.kind) {
      case WasmComponentCanonicalKind.taskReturn:
        if (!operation.hasResult) {
          _expectArity(canonicalIndex, args, 0);
          operation.taskReturn();
          return null;
        }
        if (!operation.isResultIndirect) {
          throw StateError(
            'WASI component canonical task index $canonicalIndex has a direct '
            'result; invoke it with canonical flat arguments.',
          );
        }
        _expectArity(canonicalIndex, args, 1);
        operation.taskReturn(
          result: _expectPointer(canonicalIndex, args.single),
        );
        return null;
      case WasmComponentCanonicalKind.taskCancel:
        _expectArity(canonicalIndex, args, 0);
        operation.taskCancel();
        return null;
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the task program.',
        );
    }
  }

  WASIComponentCanonicalTaskOperation _operationAt(int canonicalIndex) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical task index: $canonicalIndex.',
      );
    }
    return operations[canonicalIndex];
  }
}

/// Executable form of a canonical `task.*` operation.
final class WASIComponentCanonicalTaskOperation {
  const WASIComponentCanonicalTaskOperation._({
    required WASIComponentTaskHost host,
    required this.kind,
    required this.result,
    required this.resultFlatLength,
    required this.stringEncoding,
  }) : _host = host;

  final WASIComponentTaskHost _host;

  /// Canonical task operation kind.
  final WasmComponentCanonicalKind kind;

  /// Decoded `task.return` result metadata, if any.
  final WasmComponentCanonicalResult? result;

  /// Number of direct core scalar parameters consumed by `task.return`.
  final int? resultFlatLength;

  /// Canonical string encoding used by memory-backed return values.
  final WASIComponentCanonicalStringEncoding stringEncoding;

  /// Whether `task.return` expects a result value.
  bool get hasResult => result?.valueType != null;

  /// Whether `task.return` receives one pointer to an indirect result value.
  bool get isResultIndirect =>
      (resultFlatLength ?? 0) > _canonicalMaxFlatTaskReturnValues;

  /// Executes `task.return`.
  void taskReturn({Object? result}) {
    _requireKind(WasmComponentCanonicalKind.taskReturn);
    _host.taskReturn(result: result, hasResult: hasResult);
  }

  /// Executes `task.cancel`.
  void taskCancel() {
    _requireKind(WasmComponentCanonicalKind.taskCancel);
    _host.taskCancel();
  }

  void _requireKind(WasmComponentCanonicalKind expected) {
    if (kind != expected) {
      throw StateError(
        'WASI component canonical ${kind.name} cannot execute ${expected.name}.',
      );
    }
  }
}

bool _isTaskCanonicalKind(WasmComponentCanonicalKind kind) =>
    kind == WasmComponentCanonicalKind.taskReturn ||
    kind == WasmComponentCanonicalKind.taskCancel;

int? _taskReturnResultFlatLength(
  WasmComponentCanonicalDefinition definition,
  List<WasmComponentTypeDefinition> typeDefinitions,
  WasmComponentTypeScope? typeScope,
) {
  if (definition.kind != WasmComponentCanonicalKind.taskReturn) {
    return null;
  }
  final resultType = definition.result?.valueType;
  if (resultType == null) {
    return 0;
  }
  final flatLayout = componentCanonicalFlatLayout(
    resultType,
    typeDefinitions,
    typeScope: typeScope,
  );
  if (flatLayout == null) {
    throw UnsupportedError(
      'WASI component canonical task.return result has no supported flat layout.',
    );
  }
  return flatLayout.flatLength;
}

void _expectArity(int canonicalIndex, List<Object?> args, int expected) {
  if (args.length != expected) {
    throw StateError(
      'WASI component canonical task index $canonicalIndex expected '
      '$expected arguments, got ${args.length}.',
    );
  }
}

int _expectPointer(int canonicalIndex, Object? value) {
  if (value is int) {
    return value.toUnsigned(32);
  }
  throw StateError(
    'WASI component canonical task index $canonicalIndex expected a memory pointer.',
  );
}
