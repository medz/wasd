import '../../wasm/backend/native/interpreter/component.dart';
import 'async_host.dart';
import 'canonical_host.dart';
import 'resource_host.dart';
import 'resource_table.dart';

/// Internal component host adapter over shared WASI component primitives.
///
/// This adapter coordinates decoded component validation, resource type
/// binding, and canonical builtin binding. It is intentionally internal and
/// does not make public WASI Preview2/Preview3 support claims.
final class WASIComponentHost {
  /// Creates a component host over [canonicalHost] or a new shared host.
  WASIComponentHost({WASIComponentCanonicalHost? canonicalHost})
    : canonicalHost = canonicalHost ?? WASIComponentCanonicalHost();

  /// Shared canonical host used by this component adapter.
  final WASIComponentCanonicalHost canonicalHost;

  /// Shared resource table used by all component hosts.
  WASIComponentResourceTable get table => canonicalHost.table;

  /// Prepares a decoded component for host binding without side effects.
  WASIComponentHostBindingPlan prepareComponent(
    WasmComponent component, {
    bool validate = true,
  }) {
    final canonicalPlan = canonicalHost.prepareComponent(
      component,
      validate: validate,
    );
    final resourceBindings = canonicalPlan.validationErrors.isEmpty
        ? canonicalHost.resourceHost.componentResourceBindings(component)
        : const <WASIComponentResourceBinding>[];
    final asyncValueBindings = canonicalPlan.validationErrors.isEmpty
        ? canonicalHost.asyncHost.componentAsyncValueBindings(component)
        : const <WASIComponentAsyncValueBinding>[];
    final bindingErrors = canonicalPlan.validationErrors.isEmpty
        ? _componentHostBindingErrors(
            canonicalPlan.canonicalDefinitions,
            asyncValueBindings,
          )
        : const <WASIComponentHostBindingError>[];
    return WASIComponentHostBindingPlan._(
      host: this,
      canonicalPlan: canonicalPlan,
      resourceBindings: resourceBindings,
      asyncValueBindings: asyncValueBindings,
      bindingErrors: bindingErrors,
    );
  }

  /// Prepares and binds [component].
  WASIComponentHostBinding bindComponent(
    WasmComponent component, {
    bool validate = true,
    String Function(WASIComponentResourceBinding binding)? resourceName,
    void Function(WASIComponentResourceBinding binding, Object resource)?
    onResourceDrop,
    String Function(WASIComponentAsyncValueBinding binding)? asyncValueName,
    int? Function(WASIComponentAsyncValueBinding binding)?
    maxBufferedElementsForStream,
    void Function(WASIComponentAsyncValueBinding binding)? onAsyncValueDrop,
  }) {
    return prepareComponent(component, validate: validate).bind(
      resourceName: resourceName,
      onResourceDrop: onResourceDrop,
      asyncValueName: asyncValueName,
      maxBufferedElementsForStream: maxBufferedElementsForStream,
      onAsyncValueDrop: onAsyncValueDrop,
    );
  }
}

/// Prepared component host binding report.
final class WASIComponentHostBindingPlan {
  const WASIComponentHostBindingPlan._({
    required WASIComponentHost host,
    required this.canonicalPlan,
    required this.resourceBindings,
    required this.asyncValueBindings,
    required this.bindingErrors,
  }) : _host = host;

  final WASIComponentHost _host;

  /// Prepared canonical binding plan for the same component.
  final WASIComponentCanonicalBindingPlan canonicalPlan;

  /// Component resource bindings captured before host binding.
  final List<WASIComponentResourceBinding> resourceBindings;

  /// Component async stream/future bindings captured before host binding.
  final List<WASIComponentAsyncValueBinding> asyncValueBindings;

  /// Host-specific binding gaps that must be wired before binding.
  final List<WASIComponentHostBindingError> bindingErrors;

  /// Component validation errors that must be fixed before binding.
  List<WasmComponentValidationError> get validationErrors =>
      canonicalPlan.validationErrors;

  /// Unsupported canonical definitions that this host cannot bind.
  List<WASIComponentCanonicalHostUnsupportedDefinition>
  get unsupportedDefinitions => canonicalPlan.unsupportedDefinitions;

  /// Whether [bind] can build a component host binding without throwing.
  bool get canBind => canonicalPlan.canBind && bindingErrors.isEmpty;

