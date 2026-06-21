import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'async_host.dart';
import 'backpressure.dart';
import 'context.dart';
import 'error_context.dart';
import 'resource_host.dart';
import 'resource_table.dart';
import 'subtask.dart';
import 'task.dart';
import 'thread.dart';
import 'waitable_set.dart';

/// Internal Component Model canonical host facade.
///
/// This does not make P2/P3 public API claims. It binds the canonical builtins
/// already implemented by the focused component hosts into one canonical-indexed
/// program so future versioned WASI adapters can use one execution boundary.
final class WASIComponentCanonicalHost {
  /// Creates a canonical host over shared component runtime state.
  WASIComponentCanonicalHost({
    WASIComponentResourceTable? table,
    WASIComponentBackpressure? backpressure,
    WASIComponentContext? context,
    int availableParallelism = 1,
  }) : table = table ?? WASIComponentResourceTable() {
    resourceHost = WASIComponentResourceHost(table: this.table);
    asyncHost = WASIComponentAsyncHost(
      table: this.table,
      backpressure: backpressure,
    );
    subtaskHost = WASIComponentSubtaskHost(table: this.table);
    waitableHost = WASIComponentWaitableHost(
      table: this.table,
      waitableResolvers: [
        subtaskHost.waitableForHandle,
        asyncHost.waitableForHandle,
      ],
    );
    taskHost = WASIComponentTaskHost(waitableHost: waitableHost);
    contextHost = WASIComponentContextHost(context: context);
    threadHost = WASIComponentThreadHost(
      contextHost: contextHost,
      availableParallelism: availableParallelism,
    );
    errorContextHost = WASIComponentErrorContextHost(table: this.table);
  }

  /// Shared component resource table.
  final WASIComponentResourceTable table;

  /// Resource host used for canonical `resource.*` operations.
  late final WASIComponentResourceHost resourceHost;

  /// Async host used for canonical `stream.*`, `future.*`, and backpressure.
  late final WASIComponentAsyncHost asyncHost;

  /// Waitable host used for canonical `waitable.*` operations.
  late final WASIComponentWaitableHost waitableHost;

  /// Subtask host used for canonical `subtask.*` operations.
  late final WASIComponentSubtaskHost subtaskHost;

  /// Callee task host used for canonical `task.*` operations.
  late final WASIComponentTaskHost taskHost;

  /// Context host used for canonical `context.*` operations.
  late final WASIComponentContextHost contextHost;

  /// Thread host used for supported canonical `thread.*` identity operations.
  late final WASIComponentThreadHost threadHost;

  /// Error-context host used for canonical `error-context.*` operations.
  late final WASIComponentErrorContextHost errorContextHost;

  /// Binds decoded canonical definitions from [component].
  WASIComponentCanonicalProgram bindComponent(
    WasmComponent component, {
    bool validate = true,
  }) {
    if (validate) {
      final errors = component.validate();
      if (errors.isNotEmpty) {
        throw WASIComponentCanonicalHostValidationException(errors);
      }
    }
    return bindCanonicalDefinitions(component.canonicalDefinitions);
  }

  /// Binds canonical definitions in their decoded canonical index order.
  WASIComponentCanonicalProgram bindCanonicalDefinitions(
    Iterable<WasmComponentCanonicalDefinition> definitions,
  ) {
    final definitionList = definitions is List<WasmComponentCanonicalDefinition>
        ? definitions
        : definitions.toList(growable: false);
    final unsupported = unsupportedCanonicalDefinitions(definitionList);
    if (unsupported.isNotEmpty) {
      throw WASIComponentCanonicalHostUnsupportedException(unsupported);
    }
    final operations = <WASIComponentCanonicalOperation>[];
    for (final definition in definitionList) {
      operations.add(_bindSupportedCanonicalDefinition(definition));
    }
    return WASIComponentCanonicalProgram(
      operations: List<WASIComponentCanonicalOperation>.unmodifiable(
        operations,
      ),
    );
  }

  /// Returns `true` when this host can bind canonical [kind].
  bool supportsCanonicalKind(WasmComponentCanonicalKind kind) {
    return _unsupportedCanonicalKindReason(kind) == null;
  }

