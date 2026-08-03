import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'adapter_host.dart';
import 'string_memory.dart';
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

/// Component Model canonical host facade.
///
/// This binds the canonical builtins implemented by the focused component
/// hosts into one canonical-indexed program so versioned WASI adapters can use
/// one execution boundary.
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
    adapterHost = WASIComponentCanonicalAdapterHost(asyncHost: asyncHost);
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

  /// Adapter host used for executable canonical `lift`/`lower` operations.
  late final WASIComponentCanonicalAdapterHost adapterHost;

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
    return prepareComponent(component, validate: validate).bind();
  }

  /// Builds a reusable component binding plan without partially binding.
  WASIComponentCanonicalBindingPlan prepareComponent(
    WasmComponent component, {
    bool validate = true,
  }) {
    final definitions = List<WasmComponentCanonicalDefinition>.unmodifiable(
      component.canonicalDefinitions,
    );
    final validationErrors = validate
        ? component.validate()
        : const <WasmComponentValidationError>[];
    final unsupported = unsupportedCanonicalDefinitions(definitions);
    return WASIComponentCanonicalBindingPlan._(
      host: this,
      canonicalDefinitions: definitions,
      typeDefinitions: List<WasmComponentTypeDefinition>.unmodifiable(
        component.componentTypeIndexDefinitions,
      ),
      typeScope: component.componentTypeIndexScope,
      validationErrors: List<WasmComponentValidationError>.unmodifiable(
        validationErrors,
      ),
      unsupportedDefinitions: unsupported,
    );
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
    return _bindSupportedCanonicalDefinitions(definitionList);
  }

  WASIComponentCanonicalProgram _bindSupportedCanonicalDefinitions(
    List<WasmComponentCanonicalDefinition> definitions, {
    List<WasmComponentTypeDefinition> typeDefinitions = const [],
    WasmComponentTypeScope? typeScope,
    WASIComponentResourceBindingSet<Object>? resourceBindingSet,
    Map<int, WASIComponentCanonicalAdapterOperation> adapterOperations =
        const <int, WASIComponentCanonicalAdapterOperation>{},
  }) {
    final operations = <WASIComponentCanonicalOperation>[];
    for (
      var canonicalIndex = 0;
      canonicalIndex < definitions.length;
      canonicalIndex++
    ) {
      operations.add(
        _bindSupportedCanonicalDefinition(
          definitions[canonicalIndex],
          canonicalIndex: canonicalIndex,
          typeDefinitions: typeDefinitions,
          typeScope: typeScope,
          resourceBindingSet: resourceBindingSet,
          adapterOperations: adapterOperations,
        ),
      );
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

  /// Describes this host's support for every decoded canonical kind.
  ///
  /// Versioned P2/P3 adapters can use this table to preflight components
  /// without duplicating the canonical dispatch matrix.
  List<WASIComponentCanonicalKindCapability> get canonicalKindCapabilities {
    return List<WASIComponentCanonicalKindCapability>.unmodifiable([
      for (final kind in WasmComponentCanonicalKind.values)
        canonicalKindCapability(kind),
    ]);
  }

  /// Describes this host's support for one decoded canonical [kind].
  WASIComponentCanonicalKindCapability canonicalKindCapability(
    WasmComponentCanonicalKind kind,
  ) {
    final unsupportedReason = _unsupportedCanonicalKindReason(kind);
    return WASIComponentCanonicalKindCapability(
      kind: kind,
      area: _canonicalCapabilityArea(kind),
      unsupportedReason: unsupportedReason,
    );
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
    return _bindSupportedCanonicalDefinition(
      definition,
      canonicalIndex: 0,
      typeDefinitions: const <WasmComponentTypeDefinition>[],
      typeScope: null,
      resourceBindingSet: null,
      adapterOperations: const <int, WASIComponentCanonicalAdapterOperation>{},
    );
  }

  WASIComponentCanonicalOperation _bindSupportedCanonicalDefinition(
    WasmComponentCanonicalDefinition definition, {
    required int canonicalIndex,
    required List<WasmComponentTypeDefinition> typeDefinitions,
    required WasmComponentTypeScope? typeScope,
    required WASIComponentResourceBindingSet<Object>? resourceBindingSet,
    required Map<int, WASIComponentCanonicalAdapterOperation> adapterOperations,
  }) {
    switch (definition.kind) {
      case WasmComponentCanonicalKind.lift:
      case WasmComponentCanonicalKind.lower:
        return _bindAdapter(definition, canonicalIndex, adapterOperations);
      case WasmComponentCanonicalKind.resourceNew:
      case WasmComponentCanonicalKind.resourceDrop:
      case WasmComponentCanonicalKind.resourceRep:
        return _bindResource(definition, resourceBindingSet);
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
        return _bindTask(definition, typeDefinitions, typeScope);
      case WasmComponentCanonicalKind.contextGet:
      case WasmComponentCanonicalKind.contextSet:
        return _bindContext(definition);
      case WasmComponentCanonicalKind.threadYield:
      case WasmComponentCanonicalKind.threadIndex:
      case WasmComponentCanonicalKind.threadAvailableParallelism:
        return _bindThread(definition);
      case WasmComponentCanonicalKind.errorContextNew:
      case WasmComponentCanonicalKind.errorContextDebugMessage:
      case WasmComponentCanonicalKind.errorContextDrop:
        return _bindErrorContext(definition);
      case WasmComponentCanonicalKind.threadNewIndirect:
      case WasmComponentCanonicalKind.threadResumeLater:
      case WasmComponentCanonicalKind.threadSuspend:
      case WasmComponentCanonicalKind.threadSuspendThenResume:
      case WasmComponentCanonicalKind.threadYieldThenResume:
      case WasmComponentCanonicalKind.threadSuspendThenPromote:
      case WasmComponentCanonicalKind.threadYieldThenPromote:
      case WasmComponentCanonicalKind.threadSpawnRef:
      case WasmComponentCanonicalKind.threadSpawnIndirect:
        throw StateError(
          'Unsupported canonical ${definition.kind.name} reached binding after preflight.',
        );
    }
  }

  WASIComponentCanonicalOperation _bindAdapter(
    WasmComponentCanonicalDefinition definition,
    int canonicalIndex,
    Map<int, WASIComponentCanonicalAdapterOperation> adapterOperations,
  ) {
    final operation = adapterOperations[canonicalIndex];
    if (operation == null) {
      throw WASIComponentCanonicalHostAdapterException(
        canonicalIndex: canonicalIndex,
        definition: definition,
        reason: 'missing executable canonical adapter operation',
      );
    }
    if (operation.kind != definition.kind) {
      throw WASIComponentCanonicalHostAdapterException(
        canonicalIndex: canonicalIndex,
        definition: definition,
        reason:
            'adapter operation kind ${operation.kind.name} does not match '
            '${definition.kind.name}',
      );
    }
    return WASIComponentCanonicalOperation._(
      kind: definition.kind,
      invoke: operation.invoke,
      invokeAsync: operation.invokeAsync,
      invokeFlat: (args, memory, realloc) =>
          operation.invokeFlat(args, memory: memory, realloc: realloc),
      invokeFlatAsync: (args, memory, realloc) =>
          operation.invokeFlatAsync(args, memory: memory, realloc: realloc),
      invokeWithMemory: (memory, args, realloc, resultPointer) =>
          operation.invokeWithMemory(
            memory,
            _canonicalAdapterMemoryPointers(canonicalIndex, args),
            resultPointer: resultPointer,
            realloc: realloc,
          ),
      invokeWithMemoryAsync: (memory, args, realloc, resultPointer) =>
          operation.invokeWithMemoryAsync(
            memory,
            _canonicalAdapterMemoryPointers(canonicalIndex, args),
            resultPointer: resultPointer,
            realloc: realloc,
          ),
    );
  }

  WASIComponentCanonicalOperation _bindResource(
    WasmComponentCanonicalDefinition definition,
    WASIComponentResourceBindingSet<Object>? resourceBindingSet,
  ) {
    final program = WASIComponentCanonicalResourceProgram(
      operations: [
        resourceBindingSet?.bindCanonicalDefinition(definition) ??
            resourceHost.bindCanonicalDefinition(definition),
      ],
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
      invokeWithMemory: (memory, args, realloc, _) =>
          program.invokeWithMemory(0, memory, args, realloc: realloc),
      invokeWithMemoryEvent: (memory, args, realloc, _) =>
          program.invokeWithMemoryEvent(0, memory, args, realloc: realloc),
      invokeWithMemoryAsync: (memory, args, realloc, _) =>
          program.invokeWithMemoryAsync(0, memory, args, realloc: realloc),
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
      invokeWithMemory: (memory, args, _, _) =>
          program.invokeWithMemory(0, memory, args),
      invokeWithMemoryAsync: (memory, args, _, _) =>
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
    List<WasmComponentTypeDefinition> typeDefinitions,
    WasmComponentTypeScope? typeScope,
  ) {
    final program = WASIComponentCanonicalTaskProgram(
      operations: [
        taskHost.bindCanonicalDefinition(
          definition,
          typeDefinitions: typeDefinitions,
          typeScope: typeScope,
        ),
      ],
    );
    return WASIComponentCanonicalOperation._(
      kind: definition.kind,
      invoke: (args) => program.invoke(0, args),
      invokeWithMemory: (memory, args, _, _) =>
          program.invokeWithMemory(0, memory, args),
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
      invokeAsync: (args) => program.invokeAsync(0, args),
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
      invokeWithMemory: (memory, args, realloc, resultPointer) =>
          program.invokeWithMemory(
            0,
            memory,
            args,
            resultPointer: resultPointer,
            realloc: realloc,
          ),
    );
  }
}

/// Prepared canonical binding report for a decoded component.
final class WASIComponentCanonicalBindingPlan {
  const WASIComponentCanonicalBindingPlan._({
    required WASIComponentCanonicalHost host,
    required this.canonicalDefinitions,
    required this.typeDefinitions,
    required this.typeScope,
    required this.validationErrors,
    required this.unsupportedDefinitions,
  }) : _host = host;

  final WASIComponentCanonicalHost _host;

  /// Canonical definitions captured when the plan was prepared.
  final List<WasmComponentCanonicalDefinition> canonicalDefinitions;

  /// Component type definitions captured for memory-backed canonical values.
  final List<WasmComponentTypeDefinition> typeDefinitions;

  /// Definition-local type scopes retained for imported aliases.
  final WasmComponentTypeScope? typeScope;

  /// Component validation errors that must be fixed before binding.
  final List<WasmComponentValidationError> validationErrors;

  /// Unsupported canonical definitions that this host cannot bind.
  final List<WASIComponentCanonicalHostUnsupportedDefinition>
  unsupportedDefinitions;

  /// Whether [bind] can build a canonical program without throwing.
  bool get canBind =>
      validationErrors.isEmpty &&
      unsupportedDefinitions.isEmpty &&
      !requiresAdapterOperations;

  /// Whether this plan needs executable `lift`/`lower` adapter operations.
  bool get requiresAdapterOperations =>
      canonicalDefinitions.any(_isCanonicalAdapterDefinition);

  /// Builds the canonical program after validation and capability preflight.
  WASIComponentCanonicalProgram bind() {
    return bindWithAdapterOperations(
      const <WASIComponentCanonicalAdapterOperation>[],
    );
  }

  /// Builds the canonical program with executable `lift`/`lower` adapters.
  WASIComponentCanonicalProgram bindWithAdapterOperations(
    Iterable<WASIComponentCanonicalAdapterOperation> adapterOperations, {
    WASIComponentResourceBindingSet<Object>? resourceBindingSet,
  }) {
    if (validationErrors.isNotEmpty) {
      throw WASIComponentCanonicalHostValidationException(validationErrors);
    }
    if (unsupportedDefinitions.isNotEmpty) {
      throw WASIComponentCanonicalHostUnsupportedException(
        unsupportedDefinitions,
      );
    }
    final adaptersByCanonicalIndex =
        <int, WASIComponentCanonicalAdapterOperation>{
          for (final operation in adapterOperations)
            operation.canonicalIndex: operation,
        };
    return _host._bindSupportedCanonicalDefinitions(
      canonicalDefinitions,
      typeDefinitions: typeDefinitions,
      typeScope: typeScope,
      resourceBindingSet: resourceBindingSet,
      adapterOperations: Map.unmodifiable(adaptersByCanonicalIndex),
    );
  }
}

/// Thrown when canonical `lift`/`lower` lacks an executable adapter operation.
final class WASIComponentCanonicalHostAdapterException implements Exception {
  /// Creates an adapter binding exception.
  const WASIComponentCanonicalHostAdapterException({
    required this.canonicalIndex,
    required this.definition,
    required this.reason,
  });

  /// Canonical definition index in the decoded component.
  final int canonicalIndex;

  /// Canonical definition that required an adapter operation.
  final WasmComponentCanonicalDefinition definition;

  /// Why this adapter could not be bound.
  final String reason;

  @override
  String toString() {
    return 'canonical[$canonicalIndex].${definition.kind.name}: $reason';
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

/// Functional area covered by a Component Model canonical operation.
enum WASIComponentCanonicalCapabilityArea {
  /// Typed core function adapter generation for canonical lift/lower.
  adapterGeneration,

  /// Canonical component resource operations.
  resource,

  /// P3 async stream/future/backpressure operations.
  asyncValue,

  /// P3 waitable set operations.
  waitable,

  /// Caller-side subtask operations.
  subtask,

  /// Callee-side task operations.
  task,

  /// Component context get/set operations.
  context,

  /// Thread identity and availability operations.
  threadIdentity,

  /// Scheduler-dependent thread operations.
  threadScheduling,

  /// Error-context lifecycle and debug-message operations.
  errorContext,
}

/// Host support report for one Component Model canonical kind.
final class WASIComponentCanonicalKindCapability {
  /// Creates a canonical kind support report.
  const WASIComponentCanonicalKindCapability({
    required this.kind,
    required this.area,
    this.unsupportedReason,
  });

  /// Canonical operation kind.
  final WasmComponentCanonicalKind kind;

  /// Runtime area required by [kind].
  final WASIComponentCanonicalCapabilityArea area;

  /// Why [kind] cannot currently be bound, or `null` when supported.
  final String? unsupportedReason;

  /// Whether this host can bind [kind].
  bool get isSupported => unsupportedReason == null;
}

String? _unsupportedCanonicalKindReason(WasmComponentCanonicalKind kind) {
  switch (kind) {
    case WasmComponentCanonicalKind.resourceNew:
    case WasmComponentCanonicalKind.resourceDrop:
    case WasmComponentCanonicalKind.resourceRep:
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
    case WasmComponentCanonicalKind.threadYield:
    case WasmComponentCanonicalKind.threadIndex:
    case WasmComponentCanonicalKind.threadAvailableParallelism:
    case WasmComponentCanonicalKind.errorContextNew:
    case WasmComponentCanonicalKind.errorContextDebugMessage:
    case WasmComponentCanonicalKind.lift:
    case WasmComponentCanonicalKind.lower:
    case WasmComponentCanonicalKind.errorContextDrop:
      return null;
    case WasmComponentCanonicalKind.threadNewIndirect:
    case WasmComponentCanonicalKind.threadResumeLater:
    case WasmComponentCanonicalKind.threadSuspend:
    case WasmComponentCanonicalKind.threadSuspendThenResume:
    case WasmComponentCanonicalKind.threadYieldThenResume:
    case WasmComponentCanonicalKind.threadSuspendThenPromote:
    case WasmComponentCanonicalKind.threadYieldThenPromote:
    case WasmComponentCanonicalKind.threadSpawnRef:
    case WasmComponentCanonicalKind.threadSpawnIndirect:
      return 'scheduler-dependent canonical thread operations require component task scheduling';
  }
}

WASIComponentCanonicalCapabilityArea _canonicalCapabilityArea(
  WasmComponentCanonicalKind kind,
) {
  switch (kind) {
    case WasmComponentCanonicalKind.lift:
    case WasmComponentCanonicalKind.lower:
      return WASIComponentCanonicalCapabilityArea.adapterGeneration;
    case WasmComponentCanonicalKind.resourceNew:
    case WasmComponentCanonicalKind.resourceDrop:
    case WasmComponentCanonicalKind.resourceRep:
      return WASIComponentCanonicalCapabilityArea.resource;
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
      return WASIComponentCanonicalCapabilityArea.asyncValue;
    case WasmComponentCanonicalKind.waitableSetNew:
    case WasmComponentCanonicalKind.waitableSetWait:
    case WasmComponentCanonicalKind.waitableSetPoll:
    case WasmComponentCanonicalKind.waitableSetDrop:
    case WasmComponentCanonicalKind.waitableJoin:
      return WASIComponentCanonicalCapabilityArea.waitable;
    case WasmComponentCanonicalKind.subtaskCancel:
    case WasmComponentCanonicalKind.subtaskDrop:
      return WASIComponentCanonicalCapabilityArea.subtask;
    case WasmComponentCanonicalKind.taskReturn:
    case WasmComponentCanonicalKind.taskCancel:
      return WASIComponentCanonicalCapabilityArea.task;
    case WasmComponentCanonicalKind.contextGet:
    case WasmComponentCanonicalKind.contextSet:
      return WASIComponentCanonicalCapabilityArea.context;
    case WasmComponentCanonicalKind.threadIndex:
    case WasmComponentCanonicalKind.threadAvailableParallelism:
      return WASIComponentCanonicalCapabilityArea.threadIdentity;
    case WasmComponentCanonicalKind.threadYield:
    case WasmComponentCanonicalKind.threadNewIndirect:
    case WasmComponentCanonicalKind.threadResumeLater:
    case WasmComponentCanonicalKind.threadSuspend:
    case WasmComponentCanonicalKind.threadSuspendThenResume:
    case WasmComponentCanonicalKind.threadYieldThenResume:
    case WasmComponentCanonicalKind.threadSuspendThenPromote:
    case WasmComponentCanonicalKind.threadYieldThenPromote:
    case WasmComponentCanonicalKind.threadSpawnRef:
    case WasmComponentCanonicalKind.threadSpawnIndirect:
      return WASIComponentCanonicalCapabilityArea.threadScheduling;
    case WasmComponentCanonicalKind.errorContextNew:
    case WasmComponentCanonicalKind.errorContextDebugMessage:
    case WasmComponentCanonicalKind.errorContextDrop:
      return WASIComponentCanonicalCapabilityArea.errorContext;
  }
}

String _unsupportedCanonicalDefinitionMessage(
  int canonicalIndex,
  WasmComponentCanonicalKind kind,
  String reason,
) {
  return 'canonical[$canonicalIndex].${kind.name}: $reason';
}

bool _isCanonicalAdapterDefinition(
  WasmComponentCanonicalDefinition definition,
) {
  return switch (definition.kind) {
    WasmComponentCanonicalKind.lift || WasmComponentCanonicalKind.lower => true,
    _ => false,
  };
}

List<int> _canonicalAdapterMemoryPointers(
  int canonicalIndex,
  List<Object?> args,
) {
  return List<int>.generate(args.length, (index) {
    final value = args[index];
    if (value is! int) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex expected '
        'memory pointer argument $index to be int, got ${value.runtimeType}.',
      );
    }
    return value;
  }, growable: false);
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

  /// Invokes a flat Canonical ABI operation by canonical index.
  List<Object?> invokeFlat(
    int canonicalIndex,
    List<Object?> args, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    return _operationAt(
      canonicalIndex,
    ).invokeFlat(args, memory: memory, realloc: realloc);
  }

  /// Invokes a flat Canonical ABI operation by canonical index and waits when
  /// supported.
  Future<List<Object?>> invokeFlatAsync(
    int canonicalIndex,
    List<Object?> args, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    return _operationAt(
      canonicalIndex,
    ).invokeFlatAsync(args, memory: memory, realloc: realloc);
  }

  /// Invokes a memory-backed canonical operation.
  Object? invokeWithMemory(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    return _operationAt(canonicalIndex).invokeWithMemory(
      memory,
      args,
      resultPointer: resultPointer,
      realloc: realloc,
    );
  }

  /// Starts a memory-backed canonical event operation.
  Object? invokeWithMemoryEvent(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    return _operationAt(canonicalIndex).invokeWithMemoryEvent(
      memory,
      args,
      resultPointer: resultPointer,
      realloc: realloc,
    );
  }

  /// Invokes a memory-backed canonical operation and waits if needed.
  Future<Object?> invokeWithMemoryAsync(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    return _operationAt(canonicalIndex).invokeWithMemoryAsync(
      memory,
      args,
      resultPointer: resultPointer,
      realloc: realloc,
    );
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
typedef _WASIComponentInvokeFlat =
    List<Object?> Function(
      List<Object?> args,
      wasm.Memory? memory,
      WASIComponentCanonicalRealloc? realloc,
    );
typedef _WASIComponentInvokeFlatAsync =
    Future<List<Object?>> Function(
      List<Object?> args,
      wasm.Memory? memory,
      WASIComponentCanonicalRealloc? realloc,
    );
typedef _WASIComponentInvokeWithMemory =
    Object? Function(
      wasm.Memory memory,
      List<Object?> args,
      WASIComponentCanonicalRealloc? realloc,
      int? resultPointer,
    );
typedef _WASIComponentInvokeWithMemoryAsync =
    Future<Object?> Function(
      wasm.Memory memory,
      List<Object?> args,
      WASIComponentCanonicalRealloc? realloc,
      int? resultPointer,
    );

/// Bound canonical operation.
final class WASIComponentCanonicalOperation {
  const WASIComponentCanonicalOperation._({
    required this.kind,
    required _WASIComponentInvoke invoke,
    _WASIComponentInvokeAsync? invokeAsync,
    _WASIComponentInvokeFlat? invokeFlat,
    _WASIComponentInvokeFlatAsync? invokeFlatAsync,
    _WASIComponentInvokeWithMemory? invokeWithMemory,
    _WASIComponentInvokeWithMemory? invokeWithMemoryEvent,
    _WASIComponentInvokeWithMemoryAsync? invokeWithMemoryAsync,
  }) : _invoke = invoke,
       _invokeAsync = invokeAsync,
       _invokeFlat = invokeFlat,
       _invokeFlatAsync = invokeFlatAsync,
       _invokeWithMemory = invokeWithMemory,
       _invokeWithMemoryEvent = invokeWithMemoryEvent,
       _invokeWithMemoryAsync = invokeWithMemoryAsync;

  /// Canonical operation kind.
  final WasmComponentCanonicalKind kind;

  final _WASIComponentInvoke _invoke;
  final _WASIComponentInvokeAsync? _invokeAsync;
  final _WASIComponentInvokeFlat? _invokeFlat;
  final _WASIComponentInvokeFlatAsync? _invokeFlatAsync;
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

  /// Invokes this canonical operation through flat Canonical ABI scalars.
  List<Object?> invokeFlat(
    List<Object?> args, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final invokeFlat = _invokeFlat;
    if (invokeFlat == null) {
      throw UnsupportedError(
        'WASI component canonical ${kind.name} does not support flat invocation.',
      );
    }
    return invokeFlat(args, memory, realloc);
  }

  /// Invokes this canonical operation asynchronously through flat Canonical ABI
  /// scalars.
  Future<List<Object?>> invokeFlatAsync(
    List<Object?> args, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final invokeFlatAsync = _invokeFlatAsync;
    if (invokeFlatAsync != null) {
      return invokeFlatAsync(args, memory, realloc);
    }
    return Future<List<Object?>>.value(
      invokeFlat(args, memory: memory, realloc: realloc),
    );
  }

  /// Invokes this canonical operation with [memory].
  Object? invokeWithMemory(
    wasm.Memory memory,
    List<Object?> args, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final invokeWithMemory = _invokeWithMemory;
    if (invokeWithMemory != null) {
      return invokeWithMemory(memory, args, realloc, resultPointer);
    }
    if (resultPointer != null) {
      throw UnsupportedError(
        'WASI component canonical ${kind.name} does not support memory result pointers.',
      );
    }
    return invoke(args);
  }

  /// Starts this canonical operation's waitable event path with [memory].
  Object? invokeWithMemoryEvent(
    wasm.Memory memory,
    List<Object?> args, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final invokeWithMemoryEvent = _invokeWithMemoryEvent;
    if (invokeWithMemoryEvent != null) {
      return invokeWithMemoryEvent(memory, args, realloc, resultPointer);
    }
    return invokeWithMemory(
      memory,
      args,
      resultPointer: resultPointer,
      realloc: realloc,
    );
  }

  /// Invokes this canonical operation with [memory] and waits when supported.
  Future<Object?> invokeWithMemoryAsync(
    wasm.Memory memory,
    List<Object?> args, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final invokeWithMemoryAsync = _invokeWithMemoryAsync;
    if (invokeWithMemoryAsync != null) {
      return invokeWithMemoryAsync(memory, args, realloc, resultPointer);
    }
    return Future<Object?>.value(
      invokeWithMemory(
        memory,
        args,
        resultPointer: resultPointer,
        realloc: realloc,
      ),
    );
  }
}