  /// Defines component resources and binds the canonical builtin program.
  WASIComponentHostBinding bind({
    String Function(WASIComponentResourceBinding binding)? resourceName,
    void Function(WASIComponentResourceBinding binding, Object resource)?
    onResourceDrop,
    String Function(WASIComponentAsyncValueBinding binding)? asyncValueName,
    int? Function(WASIComponentAsyncValueBinding binding)?
    maxBufferedElementsForStream,
    void Function(WASIComponentAsyncValueBinding binding)? onAsyncValueDrop,
  }) {
    if (validationErrors.isNotEmpty) {
      throw WASIComponentCanonicalHostValidationException(validationErrors);
    }
    if (unsupportedDefinitions.isNotEmpty) {
      throw WASIComponentCanonicalHostUnsupportedException(
        unsupportedDefinitions,
      );
    }
    if (bindingErrors.isNotEmpty) {
      throw WASIComponentHostBindingException(bindingErrors);
    }
    _host.canonicalHost.resourceHost.checkResourceBindingsAvailable(
      resourceBindings,
    );
    _host.canonicalHost.asyncHost.checkAsyncValueBindingsAvailable(
      asyncValueBindings,
    );
    final resourceTypes = _host.canonicalHost.resourceHost
        .defineResourceBindings<Object>(
          resourceBindings,
          nameForBinding: resourceName,
          onDrop: onResourceDrop,
        );
    _host.canonicalHost.asyncHost.defineAsyncValueBindings<Object?>(
      asyncValueBindings,
      nameForBinding: asyncValueName,
      maxBufferedElementsForStream: maxBufferedElementsForStream,
      onDrop: onAsyncValueDrop,
    );
    return WASIComponentHostBinding._(
      host: _host,
      resourceTypes: resourceTypes,
      asyncValueBindings: asyncValueBindings,
      program: canonicalPlan.bind(),
    );
  }
}

/// A component host binding gap found before mutating host state.
final class WASIComponentHostBindingError {
  /// Creates a component host binding error.
  const WASIComponentHostBindingError({
    required this.canonicalIndex,
    required this.definition,
    required this.reason,
  });

  /// Canonical definition index in the decoded component.
  final int canonicalIndex;

  /// Canonical definition that this component host cannot currently wire.
  final WasmComponentCanonicalDefinition definition;

  /// Why this component host cannot bind [definition].
  final String reason;

  /// Canonical kind that cannot be bound.
  WasmComponentCanonicalKind get kind => definition.kind;

  @override
  String toString() {
    return 'canonical[$canonicalIndex].${definition.kind.name}: $reason';
  }
}

/// Thrown when the component host lacks required binding state.
final class WASIComponentHostBindingException implements Exception {
  /// Creates an exception from component host binding [errors].
  WASIComponentHostBindingException(
    Iterable<WASIComponentHostBindingError> errors,
  ) : errors = List<WASIComponentHostBindingError>.unmodifiable(errors);

  /// Binding errors that blocked host mutation.
  final List<WASIComponentHostBindingError> errors;

  @override
  String toString() {
    final buffer = StringBuffer('WASI component host cannot bind component');
    for (final error in errors) {
      buffer
        ..write('\n')
        ..write(error);
    }
    return buffer.toString();
  }
}

/// Bound component host state.
final class WASIComponentHostBinding {
  const WASIComponentHostBinding._({
    required this.host,
    required this.resourceTypes,
    required this.asyncValueBindings,
    required this.program,
  });

  /// Component host that owns this binding.
  final WASIComponentHost host;

  /// Resource types defined for this component binding.
  final List<WASIComponentResourceType<Object>> resourceTypes;

  /// Async value bindings defined for this component binding.
  final List<WASIComponentAsyncValueBinding> asyncValueBindings;

  /// Canonical-indexed builtin program for this component.
  final WASIComponentCanonicalProgram program;
}

List<WASIComponentHostBindingError> _componentHostBindingErrors(
  List<WasmComponentCanonicalDefinition> definitions,
  List<WASIComponentAsyncValueBinding> asyncValueBindings,
) {
  final errors = <WASIComponentHostBindingError>[];
  final asyncBindingsByTypeIndex = {
    for (final binding in asyncValueBindings)
      binding.componentTypeIndex: binding,
  };
  for (var index = 0; index < definitions.length; index++) {
    final definition = definitions[index];
    if (_componentHostNeedsAsyncValueBinding(definition.kind)) {
      final typeIndex = definition.typeIndex;
      final binding = typeIndex == null
          ? null
          : asyncBindingsByTypeIndex[typeIndex];
      if (binding == null) {
        errors.add(
          WASIComponentHostBindingError(
            canonicalIndex: index,
            definition: definition,
            reason:
                'component host cannot derive a supported stream/future async value binding',
          ),
        );
        continue;
      }
      if (_componentHostNeedsAsyncMemoryLayout(definition.kind) &&
          !_componentHostSupportsAsyncMemoryCopy(definition.kind, binding)) {
        errors.add(
          WASIComponentHostBindingError(
            canonicalIndex: index,
            definition: definition,
            reason:
                'component host cannot derive a supported stream/future memory representation',
          ),
        );
      }
    }
  }
  return List<WASIComponentHostBindingError>.unmodifiable(errors);
}

bool _componentHostSupportsAsyncMemoryCopy(
  WasmComponentCanonicalKind kind,
  WASIComponentAsyncValueBinding binding,
) {
  if (binding.isUnit || binding.fixedWidthMemoryLayout != null) {
    return true;
  }
  final isPrimitiveStringCopy =
      (kind == WasmComponentCanonicalKind.streamRead ||
          kind == WasmComponentCanonicalKind.streamWrite ||
          kind == WasmComponentCanonicalKind.futureRead ||
          kind == WasmComponentCanonicalKind.futureWrite) &&
      binding.primitive == WasmComponentPrimitiveValueType.string;
  return isPrimitiveStringCopy;
}