  /// Reports unsupported definitions without partially binding a program.
  List<WASIComponentCanonicalHostUnsupportedDefinition>
  unsupportedCanonicalDefinitions(
    Iterable<WasmComponentCanonicalDefinition> definitions,
  ) {
    final unsupported = <WASIComponentCanonicalHostUnsupportedDefinition>[];
    var canonicalIndex = 0;
    for (final definition in definitions) {
      final reason = _unsupportedCanonicalKindReason(definition.kind);
      if (reason != null) {
        unsupported.add(
          WASIComponentCanonicalHostUnsupportedDefinition(
            canonicalIndex: canonicalIndex,
            definition: definition,
            reason: reason,
          ),
        );
      }
      canonicalIndex++;
    }
    return List<WASIComponentCanonicalHostUnsupportedDefinition>.unmodifiable(
      unsupported,
    );
  }

  /// Binds one decoded canonical definition.
  WASIComponentCanonicalOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    final unsupportedReason = _unsupportedCanonicalKindReason(definition.kind);
    if (unsupportedReason != null) {
      throw UnsupportedError(
        _unsupportedCanonicalDefinitionMessage(
          0,
          definition.kind,
          unsupportedReason,
        ),
      );
    }
    return _bindSupportedCanonicalDefinition(definition);
  }

  WASIComponentCanonicalOperation _bindSupportedCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    switch (definition.kind) {
      case WasmComponentCanonicalKind.resourceNew:
      case WasmComponentCanonicalKind.resourceDrop:
      case WasmComponentCanonicalKind.resourceRep:
        return _bindResource(definition);
      case WasmComponentCanonicalKind.backpressureSet:
      case WasmComponentCanonicalKind.backpressureInc:
      case WasmComponentCanonicalKind.backpressureDec:
      case WasmComponentCanonicalKind.streamNew:
      case WasmComponentCanonicalKind.streamRead:
      case WasmComponentCanonicalKind.streamWrite:
      case WasmComponentCanonicalKind.streamCancelRead:
      case WasmComponentCanonicalKind.streamCancelWrite:
      case WasmComponentCanonicalKind.streamDropReadable:
      case WasmComponentCanonicalKind.streamDropWritable:
      case WasmComponentCanonicalKind.futureNew:
      case WasmComponentCanonicalKind.futureRead:
      case WasmComponentCanonicalKind.futureWrite:
      case WasmComponentCanonicalKind.futureCancelRead:
      case WasmComponentCanonicalKind.futureCancelWrite:
      case WasmComponentCanonicalKind.futureDropReadable:
      case WasmComponentCanonicalKind.futureDropWritable:
        return _bindAsync(definition);
      case WasmComponentCanonicalKind.waitableSetNew:
      case WasmComponentCanonicalKind.waitableSetWait:
      case WasmComponentCanonicalKind.waitableSetPoll:
      case WasmComponentCanonicalKind.waitableSetDrop:
      case WasmComponentCanonicalKind.waitableJoin:
        return _bindWaitable(definition);
      case WasmComponentCanonicalKind.subtaskCancel:
      case WasmComponentCanonicalKind.subtaskDrop:
        return _bindSubtask(definition);
      case WasmComponentCanonicalKind.taskReturn:
      case WasmComponentCanonicalKind.taskCancel:
        return _bindTask(definition);
      case WasmComponentCanonicalKind.contextGet:
      case WasmComponentCanonicalKind.contextSet:
        return _bindContext(definition);
      case WasmComponentCanonicalKind.threadIndex:
      case WasmComponentCanonicalKind.threadAvailableParallelism:
        return _bindThread(definition);
      case WasmComponentCanonicalKind.errorContextNew:
      case WasmComponentCanonicalKind.errorContextDebugMessage:
      case WasmComponentCanonicalKind.errorContextDrop:
        return _bindErrorContext(definition);
      case WasmComponentCanonicalKind.lift:
      case WasmComponentCanonicalKind.lower:
      case WasmComponentCanonicalKind.threadYield:
      case WasmComponentCanonicalKind.threadNewIndirect:
      case WasmComponentCanonicalKind.threadSwitchTo:
      case WasmComponentCanonicalKind.threadSuspend:
      case WasmComponentCanonicalKind.threadResumeLater:
      case WasmComponentCanonicalKind.threadYieldTo:
      case WasmComponentCanonicalKind.threadSpawnRef:
      case WasmComponentCanonicalKind.threadSpawnIndirect:
        throw StateError(
          'Unsupported canonical ${definition.kind.name} reached binding after preflight.',
        );
    }
  }

  WASIComponentCanonicalOperation _bindResource(
    WasmComponentCanonicalDefinition definition,
  ) {
    final program = WASIComponentCanonicalResourceProgram(
      operations: [resourceHost.bindCanonicalDefinition(definition)],
    );
    return WASIComponentCanonicalOperation._(
      kind: definition.kind,
      invoke: (args) => program.invoke(0, args),
    );
  }

  WASIComponentCanonicalOperation _bindAsync(
    WasmComponentCanonicalDefinition definition,
  ) {
    final program = WASIComponentCanonicalAsyncHandleProgram(
      operations: [asyncHost.bindCanonicalDefinition(definition)],
    );
    return WASIComponentCanonicalOperation._(
      kind: definition.kind,
      invoke: (args) => program.invoke(0, args),
      invokeAsync: (args) => program.invokeAsync(0, args),
      invokeWithMemory: (memory, args) =>
          program.invokeWithMemory(0, memory, args),
      invokeWithMemoryEvent: (memory, args) =>
          program.invokeWithMemoryEvent(0, memory, args),
      invokeWithMemoryAsync: (memory, args) =>
          program.invokeWithMemoryAsync(0, memory, args),
    );
  }

  WASIComponentCanonicalOperation _bindWaitable(
    WasmComponentCanonicalDefinition definition,
  ) {
    final program = WASIComponentCanonicalWaitableProgram(
      operations: [waitableHost.bindCanonicalDefinition(definition)],
    );
    return WASIComponentCanonicalOperation._(
      kind: definition.kind,
      invoke: (args) => program.invoke(0, args),
      invokeWithMemory: (memory, args) =>
          program.invokeWithMemory(0, memory, args),
      invokeWithMemoryAsync: (memory, args) =>
          program.invokeWithMemoryAsync(0, memory, args),
    );
  }

  WASIComponentCanonicalOperation _bindSubtask(
    WasmComponentCanonicalDefinition definition,
  ) {
    final program = WASIComponentCanonicalSubtaskProgram(
      operations: [subtaskHost.bindCanonicalDefinition(definition)],
    );
    return WASIComponentCanonicalOperation._(
      kind: definition.kind,
      invoke: (args) => program.invoke(0, args),
      invokeAsync: (args) => program.invokeAsync(0, args),
    );
  }

  WASIComponentCanonicalOperation _bindTask(
    WasmComponentCanonicalDefinition definition,
  ) {
    final program = WASIComponentCanonicalTaskProgram(
      operations: [taskHost.bindCanonicalDefinition(definition)],
    );
    return WASIComponentCanonicalOperation._(
      kind: definition.kind,
      invoke: (args) => program.invoke(0, args),
    );
  }

  WASIComponentCanonicalOperation _bindContext(
    WasmComponentCanonicalDefinition definition,
  ) {
    final program = WASIComponentCanonicalContextProgram(
      operations: [contextHost.bindCanonicalDefinition(definition)],
    );
    return WASIComponentCanonicalOperation._(
      kind: definition.kind,
      invoke: (args) => program.invoke(0, args),
    );
  }

  WASIComponentCanonicalOperation _bindThread(
    WasmComponentCanonicalDefinition definition,
  ) {
    final program = WASIComponentCanonicalThreadProgram(
      operations: [threadHost.bindCanonicalDefinition(definition)],
    );
    return WASIComponentCanonicalOperation._(
      kind: definition.kind,
      invoke: (args) => program.invoke(0, args),
    );
  }

  WASIComponentCanonicalOperation _bindErrorContext(
    WasmComponentCanonicalDefinition definition,
  ) {
    final program = WASIComponentCanonicalErrorContextProgram(
      operations: [errorContextHost.bindCanonicalDefinition(definition)],
    );
    return WASIComponentCanonicalOperation._(
      kind: definition.kind,
      invoke: (args) => program.invoke(0, args),
    );
  }
}

/// One unsupported canonical definition found during host capability preflight.
final class WASIComponentCanonicalHostUnsupportedDefinition {
  /// Creates an unsupported-definition report.
  const WASIComponentCanonicalHostUnsupportedDefinition({
    required this.canonicalIndex,
    required this.definition,
    required this.reason,
  });

  /// Canonical definition index in the decoded component.
  final int canonicalIndex;

  /// Decoded canonical definition that cannot be bound.
  final WasmComponentCanonicalDefinition definition;

  /// Why this host cannot bind [definition].
  final String reason;

  /// Canonical kind that cannot be bound.
  WasmComponentCanonicalKind get kind => definition.kind;

  @override
  String toString() {
    return _unsupportedCanonicalDefinitionMessage(
      canonicalIndex,
      definition.kind,
      reason,
    );
  }
}

/// Thrown when canonical definitions require unsupported host capabilities.
final class WASIComponentCanonicalHostUnsupportedException
    implements Exception {
  /// Creates an exception from unsupported [definitions].
  WASIComponentCanonicalHostUnsupportedException(
    Iterable<WASIComponentCanonicalHostUnsupportedDefinition> definitions,
  ) : definitions =
          List<WASIComponentCanonicalHostUnsupportedDefinition>.unmodifiable(
            definitions,
          );

  /// Unsupported definitions that blocked binding.
  final List<WASIComponentCanonicalHostUnsupportedDefinition> definitions;

  @override
  String toString() {
    final buffer = StringBuffer(
      'WASI component canonical host cannot bind unsupported definitions',
    );
    for (final definition in definitions) {
      buffer
        ..write('\n')
        ..write(definition);
    }
    return buffer.toString();
  }
}