bool _componentHostNeedsAsyncValueBinding(WasmComponentCanonicalKind kind) {
  switch (kind) {
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
      return true;
    case WasmComponentCanonicalKind.lift:
    case WasmComponentCanonicalKind.lower:
    case WasmComponentCanonicalKind.resourceNew:
    case WasmComponentCanonicalKind.resourceDrop:
    case WasmComponentCanonicalKind.resourceRep:
    case WasmComponentCanonicalKind.backpressureSet:
    case WasmComponentCanonicalKind.backpressureInc:
    case WasmComponentCanonicalKind.backpressureDec:
    case WasmComponentCanonicalKind.taskReturn:
    case WasmComponentCanonicalKind.taskCancel:
    case WasmComponentCanonicalKind.contextGet:
    case WasmComponentCanonicalKind.contextSet:
    case WasmComponentCanonicalKind.threadYield:
    case WasmComponentCanonicalKind.subtaskCancel:
    case WasmComponentCanonicalKind.subtaskDrop:
    case WasmComponentCanonicalKind.errorContextNew:
    case WasmComponentCanonicalKind.errorContextDebugMessage:
    case WasmComponentCanonicalKind.errorContextDrop:
    case WasmComponentCanonicalKind.waitableSetNew:
    case WasmComponentCanonicalKind.waitableSetWait:
    case WasmComponentCanonicalKind.waitableSetPoll:
    case WasmComponentCanonicalKind.waitableSetDrop:
    case WasmComponentCanonicalKind.waitableJoin:
    case WasmComponentCanonicalKind.threadIndex:
    case WasmComponentCanonicalKind.threadNewIndirect:
    case WasmComponentCanonicalKind.threadSwitchTo:
    case WasmComponentCanonicalKind.threadSuspend:
    case WasmComponentCanonicalKind.threadResumeLater:
    case WasmComponentCanonicalKind.threadYieldTo:
    case WasmComponentCanonicalKind.threadSpawnRef:
    case WasmComponentCanonicalKind.threadSpawnIndirect:
    case WasmComponentCanonicalKind.threadAvailableParallelism:
      return false;
  }
}

bool _componentHostNeedsAsyncMemoryLayout(WasmComponentCanonicalKind kind) {
  switch (kind) {
    case WasmComponentCanonicalKind.streamRead:
    case WasmComponentCanonicalKind.streamWrite:
    case WasmComponentCanonicalKind.futureRead:
    case WasmComponentCanonicalKind.futureWrite:
      return true;
    case WasmComponentCanonicalKind.lift:
    case WasmComponentCanonicalKind.lower:
    case WasmComponentCanonicalKind.resourceNew:
    case WasmComponentCanonicalKind.resourceDrop:
    case WasmComponentCanonicalKind.resourceRep:
    case WasmComponentCanonicalKind.backpressureSet:
    case WasmComponentCanonicalKind.backpressureInc:
    case WasmComponentCanonicalKind.backpressureDec:
    case WasmComponentCanonicalKind.taskReturn:
    case WasmComponentCanonicalKind.taskCancel:
    case WasmComponentCanonicalKind.contextGet:
    case WasmComponentCanonicalKind.contextSet:
    case WasmComponentCanonicalKind.threadYield:
    case WasmComponentCanonicalKind.subtaskCancel:
    case WasmComponentCanonicalKind.subtaskDrop:
    case WasmComponentCanonicalKind.streamNew:
    case WasmComponentCanonicalKind.streamCancelRead:
    case WasmComponentCanonicalKind.streamCancelWrite:
    case WasmComponentCanonicalKind.streamDropReadable:
    case WasmComponentCanonicalKind.streamDropWritable:
    case WasmComponentCanonicalKind.futureNew:
    case WasmComponentCanonicalKind.futureCancelRead:
    case WasmComponentCanonicalKind.futureCancelWrite:
    case WasmComponentCanonicalKind.futureDropReadable:
    case WasmComponentCanonicalKind.futureDropWritable:
    case WasmComponentCanonicalKind.errorContextNew:
    case WasmComponentCanonicalKind.errorContextDebugMessage:
    case WasmComponentCanonicalKind.errorContextDrop:
    case WasmComponentCanonicalKind.waitableSetNew:
    case WasmComponentCanonicalKind.waitableSetWait:
    case WasmComponentCanonicalKind.waitableSetPoll:
    case WasmComponentCanonicalKind.waitableSetDrop:
    case WasmComponentCanonicalKind.waitableJoin:
    case WasmComponentCanonicalKind.threadIndex:
    case WasmComponentCanonicalKind.threadNewIndirect:
    case WasmComponentCanonicalKind.threadSwitchTo:
    case WasmComponentCanonicalKind.threadSuspend:
    case WasmComponentCanonicalKind.threadResumeLater:
    case WasmComponentCanonicalKind.threadYieldTo:
    case WasmComponentCanonicalKind.threadSpawnRef:
    case WasmComponentCanonicalKind.threadSpawnIndirect:
    case WasmComponentCanonicalKind.threadAvailableParallelism:
      return false;
  }
}