/// Thrown when a decoded component fails validation before canonical binding.
final class WASIComponentCanonicalHostValidationException implements Exception {
  /// Creates a validation exception with component validation [errors].
  const WASIComponentCanonicalHostValidationException(this.errors);

  /// Component validation errors that blocked binding.
  final List<WasmComponentValidationError> errors;

  @override
  String toString() {
    final buffer = StringBuffer(
      'WASI component canonical host cannot bind invalid component',
    );
    for (final error in errors) {
      buffer
        ..write('\n')
        ..write(error.path)
        ..write(': ')
        ..write(error.message);
    }
    return buffer.toString();
  }
}

String? _unsupportedCanonicalKindReason(WasmComponentCanonicalKind kind) {
  switch (kind) {
    case WasmComponentCanonicalKind.resourceNew:
    case WasmComponentCanonicalKind.resourceDrop:
    case WasmComponentCanonicalKind.resourceRep:
    case WasmComponentCanonicalKind.backpressureSet:
    case WasmComponentCanonicalKind.backpressureInc:
    case WasmComponentCanonicalKind.backpressureDec:
    case WasmComponentCanonicalKind.streamNew:
    case WasmComponentCanonicalKind.streamRead:
    case WasmComponentCanonicalKind.streamWrite:
    case WasmComponentCanonicalKind.streamCancelRead:
    case WasmComponentCanonicalKind.streamCancelWrite:
    case WasmComponentCanonicalKind.streamDropReadable:
    case WasmComponentCanonicalKind.streamDropWritable:
    case WasmComponentCanonicalKind.futureNew:
    case WasmComponentCanonicalKind.futureRead:
    case WasmComponentCanonicalKind.futureWrite:
    case WasmComponentCanonicalKind.futureCancelRead:
    case WasmComponentCanonicalKind.futureCancelWrite:
    case WasmComponentCanonicalKind.futureDropReadable:
    case WasmComponentCanonicalKind.futureDropWritable:
    case WasmComponentCanonicalKind.waitableSetNew:
    case WasmComponentCanonicalKind.waitableSetWait:
    case WasmComponentCanonicalKind.waitableSetPoll:
    case WasmComponentCanonicalKind.waitableSetDrop:
    case WasmComponentCanonicalKind.waitableJoin:
    case WasmComponentCanonicalKind.subtaskCancel:
    case WasmComponentCanonicalKind.subtaskDrop:
    case WasmComponentCanonicalKind.taskReturn:
    case WasmComponentCanonicalKind.taskCancel:
    case WasmComponentCanonicalKind.contextGet:
    case WasmComponentCanonicalKind.contextSet:
    case WasmComponentCanonicalKind.threadIndex:
    case WasmComponentCanonicalKind.threadAvailableParallelism:
    case WasmComponentCanonicalKind.errorContextNew:
    case WasmComponentCanonicalKind.errorContextDebugMessage:
    case WasmComponentCanonicalKind.errorContextDrop:
      return null;
    case WasmComponentCanonicalKind.lift:
    case WasmComponentCanonicalKind.lower:
      return 'canonical lift/lower require typed core function adapter generation';
    case WasmComponentCanonicalKind.threadYield:
    case WasmComponentCanonicalKind.threadNewIndirect:
    case WasmComponentCanonicalKind.threadSwitchTo:
    case WasmComponentCanonicalKind.threadSuspend:
    case WasmComponentCanonicalKind.threadResumeLater:
    case WasmComponentCanonicalKind.threadYieldTo:
    case WasmComponentCanonicalKind.threadSpawnRef:
    case WasmComponentCanonicalKind.threadSpawnIndirect:
      return 'scheduler-dependent canonical thread operations require component task scheduling';
  }
}

String _unsupportedCanonicalDefinitionMessage(
  int canonicalIndex,
  WasmComponentCanonicalKind kind,
  String reason,
) {
  return 'canonical[$canonicalIndex].${kind.name}: $reason';
}

/// Bound canonical program preserving component canonical index order.
final class WASIComponentCanonicalProgram {
  /// Creates a bound program from [operations].
  const WASIComponentCanonicalProgram({required this.operations});

  /// Bound operations in component canonical definition order.
  final List<WASIComponentCanonicalOperation> operations;

  /// Invokes a canonical operation by canonical index.
  Object? invoke(int canonicalIndex, List<Object?> args) {
    return _operationAt(canonicalIndex).invoke(args);
  }

  /// Invokes a canonical operation and waits when the operation supports it.
  Future<Object?> invokeAsync(int canonicalIndex, List<Object?> args) {
    return _operationAt(canonicalIndex).invokeAsync(args);
  }

  /// Invokes a memory-backed canonical operation.
  Object? invokeWithMemory(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args,
  ) {
    return _operationAt(canonicalIndex).invokeWithMemory(memory, args);
  }

  /// Starts a memory-backed canonical event operation.
  Object? invokeWithMemoryEvent(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args,
  ) {
    return _operationAt(canonicalIndex).invokeWithMemoryEvent(memory, args);
  }

  /// Invokes a memory-backed canonical operation and waits if needed.
  Future<Object?> invokeWithMemoryAsync(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args,
  ) {
    return _operationAt(canonicalIndex).invokeWithMemoryAsync(memory, args);
  }

  WASIComponentCanonicalOperation _operationAt(int canonicalIndex) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical index: $canonicalIndex.',
      );
    }
    return operations[canonicalIndex];
  }
}

typedef _WASIComponentInvoke = Object? Function(List<Object?> args);
typedef _WASIComponentInvokeAsync =
    Future<Object?> Function(List<Object?> args);
typedef _WASIComponentInvokeWithMemory =
    Object? Function(wasm.Memory memory, List<Object?> args);
typedef _WASIComponentInvokeWithMemoryAsync =
    Future<Object?> Function(wasm.Memory memory, List<Object?> args);

/// Bound canonical operation.
final class WASIComponentCanonicalOperation {
  const WASIComponentCanonicalOperation._({
    required this.kind,
    required _WASIComponentInvoke invoke,
    _WASIComponentInvokeAsync? invokeAsync,
    _WASIComponentInvokeWithMemory? invokeWithMemory,
    _WASIComponentInvokeWithMemory? invokeWithMemoryEvent,
    _WASIComponentInvokeWithMemoryAsync? invokeWithMemoryAsync,
  }) : _invoke = invoke,
       _invokeAsync = invokeAsync,
       _invokeWithMemory = invokeWithMemory,
       _invokeWithMemoryEvent = invokeWithMemoryEvent,
       _invokeWithMemoryAsync = invokeWithMemoryAsync;

  /// Canonical operation kind.
  final WasmComponentCanonicalKind kind;

  final _WASIComponentInvoke _invoke;
  final _WASIComponentInvokeAsync? _invokeAsync;
  final _WASIComponentInvokeWithMemory? _invokeWithMemory;
  final _WASIComponentInvokeWithMemory? _invokeWithMemoryEvent;
  final _WASIComponentInvokeWithMemoryAsync? _invokeWithMemoryAsync;

  /// Invokes this canonical operation.
  Object? invoke(List<Object?> args) {
    return _invoke(args);
  }

  /// Invokes this canonical operation and waits when supported.
  Future<Object?> invokeAsync(List<Object?> args) {
    final invokeAsync = _invokeAsync;
    if (invokeAsync != null) {
      return invokeAsync(args);
    }
    return Future<Object?>.value(invoke(args));
  }

  /// Invokes this canonical operation with [memory].
  Object? invokeWithMemory(wasm.Memory memory, List<Object?> args) {
    final invokeWithMemory = _invokeWithMemory;
    if (invokeWithMemory != null) {
      return invokeWithMemory(memory, args);
    }
    return invoke(args);
  }

  /// Starts this canonical operation's waitable event path with [memory].
  Object? invokeWithMemoryEvent(wasm.Memory memory, List<Object?> args) {
    final invokeWithMemoryEvent = _invokeWithMemoryEvent;
    if (invokeWithMemoryEvent != null) {
      return invokeWithMemoryEvent(memory, args);
    }
    return invokeWithMemory(memory, args);
  }

  /// Invokes this canonical operation with [memory] and waits when supported.
  Future<Object?> invokeWithMemoryAsync(
    wasm.Memory memory,
    List<Object?> args,
  ) {
    final invokeWithMemoryAsync = _invokeWithMemoryAsync;
    if (invokeWithMemoryAsync != null) {
      return invokeWithMemoryAsync(memory, args);
    }
    return Future<Object?>.value(invokeWithMemory(memory, args));
  }
}
