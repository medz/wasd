import 'dart:async';
import 'dart:collection';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'async_values.dart';
import 'backpressure.dart';
import 'integer_bounds.dart';
import 'resource_table.dart';
import 'string_memory.dart';
import 'unicode_scalar.dart';
import 'value_memory.dart';
import 'waitable_set.dart';

/// Binds decoded canonical stream/future definitions to executable primitives.
///
/// This host layer binds validated `stream.*` and `future.*` definitions to
/// typed Dart endpoint primitives, including primitive, owned-resource-handle,
/// composite, and dynamic string/list stream/future memory copies.
final class WASIComponentAsyncHost {
  /// Creates an async host backed by [table] or a new resource table.
  WASIComponentAsyncHost({
    WASIComponentResourceTable? table,
    WASIComponentBackpressure? backpressure,
  }) : table = table ?? WASIComponentResourceTable(),
       backpressure = backpressure ?? WASIComponentBackpressure();

  /// Resource table used for handle-backed stream/future endpoints.
  final WASIComponentResourceTable table;

  /// Shared Component Model async backpressure state.
  final WASIComponentBackpressure backpressure;
  final _WASIComponentEndpointWaitables _endpointWaitables =
      _WASIComponentEndpointWaitables();

  final Map<int, _RegisteredAsyncValueType> _valueTypes =
      <int, _RegisteredAsyncValueType>{};

  /// Defines a component `stream<T>` type for [componentTypeIndex].
  void defineStreamType<T>(
    int componentTypeIndex,
    String name, {
    int? maxBufferedElements,
    void Function()? onDrop,
    void Function(T value)? onDiscard,
  }) {
    _defineType<T>(
      componentTypeIndex,
      name,
      kind: _WASIComponentAsyncValueKind.stream,
      valueValidator: _WASIComponentAsyncValueValidator.unconstrained,
      maxBufferedElements: maxBufferedElements,
      onDrop: onDrop,
      onDiscard: onDiscard,
    );
  }

  /// Defines a component `stream<T>` type from a decoded component type.
  void defineStreamTypeFromComponent<T>(
    WasmComponent component,
    int componentTypeIndex,
    String name, {
    int? maxBufferedElements,
    void Function()? onDrop,
    void Function(T value)? onDiscard,
  }) {
    final valueValidator = _expectDecodedAsyncType(
      component,
      componentTypeIndex,
      WasmComponentDefinedValueTypeKind.stream,
    );
    _defineType<T>(
      componentTypeIndex,
      name,
      kind: _WASIComponentAsyncValueKind.stream,
      valueValidator: valueValidator,
      maxBufferedElements: maxBufferedElements,
      onDrop: onDrop,
      onDiscard: onDiscard,
    );
  }

  /// Resolves a handle-backed async endpoint to its waitable state.
  WASIComponentWaitable? waitableForHandle(int handle) {
    for (final valueType in _valueTypes.values) {
      final waitable = valueType.waitableForHandle(handle);
      if (waitable != null) {
        return waitable;
      }
    }
    return null;
  }

  /// Lowers a host stream or future readable endpoint to a canonical handle.
  int lowerReadableEndpoint(int componentTypeIndex, Object value) {
    final valueType = _valueTypes[componentTypeIndex];
    if (valueType == null) {
      throw StateError(
        'Unknown WASI component async type index: $componentTypeIndex.',
      );
    }
    return valueType.lowerReadableEndpoint(value);
  }

  /// Lifts a canonical stream or future handle by transferring its endpoint
  /// out of the component resource table.
  Object liftReadableEndpoint(int componentTypeIndex, int handle) {
    final valueType = _valueTypes[componentTypeIndex];
    if (valueType == null) {
      throw StateError(
        'Unknown WASI component async type index: $componentTypeIndex.',
      );
    }
    return valueType.liftReadableEndpoint(handle);
  }

  /// Defines a component `future<T>` type for [componentTypeIndex].
  void defineFutureType<T>(
    int componentTypeIndex,
    String name, {
    void Function()? onDrop,
    void Function(T value)? onDiscard,
  }) {
    _defineType<T>(
      componentTypeIndex,
      name,
      kind: _WASIComponentAsyncValueKind.future,
      valueValidator: _WASIComponentAsyncValueValidator.unconstrained,
      maxBufferedElements: null,
      onDrop: onDrop,
      onDiscard: onDiscard,
    );
  }

  /// Defines a component `future<T>` type from a decoded component type.
  void defineFutureTypeFromComponent<T>(
    WasmComponent component,
    int componentTypeIndex,
    String name, {
    void Function()? onDrop,
    void Function(T value)? onDiscard,
  }) {
    final valueValidator = _expectDecodedAsyncType(
      component,
      componentTypeIndex,
      WasmComponentDefinedValueTypeKind.future,
    );
    _defineType<T>(
      componentTypeIndex,
      name,
      kind: _WASIComponentAsyncValueKind.future,
      valueValidator: valueValidator,
      maxBufferedElements: null,
      onDrop: onDrop,
      onDiscard: onDiscard,
    );
  }

  /// Returns supported component stream/future bindings in type-index order.
  List<WASIComponentAsyncValueBinding> componentAsyncValueBindings(
    WasmComponent component,
  ) {
    final bindings = <WASIComponentAsyncValueBinding>[];
    final definitions = component.componentTypeIndexDefinitions;
    for (
      var componentTypeIndex = 0;
      componentTypeIndex < definitions.length;
      componentTypeIndex++
    ) {
      final definition = definitions[componentTypeIndex];
      final definedValue = definition.definedValue;
      if (definition.kind != WasmComponentTypeKind.definedValue ||
          definedValue == null) {
        continue;
      }
      final kind = switch (definedValue.kind) {
        WasmComponentDefinedValueTypeKind.stream =>
          WASIComponentAsyncValueBindingKind.stream,
        WasmComponentDefinedValueTypeKind.future =>
          WASIComponentAsyncValueBindingKind.future,
        _ => null,
      };
      if (kind == null) {
        continue;
      }
      final validator =
          _supportedAsyncValueValidatorForElementType(
            definedValue.elementType,
            definitions,
          ) ??
          _supportedAsyncValueValidatorFromFunctionContexts(
            component,
            componentTypeIndex,
          );
      if (validator == null) {
        continue;
      }
      bindings.add(
        WASIComponentAsyncValueBinding._(
          componentTypeIndex: componentTypeIndex,
          name: '${kind.name}[$componentTypeIndex]',
          kind: kind,
          valueValidator: validator,
        ),
      );
    }
    for (final scopedType in _componentScopedAsyncValueTypes(component)) {
      final validator = _supportedAsyncValueValidatorForElementType(
        scopedType.definedValue.elementType,
        scopedType.referenceDefinitions,
      );
      if (validator == null) {
        continue;
      }
      bindings.add(
        WASIComponentAsyncValueBinding._(
          componentTypeIndex: scopedType.componentTypeIndex,
          name: '${scopedType.kind.name}[${scopedType.componentTypeIndex}]',
          kind: scopedType.kind,
          valueValidator: validator,
        ),
      );
    }
    return List<WASIComponentAsyncValueBinding>.unmodifiable(bindings);
  }

  /// Defines async value types from a prepared component async binding list.
  void defineAsyncValueBindings<T>(
    Iterable<WASIComponentAsyncValueBinding> bindings, {
    String Function(WASIComponentAsyncValueBinding binding)? nameForBinding,
    int? Function(WASIComponentAsyncValueBinding binding)?
    maxBufferedElementsForStream,
    void Function(WASIComponentAsyncValueBinding binding)? onDrop,
    void Function(WASIComponentAsyncValueBinding binding, T value)? onDiscard,
  }) {
    final bindingList = bindings is List<WASIComponentAsyncValueBinding>
        ? bindings
        : bindings.toList(growable: false);
    checkAsyncValueBindingsAvailable(bindingList);
    for (final binding in bindingList) {
      _defineType<T>(
        binding.componentTypeIndex,
        nameForBinding?.call(binding) ?? binding.name,
        kind: switch (binding.kind) {
          WASIComponentAsyncValueBindingKind.stream =>
            _WASIComponentAsyncValueKind.stream,
          WASIComponentAsyncValueBindingKind.future =>
            _WASIComponentAsyncValueKind.future,
        },
        valueValidator: binding._valueValidator,
        maxBufferedElements:
            binding.kind == WASIComponentAsyncValueBindingKind.stream
            ? maxBufferedElementsForStream?.call(binding)
            : null,
        onDrop: onDrop == null ? null : () => onDrop(binding),
        onDiscard: onDiscard == null
            ? null
            : (value) => onDiscard(binding, value),
      );
    }
  }

  /// Throws if [bindings] cannot be defined without mutating this host.
  void checkAsyncValueBindingsAvailable(
    Iterable<WASIComponentAsyncValueBinding> bindings,
  ) {
    final seen = <int>{};
    for (final binding in bindings) {
      final componentTypeIndex = binding.componentTypeIndex;
      if (componentTypeIndex < 0) {
        throw StateError(
          'WASI component async type index $componentTypeIndex is invalid.',
        );
      }
      if (!seen.add(componentTypeIndex)) {
        throw StateError(
          'WASI component async type index $componentTypeIndex is bound more than once.',
        );
      }
      if (_valueTypes.containsKey(componentTypeIndex)) {
        throw StateError(
          'WASI component async type index $componentTypeIndex is already bound.',
        );
      }
    }
  }

  void _defineType<T>(
    int componentTypeIndex,
    String name, {
    required _WASIComponentAsyncValueKind kind,
    required _WASIComponentAsyncValueValidator valueValidator,
    int? maxBufferedElements,
    void Function()? onDrop,
    void Function(T value)? onDiscard,
  }) {
    if (_valueTypes.containsKey(componentTypeIndex)) {
      throw StateError(
        'WASI component async type index $componentTypeIndex is already bound.',
      );
    }
    _valueTypes[componentTypeIndex] = _RegisteredAsyncValueType<T>(
      table: table,
      name: name,
      kind: kind,
      valueValidator: valueValidator,
      maxBufferedElements: maxBufferedElements,
      onDrop: onDrop,
      onDiscard: onDiscard,
      endpointWaitables: _endpointWaitables,
    );
  }

  /// Binds a decoded canonical stream/future definition.
  WASIComponentCanonicalAsyncOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    if (_canonicalDefinitionUsesBackpressure(definition.kind)) {
      if (definition.typeIndex != null) {
        throw StateError(
          'Wasm component canonical ${definition.kind.name} does not use a type index.',
        );
      }
      return WASIComponentCanonicalAsyncOperation._backpressure(
        kind: definition.kind,
        backpressure: backpressure,
      );
    }

    final expectedKind = _asyncValueKindForCanonicalKind(definition.kind);
    if (expectedKind == null) {
      throw UnsupportedError(
        'Wasm component canonical ${definition.kind.name} is not a stream, future, or backpressure operation.',
      );
    }

    final typeIndex = definition.typeIndex;
    final valueType = typeIndex == null ? null : _valueTypes[typeIndex];
    if (typeIndex == null || valueType == null) {
      throw StateError('Unknown WASI component async type index: $typeIndex.');
    }
    if (valueType.kind != expectedKind) {
      throw StateError(
        'WASI component async type index $typeIndex is ${valueType.kind.name}, '
        'but canonical ${definition.kind.name} requires ${expectedKind.name}.',
      );
    }

    return WASIComponentCanonicalAsyncOperation._(
      kind: definition.kind,
      componentTypeIndex: typeIndex,
      isAsync: definition.isAsync,
      stringEncoding: WASIComponentCanonicalStringEncoding.fromCanonicalOptions(
        definition.options,
      ),
      valueType: valueType,
    );
  }

  /// Binds all decoded canonical stream/future definitions in [component].
  WASIComponentCanonicalAsyncProgram bindCanonicalDefinitions(
    WasmComponent component,
  ) {
    return WASIComponentCanonicalAsyncProgram(
      operations: List<WASIComponentCanonicalAsyncOperation>.unmodifiable([
        for (final definition in component.canonicalDefinitions)
          bindCanonicalDefinition(definition),
      ]),
    );
  }

  /// Binds all decoded canonical stream/future definitions to integer handles.
  WASIComponentCanonicalAsyncHandleProgram bindCanonicalDefinitionsToHandles(
    WasmComponent component,
  ) {
    return WASIComponentCanonicalAsyncHandleProgram(
      operations: List<WASIComponentCanonicalAsyncOperation>.unmodifiable([
        for (final definition in component.canonicalDefinitions)
          bindCanonicalDefinition(definition),
      ]),
    );
  }
}

/// Resolves a stream/future type from a function-local type scope to the
/// matching component type index used by canonical async builtins.
int? wasiComponentAsyncValueTypeIndex(
  WasmComponent component,
  int sourceTypeIndex,
  List<WasmComponentTypeDefinition> sourceDefinitions, {
  WasmComponentTypeScope? sourceTypeScope,
}) {
  if (sourceTypeIndex < 0 || sourceTypeIndex >= sourceDefinitions.length) {
    return null;
  }
  final sourceContext = sourceTypeScope?.definitionContextAt(sourceTypeIndex);
  final source =
      sourceContext?.definition ?? sourceDefinitions[sourceTypeIndex];
  final sourceValue = source.definedValue;
  if (source.kind != WasmComponentTypeKind.definedValue ||
      sourceValue == null ||
      (sourceValue.kind != WasmComponentDefinedValueTypeKind.stream &&
          sourceValue.kind != WasmComponentDefinedValueTypeKind.future)) {
    return null;
  }
  final referenceDefinitions =
      sourceContext?.typeScope.definitions ?? sourceDefinitions;
  final topLevelIndex = _topLevelAsyncValueTypeIndex(
    component,
    source,
    sourceValue,
    referenceDefinitions,
  );
  if (topLevelIndex != null) {
    return topLevelIndex;
  }
  for (final scopedType in _componentScopedAsyncValueTypes(component)) {
    if (identical(scopedType.definition, source)) {
      return scopedType.componentTypeIndex;
    }
  }
  return null;
}

int? _topLevelAsyncValueTypeIndex(
  WasmComponent component,
  WasmComponentTypeDefinition source,
  WasmComponentDefinedValueType sourceValue,
  List<WasmComponentTypeDefinition> sourceDefinitions,
) {
  final componentDefinitions = component.componentTypeIndexDefinitions;
  final identityMatches = <int>[];
  for (var index = 0; index < componentDefinitions.length; index++) {
    if (identical(source, componentDefinitions[index])) {
      identityMatches.add(index);
    }
  }
  if (identityMatches.length == 1) {
    return identityMatches.single;
  }
  final matches = <int>[];
  for (var index = 0; index < componentDefinitions.length; index++) {
    final candidate = componentDefinitions[index];
    final candidateValue = candidate.definedValue;
    if (candidate.kind == WasmComponentTypeKind.definedValue &&
        candidateValue != null &&
        candidateValue.kind == sourceValue.kind &&
        _asyncBindingValueTypesEquivalent(
          sourceValue.elementType,
          sourceDefinitions,
          candidateValue.elementType,
          componentDefinitions,
          <(WasmComponentTypeDefinition, WasmComponentTypeDefinition)>{},
        )) {
      matches.add(index);
    }
  }
  return matches.length == 1 ? matches.single : null;
}

final Expando<List<_WASIComponentScopedAsyncValueType>>
_scopedAsyncValueTypesByComponent =
    Expando<List<_WASIComponentScopedAsyncValueType>>();

List<_WASIComponentScopedAsyncValueType> _componentScopedAsyncValueTypes(
  WasmComponent component,
) {
  final cached = _scopedAsyncValueTypesByComponent[component];
  if (cached != null) {
    return cached;
  }
  final componentDefinitions = component.componentTypeIndexDefinitions;
  final knownDefinitions = HashSet<WasmComponentTypeDefinition>.identity()
    ..addAll(componentDefinitions);
  final scopedTypes = <_WASIComponentScopedAsyncValueType>[];
  for (final context in component.componentFunctionIndexTypeContexts) {
    if (context == null) {
      continue;
    }
    final definitions = context.typeDefinitions;
    final typeScope = context.typeScope;
    for (var index = 0; index < definitions.length; index++) {
      final definitionContext = typeScope?.definitionContextAt(index);
      final definition = definitionContext?.definition ?? definitions[index];
      if (!knownDefinitions.add(definition)) {
        continue;
      }
      final value = definition.definedValue;
      final kind = switch (value?.kind) {
        WasmComponentDefinedValueTypeKind.stream =>
          WASIComponentAsyncValueBindingKind.stream,
        WasmComponentDefinedValueTypeKind.future =>
          WASIComponentAsyncValueBindingKind.future,
        _ => null,
      };
      if (value == null || kind == null) {
        continue;
      }
      final referenceDefinitions =
          definitionContext?.typeScope.definitions ?? definitions;
      if (_topLevelAsyncValueTypeIndex(
            component,
            definition,
            value,
            referenceDefinitions,
          ) !=
          null) {
        continue;
      }
      scopedTypes.add(
        _WASIComponentScopedAsyncValueType(
          componentTypeIndex: componentDefinitions.length + scopedTypes.length,
          definition: definition,
          definedValue: value,
          referenceDefinitions: referenceDefinitions,
          kind: kind,
        ),
      );
    }
  }
  final result = List<_WASIComponentScopedAsyncValueType>.unmodifiable(
    scopedTypes,
  );
  _scopedAsyncValueTypesByComponent[component] = result;
  return result;
}

final class _WASIComponentScopedAsyncValueType {
  const _WASIComponentScopedAsyncValueType({
    required this.componentTypeIndex,
    required this.definition,
    required this.definedValue,
    required this.referenceDefinitions,
    required this.kind,
  });

  final int componentTypeIndex;
  final WasmComponentTypeDefinition definition;
  final WasmComponentDefinedValueType definedValue;
  final List<WasmComponentTypeDefinition> referenceDefinitions;
  final WASIComponentAsyncValueBindingKind kind;
}

_WASIComponentAsyncValueValidator?
_supportedAsyncValueValidatorFromFunctionContexts(
  WasmComponent component,
  int componentTypeIndex,
) {
  final visitedContexts =
      <(List<WasmComponentTypeDefinition>, WasmComponentTypeScope?)>{};
  for (final context in component.componentFunctionIndexTypeContexts) {
    final definitions = context?.typeDefinitions;
    final typeScope = context?.typeScope;
    if (definitions == null || !visitedContexts.add((definitions, typeScope))) {
      continue;
    }
    for (var index = 0; index < definitions.length; index++) {
      if (wasiComponentAsyncValueTypeIndex(
            component,
            index,
            definitions,
            sourceTypeScope: typeScope,
          ) !=
          componentTypeIndex) {
        continue;
      }
      final definitionContext = typeScope?.definitionContextAt(index);
      final value =
          (definitionContext?.definition ?? definitions[index]).definedValue;
      if (value == null) {
        continue;
      }
      final validator = _supportedAsyncValueValidatorForElementType(
        value.elementType,
        definitionContext?.typeScope.definitions ?? definitions,
      );
      if (validator != null) {
        return validator;
      }
    }
  }
  return null;
}

bool _asyncBindingValueTypesEquivalent(
  WasmComponentValueType? left,
  List<WasmComponentTypeDefinition> leftDefinitions,
  WasmComponentValueType? right,
  List<WasmComponentTypeDefinition> rightDefinitions,
  Set<(WasmComponentTypeDefinition, WasmComponentTypeDefinition)> visiting,
) {
  if (left == null || right == null) {
    return left == null && right == null;
  }
  if (left.kind != right.kind) {
    return false;
  }
  if (left.kind == WasmComponentValueTypeKind.primitive) {
    return left.primitive == right.primitive;
  }
  final leftIndex = left.typeIndex;
  final rightIndex = right.typeIndex;
  if (leftIndex == null ||
      leftIndex < 0 ||
      leftIndex >= leftDefinitions.length ||
      rightIndex == null ||
      rightIndex < 0 ||
      rightIndex >= rightDefinitions.length) {
    return false;
  }
  return _asyncBindingTypeDefinitionsEquivalent(
    leftDefinitions[leftIndex],
    leftDefinitions,
    rightDefinitions[rightIndex],
    rightDefinitions,
    visiting,
  );
}

bool _asyncBindingTypeDefinitionsEquivalent(
  WasmComponentTypeDefinition left,
  List<WasmComponentTypeDefinition> leftDefinitions,
  WasmComponentTypeDefinition right,
  List<WasmComponentTypeDefinition> rightDefinitions,
  Set<(WasmComponentTypeDefinition, WasmComponentTypeDefinition)> visiting,
) {
  if (identical(left, right)) {
    return true;
  }
  if (left.kind != right.kind ||
      left.kind != WasmComponentTypeKind.definedValue) {
    return false;
  }
  final pair = (left, right);
  if (!visiting.add(pair)) {
    return true;
  }
  final leftValue = left.definedValue;
  final rightValue = right.definedValue;
  final equivalent =
      leftValue != null &&
      rightValue != null &&
      _asyncBindingDefinedValuesEquivalent(
        leftValue,
        leftDefinitions,
        rightValue,
        rightDefinitions,
        visiting,
      );
  visiting.remove(pair);
  return equivalent;
}

bool _asyncBindingDefinedValuesEquivalent(
  WasmComponentDefinedValueType left,
  List<WasmComponentTypeDefinition> leftDefinitions,
  WasmComponentDefinedValueType right,
  List<WasmComponentTypeDefinition> rightDefinitions,
  Set<(WasmComponentTypeDefinition, WasmComponentTypeDefinition)> visiting,
) {
  if (left.kind != right.kind ||
      left.primitive != right.primitive ||
      left.fixedLength != right.fixedLength ||
      !_asyncBindingStringsEqual(left.labels, right.labels)) {
    return false;
  }
  bool valueTypesEquivalent(
    WasmComponentValueType? leftType,
    WasmComponentValueType? rightType,
  ) => _asyncBindingValueTypesEquivalent(
    leftType,
    leftDefinitions,
    rightType,
    rightDefinitions,
    visiting,
  );
  if (!valueTypesEquivalent(left.elementType, right.elementType) ||
      !valueTypesEquivalent(left.okType, right.okType) ||
      !valueTypesEquivalent(left.errorType, right.errorType)) {
    return false;
  }
  if (left.kind == WasmComponentDefinedValueTypeKind.own ||
      left.kind == WasmComponentDefinedValueTypeKind.borrow) {
    return _asyncBindingTypeIndexesEquivalent(
      left.typeIndex,
      leftDefinitions,
      right.typeIndex,
      rightDefinitions,
      visiting,
    );
  }
  if (left.types.length != right.types.length ||
      left.fields.length != right.fields.length ||
      left.cases.length != right.cases.length) {
    return false;
  }
  for (var index = 0; index < left.types.length; index++) {
    if (!valueTypesEquivalent(left.types[index], right.types[index])) {
      return false;
    }
  }
  for (var index = 0; index < left.fields.length; index++) {
    final leftField = left.fields[index];
    final rightField = right.fields[index];
    if (leftField.label != rightField.label ||
        !valueTypesEquivalent(leftField.type, rightField.type)) {
      return false;
    }
  }
  for (var index = 0; index < left.cases.length; index++) {
    final leftCase = left.cases[index];
    final rightCase = right.cases[index];
    if (leftCase.label != rightCase.label ||
        !valueTypesEquivalent(leftCase.type, rightCase.type)) {
      return false;
    }
  }
  return true;
}

bool _asyncBindingTypeIndexesEquivalent(
  int? leftIndex,
  List<WasmComponentTypeDefinition> leftDefinitions,
  int? rightIndex,
  List<WasmComponentTypeDefinition> rightDefinitions,
  Set<(WasmComponentTypeDefinition, WasmComponentTypeDefinition)> visiting,
) {
  if (leftIndex == null ||
      leftIndex < 0 ||
      leftIndex >= leftDefinitions.length ||
      rightIndex == null ||
      rightIndex < 0 ||
      rightIndex >= rightDefinitions.length) {
    return false;
  }
  return _asyncBindingTypeDefinitionsEquivalent(
    leftDefinitions[leftIndex],
    leftDefinitions,
    rightDefinitions[rightIndex],
    rightDefinitions,
    visiting,
  );
}

bool _asyncBindingStringsEqual(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

/// Supported async value binding kind.
enum WASIComponentAsyncValueBindingKind {
  /// Component `stream<T>`.
  stream,

  /// Component `future<T>`.
  future,
}

/// A decoded component stream/future type that can be bound to the async host.
final class WASIComponentAsyncValueBinding {
  WASIComponentAsyncValueBinding._({
    required this.componentTypeIndex,
    required this.name,
    required this.kind,
    required _WASIComponentAsyncValueValidator valueValidator,
  }) : _valueValidator = valueValidator,
       memoryLayout = _memoryLayoutFor(valueValidator);

  final _WASIComponentAsyncValueValidator _valueValidator;

  /// Component type index of the stream/future value.
  final int componentTypeIndex;

  /// Stable debug name for this async value type.
  final String name;

  /// Stream/future binding kind.
  final WASIComponentAsyncValueBindingKind kind;

  /// Whether this stream/future carries unit values.
  bool get isUnit => _valueValidator.kind == _WASIComponentAsyncValueShape.unit;

  /// Primitive element type when this binding carries primitive values.
  WasmComponentPrimitiveValueType? get primitive =>
      _valueValidator.primitive ?? _valueValidator.memoryCodec?.primitive;

  /// Canonical ABI memory-copy layout for this payload.
  ///
  /// Returns `null` for unit payloads and unsupported shapes such as borrows,
  /// nested streams/futures, and error contexts.
  final WASIComponentAsyncValueMemoryLayout? memoryLayout;
}

/// Canonical ABI memory-copy layout for an async value payload.
final class WASIComponentAsyncValueMemoryLayout {
  const WASIComponentAsyncValueMemoryLayout._({
    required this.byteLength,
    required this.alignment,
  });

  /// Number of guest-memory bytes per stream/future element record.
  final int byteLength;

  /// Required guest-memory alignment for the element record pointer.
  final int alignment;
}

/// Executable stream/future-only canonical program for a decoded component.
final class WASIComponentCanonicalAsyncProgram {
  /// Creates a canonical async program from ordered [operations].
  const WASIComponentCanonicalAsyncProgram({required this.operations});

  /// Stream/future operations in component canonical definition order.
  final List<WASIComponentCanonicalAsyncOperation> operations;

  /// Invokes the canonical async operation at [canonicalIndex].
  Object? invoke(int canonicalIndex, List<Object?> args) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamNew:
        _expectArity(canonicalIndex, args, 0);
        return operation.streamNew();
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 2);
        return operation.streamRead(
          args[0],
          _expectNonNegativeInt(canonicalIndex, args[1], 'maxElements'),
        );
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 2);
        return operation.streamWrite(args[0], args[1]);
      case WasmComponentCanonicalKind.streamCancelRead:
        _expectArity(canonicalIndex, args, 1);
        operation.streamCancelRead(args.single);
        return null;
      case WasmComponentCanonicalKind.streamCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        operation.streamCancelWrite(args.single);
        return null;
      case WasmComponentCanonicalKind.streamDropReadable:
        _expectArity(canonicalIndex, args, 1);
        operation.streamDropReadable(args.single);
        return null;
      case WasmComponentCanonicalKind.streamDropWritable:
        _expectArity(canonicalIndex, args, 1);
        operation.streamDropWritable(args.single);
        return null;
      case WasmComponentCanonicalKind.futureNew:
        _expectArity(canonicalIndex, args, 0);
        return operation.futureNew();
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureRead(args.single);
      case WasmComponentCanonicalKind.futureWrite:
        _expectArity(canonicalIndex, args, 2);
        return operation.futureWrite(args[0], args[1]);
      case WasmComponentCanonicalKind.futureCancelRead:
        _expectArity(canonicalIndex, args, 1);
        operation.futureCancelRead(args.single);
        return null;
      case WasmComponentCanonicalKind.futureCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        operation.futureCancelWrite(args.single);
        return null;
      case WasmComponentCanonicalKind.futureDropReadable:
        _expectArity(canonicalIndex, args, 1);
        operation.futureDropReadable(args.single);
        return null;
      case WasmComponentCanonicalKind.futureDropWritable:
        _expectArity(canonicalIndex, args, 1);
        operation.futureDropWritable(args.single);
        return null;
      case WasmComponentCanonicalKind.backpressureInc:
        _expectArity(canonicalIndex, args, 0);
        return operation.backpressureIncrement();
      case WasmComponentCanonicalKind.backpressureDec:
        _expectArity(canonicalIndex, args, 0);
        return operation.backpressureDecrement();
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the async program.',
        );
    }
  }

  /// Invokes a canonical async operation and waits for pending future reads.
  Future<Object?> invokeAsync(int canonicalIndex, List<Object?> args) async {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 2);
        return operation.streamReadWhenAvailable(
          args[0],
          _expectNonNegativeInt(canonicalIndex, args[1], 'maxElements'),
        );
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureReadWhenReady(args.single);
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 2);
        return operation.streamWriteWhenAvailable(args[0], args[1]);
      default:
        return invoke(canonicalIndex, args);
    }
  }
}

/// Pair of canonical readable and writable endpoint handles.
final class WASIComponentAsyncEndpointHandles {
  /// Creates an endpoint handle pair.
  WASIComponentAsyncEndpointHandles({
    required this.readable,
    required this.writable,
  }) {
    _checkU32Handle(readable, 'readable');
    _checkU32Handle(writable, 'writable');
  }

  /// Unpacks the canonical `i64` handle pair used by stream/future.new.
  factory WASIComponentAsyncEndpointHandles.unpack(int packed) {
    _checkI64Bits(packed, 'packed');
    final signedHigh = _floorDivideByU32Base(packed);
    final writable = signedHigh < 0 ? signedHigh + _u32Base : signedHigh;
    return WASIComponentAsyncEndpointHandles(
      readable: packed - signedHigh * _u32Base,
      writable: writable,
    );
  }

  /// Readable endpoint handle.
  final int readable;

  /// Writable endpoint handle.
  final int writable;

  /// Canonical signed `i64` with readable in low bits and writable in high bits.
  int get packed {
    final bits = readable + writable * _u32Base;
    return bits >= _i64SignBit ? bits - _i64SignBit - _i64SignBit : bits;
  }
}

const int _u32Mask = 0xffffffff;
const int _u32Base = 0x100000000;
const int _i64Min = -0x8000000000000000;
const int _i64SignBit = 0x8000000000000000;

/// Status returned by canonical async stream memory copy operations.
enum WASIComponentAsyncCopyStatus {
  /// The copy completed synchronously.
  completed(0),

  /// The stream endpoint was dropped.
  dropped(1),

  /// The stream endpoint was cancelled.
  cancelled(2);

  const WASIComponentAsyncCopyStatus(this.code);

  /// Low-bit status code used by the Component Model copy result.
  final int code;
}

/// Canonical return value used when an async copy has not produced an event yet.
const int wasiComponentAsyncBlocked = 0xffffffff;

/// Result of a canonical async stream memory copy operation.
final class WASIComponentAsyncCopyResult {
  /// Creates a copy result.
  const WASIComponentAsyncCopyResult._({
    required this.status,
    required this.copiedElements,
  });

  /// Completed copy result for [copiedElements].
  factory WASIComponentAsyncCopyResult.completed(int copiedElements) {
    _checkCopyElementCount(copiedElements);
    return WASIComponentAsyncCopyResult._(
      status: WASIComponentAsyncCopyStatus.completed,
      copiedElements: copiedElements,
    );
  }

  /// Dropped copy result for [copiedElements].
  factory WASIComponentAsyncCopyResult.dropped([int copiedElements = 0]) {
    _checkCopyElementCount(copiedElements);
    return WASIComponentAsyncCopyResult._(
      status: WASIComponentAsyncCopyStatus.dropped,
      copiedElements: copiedElements,
    );
  }

  /// Cancelled copy result for [copiedElements].
  factory WASIComponentAsyncCopyResult.cancelled([int copiedElements = 0]) {
    _checkCopyElementCount(copiedElements);
    return WASIComponentAsyncCopyResult._(
      status: WASIComponentAsyncCopyStatus.cancelled,
      copiedElements: copiedElements,
    );
  }

  /// Copy status.
  final WASIComponentAsyncCopyStatus status;

  /// Number of elements copied before [status] was observed.
  final int copiedElements;

  /// Canonical packed result: status in low bits, element count above bit 4.
  int get packedResult => (copiedElements << 4) | status.code;
}

WASIComponentAsyncCopyResult _endpointFailureCopyResult(
  WASIComponentAsyncEndpointStateError error,
) => switch (error.failure) {
  WASIComponentAsyncEndpointFailure.dropped =>
    WASIComponentAsyncCopyResult.dropped(),
  WASIComponentAsyncEndpointFailure.cancelled =>
    WASIComponentAsyncCopyResult.cancelled(),
};

/// Handle-backed stream/future-only canonical program for a decoded component.
final class WASIComponentCanonicalAsyncHandleProgram {
  /// Creates a canonical async handle program from ordered [operations].
  const WASIComponentCanonicalAsyncHandleProgram({required this.operations});

  /// Stream/future operations in component canonical definition order.
  final List<WASIComponentCanonicalAsyncOperation> operations;

  /// Invokes the canonical async operation at [canonicalIndex] with handles.
  Object? invoke(int canonicalIndex, List<Object?> args) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamNew:
        _expectArity(canonicalIndex, args, 0);
        return operation.streamNewPackedHandles();
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 2);
        return operation.streamReadHandle(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          _expectNonNegativeInt(canonicalIndex, args[1], 'maxElements'),
        );
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 2);
        return operation.streamWriteHandle(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          args[1],
        );
      case WasmComponentCanonicalKind.streamCancelRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.streamCancelReadHandle(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.streamCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        return operation.streamCancelWriteHandle(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
      case WasmComponentCanonicalKind.streamDropReadable:
        _expectArity(canonicalIndex, args, 1);
        operation.streamDropReadableHandle(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
        return null;
      case WasmComponentCanonicalKind.streamDropWritable:
        _expectArity(canonicalIndex, args, 1);
        operation.streamDropWritableHandle(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
        return null;
      case WasmComponentCanonicalKind.futureNew:
        _expectArity(canonicalIndex, args, 0);
        return operation.futureNewPackedHandles();
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureReadHandle(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.futureWrite:
        _expectArity(canonicalIndex, args, 2);
        return operation.futureWriteHandle(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          args[1],
        );
      case WasmComponentCanonicalKind.futureCancelRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureCancelReadHandle(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.futureCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureCancelWriteHandle(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
      case WasmComponentCanonicalKind.futureDropReadable:
        _expectArity(canonicalIndex, args, 1);
        operation.futureDropReadableHandle(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
        return null;
      case WasmComponentCanonicalKind.futureDropWritable:
        _expectArity(canonicalIndex, args, 1);
        operation.futureDropWritableHandle(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
        return null;
      case WasmComponentCanonicalKind.backpressureInc:
        _expectArity(canonicalIndex, args, 0);
        return operation.backpressureIncrement();
      case WasmComponentCanonicalKind.backpressureDec:
        _expectArity(canonicalIndex, args, 0);
        return operation.backpressureDecrement();
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the async handle program.',
        );
    }
  }

  /// Invokes a handle-backed canonical async operation and waits for pending
  /// future reads.
  Future<Object?> invokeAsync(int canonicalIndex, List<Object?> args) async {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 2);
        return operation.streamReadHandleWhenAvailable(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          _expectNonNegativeInt(canonicalIndex, args[1], 'maxElements'),
        );
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureReadHandleWhenReady(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 2);
        return operation.streamWriteHandleWhenAvailable(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          args[1],
        );
      case WasmComponentCanonicalKind.streamCancelRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.streamCancelReadHandleWhenReady(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.streamCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        return operation.streamCancelWriteHandleWhenReady(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
      case WasmComponentCanonicalKind.futureCancelRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureCancelReadHandleWhenReady(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.futureCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureCancelWriteHandleWhenReady(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
      default:
        return invoke(canonicalIndex, args);
    }
  }

  /// Starts a no-memory core Canonical ABI operation.
  ///
  /// Unit stream copies keep the ignored pointer in their three-argument core
  /// signature, and unit future copies keep it in their two-argument signature.
  /// Copy results are returned as packed core integers.
  Object? invokeWithoutMemoryEvent(int canonicalIndex, List<Object?> args) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }
    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 3);
        _expectNonNegativeInt(canonicalIndex, args[1], 'pointer');
        return operation.streamReadHandleWithoutMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          _expectNonNegativeInt(canonicalIndex, args[2], 'maxElements'),
        );
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 3);
        _expectNonNegativeInt(canonicalIndex, args[1], 'pointer');
        return operation.streamWriteHandleWithoutMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          _expectNonNegativeInt(canonicalIndex, args[2], 'elementCount'),
        );
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 2);
        _expectNonNegativeInt(canonicalIndex, args[1], 'pointer');
        return operation.futureReadHandleWithoutMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'readable'),
        );
      case WasmComponentCanonicalKind.futureWrite:
        _expectArity(canonicalIndex, args, 2);
        _expectNonNegativeInt(canonicalIndex, args[1], 'pointer');
        return operation.futureWriteHandleWithoutMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'writable'),
        );
      default:
        return invoke(canonicalIndex, args);
    }
  }

  /// Executes a synchronous no-memory core Canonical ABI operation.
  Future<Object?> invokeWithoutMemoryAsync(
    int canonicalIndex,
    List<Object?> args,
  ) async {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }
    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 3);
        _expectNonNegativeInt(canonicalIndex, args[1], 'pointer');
        final result = await operation
            .streamReadHandleWithoutMemoryWhenAvailable(
              _expectHandle(canonicalIndex, args[0], 'readable'),
              _expectNonNegativeInt(canonicalIndex, args[2], 'maxElements'),
            );
        return result.packedResult;
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 3);
        _expectNonNegativeInt(canonicalIndex, args[1], 'pointer');
        final result = await operation
            .streamWriteHandleWithoutMemoryWhenAvailable(
              _expectHandle(canonicalIndex, args[0], 'writable'),
              _expectNonNegativeInt(canonicalIndex, args[2], 'elementCount'),
            );
        return result.packedResult;
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 2);
        _expectNonNegativeInt(canonicalIndex, args[1], 'pointer');
        final result = await operation.futureReadHandleWithoutMemoryWhenReady(
          _expectHandle(canonicalIndex, args[0], 'readable'),
        );
        return result.packedResult;
      case WasmComponentCanonicalKind.futureWrite:
        _expectArity(canonicalIndex, args, 2);
        _expectNonNegativeInt(canonicalIndex, args[1], 'pointer');
        final result = await operation.futureWriteHandleWithoutMemoryWhenRead(
          _expectHandle(canonicalIndex, args[0], 'writable'),
        );
        return result.packedResult;
      default:
        return invokeAsync(canonicalIndex, args);
    }
  }

  /// Invokes a handle-backed canonical async memory-copy operation.
  ///
  /// This uses the core Canonical ABI argument shape for stream/future copies:
  /// `stream.{read,write}` receive `(handle, ptr, n)`, and
  /// `future.{read,write}` receive `(handle, ptr)`. Dynamic string/list read
  /// paths use [realloc] to lower host values into guest memory. Completed copy
  /// results are returned in their canonical packed integer representation.
  Object? invokeWithMemory(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args, {
    WASIComponentCanonicalRealloc? realloc,
  }) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 3);
        return operation
            .streamReadHandleToMemory(
              _expectHandle(canonicalIndex, args[0], 'readable'),
              memory,
              _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
              _expectNonNegativeInt(canonicalIndex, args[2], 'maxElements'),
              realloc,
            )
            .packedResult;
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 3);
        return operation
            .streamWriteHandleFromMemory(
              _expectHandle(canonicalIndex, args[0], 'writable'),
              memory,
              _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
              _expectNonNegativeInt(canonicalIndex, args[2], 'elementCount'),
            )
            .packedResult;
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 2);
        return operation
            .futureReadHandleToMemory(
              _expectHandle(canonicalIndex, args[0], 'readable'),
              memory,
              _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
              realloc,
            )
            .packedResult;
      case WasmComponentCanonicalKind.futureWrite:
        _expectArity(canonicalIndex, args, 2);
        return operation
            .futureWriteHandleFromMemory(
              _expectHandle(canonicalIndex, args[0], 'writable'),
              memory,
              _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
            )
            .packedResult;
      default:
        return invoke(canonicalIndex, args);
    }
  }

  /// Starts a handle-backed canonical async memory-copy operation.
  ///
  /// When the copy can complete immediately, the canonical packed copy payload
  /// is returned. When it must wait for stream/future progress, this returns
  /// [wasiComponentAsyncBlocked] and later publishes a waitable event on the
  /// endpoint handle.
  Object? invokeWithMemoryEvent(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args, {
    WASIComponentCanonicalRealloc? realloc,
  }) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 3);
        return operation.streamReadHandleToMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
          _expectNonNegativeInt(canonicalIndex, args[2], 'maxElements'),
          realloc,
        );
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 3);
        return operation.streamWriteHandleFromMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
          _expectNonNegativeInt(canonicalIndex, args[2], 'elementCount'),
        );
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 2);
        return operation.futureReadHandleToMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
          realloc,
        );
      case WasmComponentCanonicalKind.futureWrite:
        _expectArity(canonicalIndex, args, 2);
        return operation.futureWriteHandleFromMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
        );
      default:
        return invoke(canonicalIndex, args);
    }
  }

  /// Invokes a handle-backed canonical async memory-copy operation and waits
  /// when the endpoint cannot complete immediately.
  Future<Object?> invokeWithMemoryAsync(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args, {
    WASIComponentCanonicalRealloc? realloc,
  }) async {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 3);
        final result = await operation.streamReadHandleToMemoryWhenAvailable(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
          _expectNonNegativeInt(canonicalIndex, args[2], 'maxElements'),
          realloc,
        );
        return result.packedResult;
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 3);
        final result = await operation.streamWriteHandleFromMemoryWhenAvailable(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
          _expectNonNegativeInt(canonicalIndex, args[2], 'elementCount'),
        );
        return result.packedResult;
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 2);
        final result = await operation.futureReadHandleToMemoryWhenReady(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
          realloc,
        );
        return result.packedResult;
      case WasmComponentCanonicalKind.futureWrite:
        _expectArity(canonicalIndex, args, 2);
        final result = await operation.futureWriteHandleFromMemoryWhenRead(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
        );
        return result.packedResult;
      default:
        return invokeWithMemory(canonicalIndex, memory, args, realloc: realloc);
    }
  }
}

/// Executable form of a canonical stream/future operation.
final class WASIComponentCanonicalAsyncOperation {
  const WASIComponentCanonicalAsyncOperation._({
    required this.kind,
    required this.componentTypeIndex,
    required this.isAsync,
    required this.stringEncoding,
    required _RegisteredAsyncValueType valueType,
  }) : _valueType = valueType,
       _backpressure = null;

  const WASIComponentCanonicalAsyncOperation._backpressure({
    required this.kind,
    required WASIComponentBackpressure backpressure,
  }) : componentTypeIndex = null,
       isAsync = false,
       stringEncoding = WASIComponentCanonicalStringEncoding.utf8,
       _valueType = null,
       _backpressure = backpressure;

  /// Canonical async operation kind.
  final WasmComponentCanonicalKind kind;

  /// Component type index the operation targets.
  final int? componentTypeIndex;

  /// Whether this canonical operation was decoded with the async flag.
  final bool isAsync;

  /// Canonical string encoding configured by decoded operation options.
  final WASIComponentCanonicalStringEncoding stringEncoding;

  final _RegisteredAsyncValueType? _valueType;
  final WASIComponentBackpressure? _backpressure;

  /// Executes `stream.new`.
  Object streamNew() {
    _requireKind(WasmComponentCanonicalKind.streamNew);
    return _requireValueType().streamNew();
  }

  /// Executes `stream.new` and returns endpoint handles.
  WASIComponentAsyncEndpointHandles streamNewHandles() {
    _requireKind(WasmComponentCanonicalKind.streamNew);
    return _requireValueType().streamNewHandles();
  }

  /// Executes `stream.new` and returns the canonical packed handle pair.
  int streamNewPackedHandles() {
    return streamNewHandles().packed;
  }

  /// Executes `stream.read`.
  List<Object?> streamRead(Object? readable, int maxElements) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamRead(readable, maxElements);
  }

  /// Executes `stream.read` and waits if the stream has no queued values.
  Future<List<Object?>> streamReadWhenAvailable(
    Object? readable,
    int maxElements,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadWhenAvailable(readable, maxElements);
  }

  /// Executes `stream.read` with a readable endpoint handle.
  List<Object?> streamReadHandle(int readable, int maxElements) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadHandle(readable, maxElements);
  }

  /// Executes `stream.read` with a readable endpoint handle and waits if the
  /// stream has no queued values.
  Future<List<Object?>> streamReadHandleWhenAvailable(
    int readable,
    int maxElements,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadHandleWhenAvailable(
      readable,
      maxElements,
    );
  }

  /// Executes `stream.write`.
  int streamWrite(Object? writable, Object? values) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWrite(writable, values);
  }

  /// Executes `stream.write` and waits if the stream has no write capacity.
  Future<int> streamWriteWhenAvailable(Object? writable, Object? values) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteWhenAvailable(writable, values);
  }

  /// Executes `stream.write` by reading elements from [memory].
  WASIComponentAsyncCopyResult streamWriteFromMemory(
    Object? writable,
    wasm.Memory memory,
    int pointer,
    int elementCount,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteFromMemory(
      writable,
      memory,
      pointer,
      elementCount,
      stringEncoding,
    );
  }

  /// Executes `stream.write` with a writable endpoint handle.
  int streamWriteHandle(int writable, Object? values) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteHandle(writable, values);
  }

  /// Executes `stream.write` with a writable endpoint handle and waits if the
  /// stream has no write capacity.
  Future<int> streamWriteHandleWhenAvailable(int writable, Object? values) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteHandleWhenAvailable(writable, values);
  }

  /// Executes handle-backed `stream.write` from memory elements.
  WASIComponentAsyncCopyResult streamWriteHandleFromMemory(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteHandleFromMemory(
      writable,
      memory,
      pointer,
      elementCount,
      stringEncoding,
    );
  }

  /// Executes handle-backed `stream.write` from memory when capacity exists.
  Future<WASIComponentAsyncCopyResult> streamWriteHandleFromMemoryWhenAvailable(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteHandleFromMemoryWhenAvailable(
      writable,
      memory,
      pointer,
      elementCount,
      stringEncoding,
    );
  }

  /// Starts handle-backed `stream.write` from memory and publishes an event.
  int streamWriteHandleFromMemoryEvent(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteHandleFromMemoryEvent(
      writable,
      memory,
      pointer,
      elementCount,
      stringEncoding,
    );
  }

  /// Starts handle-backed unit `stream.write` without canonical memory.
  int streamWriteHandleWithoutMemoryEvent(int writable, int elementCount) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteHandleWithoutMemoryEvent(
      writable,
      elementCount,
    );
  }

  /// Executes handle-backed unit `stream.write` without canonical memory.
  Future<WASIComponentAsyncCopyResult>
  streamWriteHandleWithoutMemoryWhenAvailable(int writable, int elementCount) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteHandleWithoutMemoryWhenAvailable(
      writable,
      elementCount,
    );
  }

  /// Executes `stream.read` and writes elements to [memory].
  WASIComponentAsyncCopyResult streamReadToMemory(
    Object? readable,
    wasm.Memory memory,
    int pointer,
    int maxElements, [
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadToMemory(
      readable,
      memory,
      pointer,
      maxElements,
      stringEncoding,
      realloc,
    );
  }

  /// Executes handle-backed `stream.read` into memory elements.
  WASIComponentAsyncCopyResult streamReadHandleToMemory(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements, [
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadHandleToMemory(
      readable,
      memory,
      pointer,
      maxElements,
      stringEncoding,
      realloc,
    );
  }

  /// Executes handle-backed `stream.read` into memory when values exist.
  Future<WASIComponentAsyncCopyResult> streamReadHandleToMemoryWhenAvailable(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements, [
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadHandleToMemoryWhenAvailable(
      readable,
      memory,
      pointer,
      maxElements,
      stringEncoding,
      realloc,
    );
  }

  /// Starts handle-backed `stream.read` into memory and publishes an event.
  int streamReadHandleToMemoryEvent(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements, [
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadHandleToMemoryEvent(
      readable,
      memory,
      pointer,
      maxElements,
      stringEncoding,
      realloc,
    );
  }

  /// Starts handle-backed unit `stream.read` without canonical memory.
  int streamReadHandleWithoutMemoryEvent(int readable, int maxElements) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadHandleWithoutMemoryEvent(
      readable,
      maxElements,
    );
  }

  /// Executes handle-backed unit `stream.read` without canonical memory.
  Future<WASIComponentAsyncCopyResult>
  streamReadHandleWithoutMemoryWhenAvailable(int readable, int maxElements) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadHandleWithoutMemoryWhenAvailable(
      readable,
      maxElements,
    );
  }

  /// Executes `stream.cancel-read`.
  void streamCancelRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelRead);
    _requireValueType().streamCancelRead(readable);
  }

  /// Executes `stream.cancel-read` with a readable endpoint handle.
  int streamCancelReadHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelRead);
    return _requireValueType().streamCancelReadHandle(
      readable,
      isAsync: isAsync,
    );
  }

  /// Executes `stream.cancel-read` with a readable endpoint handle, waiting
  /// for the copy event when the canonical operation is synchronous.
  Future<int> streamCancelReadHandleWhenReady(int readable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelRead);
    return _requireValueType().streamCancelReadHandleWhenReady(
      readable,
      isAsync: isAsync,
    );
  }

  /// Executes `stream.cancel-write`.
  void streamCancelWrite(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    _requireValueType().streamCancelWrite(writable);
  }

  /// Executes `stream.cancel-write` with a writable endpoint handle.
  int streamCancelWriteHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    return _requireValueType().streamCancelWriteHandle(
      writable,
      isAsync: isAsync,
    );
  }

  /// Executes `stream.cancel-write` with a writable endpoint handle, waiting
  /// for the copy event when the canonical operation is synchronous.
  Future<int> streamCancelWriteHandleWhenReady(int writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    return _requireValueType().streamCancelWriteHandleWhenReady(
      writable,
      isAsync: isAsync,
    );
  }

  /// Executes `stream.drop-readable`.
  void streamDropReadable(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.streamDropReadable);
    _requireValueType().streamDropReadable(readable);
  }

  /// Executes `stream.drop-readable` with a readable endpoint handle.
  void streamDropReadableHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.streamDropReadable);
    _requireValueType().streamDropReadableHandle(readable);
  }

  /// Executes `stream.drop-writable`.
  void streamDropWritable(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.streamDropWritable);
    _requireValueType().streamDropWritable(writable);
  }

  /// Executes `stream.drop-writable` with a writable endpoint handle.
  void streamDropWritableHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.streamDropWritable);
    _requireValueType().streamDropWritableHandle(writable);
  }

  /// Executes `future.new`.
  Object futureNew() {
    _requireKind(WasmComponentCanonicalKind.futureNew);
    return _requireValueType().futureNew();
  }

  /// Executes `future.new` and returns endpoint handles.
  WASIComponentAsyncEndpointHandles futureNewHandles() {
    _requireKind(WasmComponentCanonicalKind.futureNew);
    return _requireValueType().futureNewHandles();
  }

  /// Executes `future.new` and returns the canonical packed handle pair.
  int futureNewPackedHandles() {
    return futureNewHandles().packed;
  }

  /// Executes `future.read`.
  Object? futureRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureRead(readable);
  }

  /// Executes `future.read` and waits if the future is still pending.
  Future<Object?> futureReadWhenReady(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadWhenReady(readable);
  }

  /// Executes `future.read` with a readable endpoint handle.
  Object? futureReadHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadHandle(readable);
  }

  /// Executes `future.read` with a readable endpoint handle and waits if
  /// pending.
  Future<Object?> futureReadHandleWhenReady(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadHandleWhenReady(readable);
  }

  /// Executes `future.read` and writes a value to [memory].
  WASIComponentAsyncCopyResult futureReadToMemory(
    Object? readable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadToMemory(
      readable,
      memory,
      pointer,
      stringEncoding,
      realloc,
    );
  }

  /// Executes handle-backed `future.read` into memory.
  WASIComponentAsyncCopyResult futureReadHandleToMemory(
    int readable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadHandleToMemory(
      readable,
      memory,
      pointer,
      stringEncoding,
      realloc,
    );
  }

  /// Executes handle-backed `future.read` into memory when ready.
  Future<WASIComponentAsyncCopyResult> futureReadHandleToMemoryWhenReady(
    int readable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadHandleToMemoryWhenReady(
      readable,
      memory,
      pointer,
      stringEncoding,
      realloc,
    );
  }

  /// Starts handle-backed `future.read` into memory and publishes an event.
  int futureReadHandleToMemoryEvent(
    int readable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadHandleToMemoryEvent(
      readable,
      memory,
      pointer,
      stringEncoding,
      realloc,
    );
  }

  /// Starts handle-backed unit `future.read` without canonical memory.
  int futureReadHandleWithoutMemoryEvent(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadHandleWithoutMemoryEvent(readable);
  }

  /// Executes handle-backed unit `future.read` without canonical memory.
  Future<WASIComponentAsyncCopyResult> futureReadHandleWithoutMemoryWhenReady(
    int readable,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadHandleWithoutMemoryWhenReady(readable);
  }

  /// Executes `future.write`.
  WASIComponentAsyncCopyResult futureWrite(Object? writable, Object? value) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    return _requireValueType().futureWrite(writable, value);
  }

  /// Executes `future.write` by reading a value from [memory].
  WASIComponentAsyncCopyResult futureWriteFromMemory(
    Object? writable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    return _requireValueType().futureWriteFromMemory(
      writable,
      memory,
      pointer,
      stringEncoding,
    );
  }

  /// Executes `future.write` with a writable endpoint handle.
  WASIComponentAsyncCopyResult futureWriteHandle(int writable, Object? value) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    return _requireValueType().futureWriteHandle(writable, value);
  }

  /// Executes handle-backed `future.write` from memory.
  WASIComponentAsyncCopyResult futureWriteHandleFromMemory(
    int writable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    return _requireValueType().futureWriteHandleFromMemory(
      writable,
      memory,
      pointer,
      stringEncoding,
    );
  }

  /// Executes handle-backed `future.write` and waits for value delivery.
  Future<WASIComponentAsyncCopyResult> futureWriteHandleFromMemoryWhenRead(
    int writable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    return _requireValueType().futureWriteHandleFromMemoryWhenRead(
      writable,
      memory,
      pointer,
      stringEncoding,
    );
  }

  /// Starts handle-backed `future.write` from memory and publishes an event.
  int futureWriteHandleFromMemoryEvent(
    int writable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    return _requireValueType().futureWriteHandleFromMemoryEvent(
      writable,
      memory,
      pointer,
      stringEncoding,
    );
  }

  /// Starts handle-backed unit `future.write` without canonical memory.
  int futureWriteHandleWithoutMemoryEvent(int writable) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    return _requireValueType().futureWriteHandleWithoutMemoryEvent(writable);
  }

  /// Executes handle-backed unit `future.write` without canonical memory.
  Future<WASIComponentAsyncCopyResult> futureWriteHandleWithoutMemoryWhenRead(
    int writable,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    return _requireValueType().futureWriteHandleWithoutMemoryWhenRead(writable);
  }

  /// Executes `future.cancel-read`.
  void futureCancelRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelRead);
    _requireValueType().futureCancelRead(readable);
  }

  /// Executes `future.cancel-read` with a readable endpoint handle.
  int futureCancelReadHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelRead);
    return _requireValueType().futureCancelReadHandle(
      readable,
      isAsync: isAsync,
    );
  }

  /// Executes `future.cancel-read` with a readable endpoint handle, waiting
  /// for the copy event when the canonical operation is synchronous.
  Future<int> futureCancelReadHandleWhenReady(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelRead);
    return _requireValueType().futureCancelReadHandleWhenReady(
      readable,
      isAsync: isAsync,
    );
  }

  /// Executes `future.cancel-write`.
  void futureCancelWrite(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    _requireValueType().futureCancelWrite(writable);
  }

  /// Executes `future.cancel-write` with a writable endpoint handle.
  int futureCancelWriteHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    return _requireValueType().futureCancelWriteHandle(
      writable,
      isAsync: isAsync,
    );
  }

  /// Executes `future.cancel-write` with a writable endpoint handle, waiting
  /// for the copy event when the canonical operation is synchronous.
  Future<int> futureCancelWriteHandleWhenReady(int writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    return _requireValueType().futureCancelWriteHandleWhenReady(
      writable,
      isAsync: isAsync,
    );
  }

  /// Executes `future.drop-readable`.
  void futureDropReadable(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureDropReadable);
    _requireValueType().futureDropReadable(readable);
  }

  /// Executes `future.drop-readable` with a readable endpoint handle.
  void futureDropReadableHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureDropReadable);
    _requireValueType().futureDropReadableHandle(readable);
  }

  /// Executes `future.drop-writable`.
  void futureDropWritable(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.futureDropWritable);
    _requireValueType().futureDropWritable(writable);
  }

  /// Executes `future.drop-writable` with a writable endpoint handle.
  void futureDropWritableHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.futureDropWritable);
    _requireValueType().futureDropWritableHandle(writable);
  }

  /// Executes `backpressure.inc`.
  int backpressureIncrement() {
    _requireKind(WasmComponentCanonicalKind.backpressureInc);
    return _requireBackpressure().increment();
  }

  /// Executes `backpressure.dec`.
  int backpressureDecrement() {
    _requireKind(WasmComponentCanonicalKind.backpressureDec);
    return _requireBackpressure().decrement();
  }

  _RegisteredAsyncValueType _requireValueType() {
    final valueType = _valueType;
    if (valueType == null) {
      throw StateError(
        'WASI component canonical ${kind.name} does not target a stream or future type.',
      );
    }
    return valueType;
  }

  WASIComponentBackpressure _requireBackpressure() {
    final backpressure = _backpressure;
    if (backpressure == null) {
      throw StateError(
        'WASI component canonical ${kind.name} does not target backpressure.',
      );
    }
    return backpressure;
  }

  void _requireKind(WasmComponentCanonicalKind expected) {
    if (kind != expected) {
      throw StateError(
        'WASI component canonical ${kind.name} cannot execute ${expected.name}.',
      );
    }
  }
}

enum _WASIComponentAsyncValueKind { stream, future }

final class _WASIComponentAsyncValueValidator {
  const _WASIComponentAsyncValueValidator._({
    required this.kind,
    this.primitive,
    this.memoryCodec,
  });

  static const unconstrained = _WASIComponentAsyncValueValidator._(
    kind: _WASIComponentAsyncValueShape.unconstrained,
  );

  static const unit = _WASIComponentAsyncValueValidator._(
    kind: _WASIComponentAsyncValueShape.unit,
  );

  final _WASIComponentAsyncValueShape kind;
  final WasmComponentPrimitiveValueType? primitive;
  final WASIComponentCanonicalValueMemoryCodec? memoryCodec;

  void validateAll(String name, Iterable<Object?> values) {
    if (kind == _WASIComponentAsyncValueShape.unconstrained) {
      return;
    }
    for (final value in values) {
      validate(name, value);
    }
  }

  void validate(String name, Object? value) {
    switch (kind) {
      case _WASIComponentAsyncValueShape.unconstrained:
        return;
      case _WASIComponentAsyncValueShape.unit:
        if (value == null) {
          return;
        }
        throw StateError(
          'WASI component async type $name expected unit value.',
        );
      case _WASIComponentAsyncValueShape.primitive:
        final expected = primitive;
        if (expected != null &&
            value != null &&
            _primitiveValueMatches(expected, value)) {
          return;
        }
        throw StateError(
          'WASI component async type $name expected ${expected?.name} element value.',
        );
      case _WASIComponentAsyncValueShape.canonicalValue:
        final codec = memoryCodec;
        if (codec != null) {
          codec.validate(name, value);
          return;
        }
        throw StateError(
          'WASI component async type $name does not have a canonical value codec.',
        );
    }
  }
}

enum _WASIComponentAsyncValueShape {
  unconstrained,
  unit,
  primitive,
  canonicalValue,
}

final class _WASIComponentEndpointWaitables {
  final Map<int, WASIComponentWaitable> _waitables =
      <int, WASIComponentWaitable>{};
  final Map<int, Object> _endpoints = <int, Object>{};
  final Map<Object, Set<int>> _handlesByEndpoint =
      HashMap<Object, Set<int>>.identity();

  WASIComponentWaitable? operator [](int handle) => _waitables[handle];

  WASIComponentWaitable forEndpoint(int handle, Object endpoint, String name) {
    final existingEndpoint = _endpoints[handle];
    if (existingEndpoint != null && !identical(existingEndpoint, endpoint)) {
      throw StateError(
        'WASI component async endpoint handle $handle changed identity.',
      );
    }
    _endpoints[handle] = endpoint;
    (_handlesByEndpoint[endpoint] ??= <int>{}).add(handle);
    return _waitables.putIfAbsent(handle, () => WASIComponentWaitable(name));
  }

  void dropHandle(int handle) {
    _waitables[handle]?.drop();
    _removeHandle(handle);
  }

  void disposeEndpoint(Object endpoint) {
    final handles = _handlesByEndpoint.remove(endpoint);
    if (handles == null) {
      return;
    }
    for (final handle in handles) {
      _endpoints.remove(handle);
      _waitables.remove(handle)?.dispose();
    }
  }

  void _removeHandle(int handle) {
    _waitables.remove(handle);
    final endpoint = _endpoints.remove(handle);
    if (endpoint == null) {
      return;
    }
    final handles = _handlesByEndpoint[endpoint];
    handles?.remove(handle);
    if (handles?.isEmpty ?? false) {
      _handlesByEndpoint.remove(endpoint);
    }
  }
}

final class _RegisteredAsyncValueType<T> {
  _RegisteredAsyncValueType({
    required this.table,
    required this.name,
    required this.kind,
    required this.valueValidator,
    required this.endpointWaitables,
    this.maxBufferedElements,
    this.onDrop,
    this.onDiscard,
  }) : readableStreamType = kind == _WASIComponentAsyncValueKind.stream
           ? table.defineType<WASIComponentReadableStream<T>>(
               '$name.readable',
               onDrop: (endpoint) {
                 endpointWaitables.disposeEndpoint(endpoint);
                 endpoint.dispose();
               },
             )
           : null,
       writableStreamType = kind == _WASIComponentAsyncValueKind.stream
           ? table.defineType<WASIComponentWritableStream<T>>(
               '$name.writable',
               onDrop: (endpoint) {
                 endpointWaitables.disposeEndpoint(endpoint);
                 endpoint.dispose();
               },
             )
           : null,
       readableFutureType = kind == _WASIComponentAsyncValueKind.future
           ? table.defineType<WASIComponentReadableFuture<T>>(
               '$name.readable',
               onDrop: (endpoint) {
                 endpointWaitables.disposeEndpoint(endpoint);
                 endpoint.dispose();
               },
             )
           : null,
       writableFutureType = kind == _WASIComponentAsyncValueKind.future
           ? table.defineType<WASIComponentWritableFuture<T>>(
               '$name.writable',
               onDrop: (endpoint) {
                 endpointWaitables.disposeEndpoint(endpoint);
                 endpoint.dispose();
               },
             )
           : null;

  final WASIComponentResourceTable table;
  final String name;
  final _WASIComponentAsyncValueKind kind;
  final _WASIComponentAsyncValueValidator valueValidator;
  final _WASIComponentEndpointWaitables endpointWaitables;
  final int? maxBufferedElements;
  final void Function()? onDrop;
  final void Function(T value)? onDiscard;
  final WASIComponentResourceType<WASIComponentReadableStream<T>>?
  readableStreamType;
  final WASIComponentResourceType<WASIComponentWritableStream<T>>?
  writableStreamType;
  final WASIComponentResourceType<WASIComponentReadableFuture<T>>?
  readableFutureType;
  final WASIComponentResourceType<WASIComponentWritableFuture<T>>?
  writableFutureType;

  Object streamNew() {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    return WASIComponentStream<T>(
      name,
      maxBufferedElements: maxBufferedElements,
      onDrop: onDrop,
      onDiscard: onDiscard,
    );
  }

  WASIComponentAsyncEndpointHandles streamNewHandles() {
    final stream = streamNew() as WASIComponentStream<T>;
    final readable = table.insert<WASIComponentReadableStream<T>>(
      readableStreamType!,
      stream.readable,
    );
    final writable = table.insert<WASIComponentWritableStream<T>>(
      writableStreamType!,
      stream.writable,
    );
    return WASIComponentAsyncEndpointHandles(
      readable: readable,
      writable: writable,
    );
  }

  int lowerReadableEndpoint(Object value) {
    switch (kind) {
      case _WASIComponentAsyncValueKind.stream:
        final endpoint = switch (value) {
          WASIComponentStream<T>() => value.readable,
          WASIComponentReadableStream<T>() => value,
          _ => throw StateError(
            'WASI component async type $name expected a readable stream.',
          ),
        };
        return table.insert<WASIComponentReadableStream<T>>(
          readableStreamType!,
          endpoint,
        );
      case _WASIComponentAsyncValueKind.future:
        final endpoint = switch (value) {
          WASIComponentFuture<T>() => value.readable,
          WASIComponentReadableFuture<T>() => value,
          _ => throw StateError(
            'WASI component async type $name expected a readable future.',
          ),
        };
        return table.insert<WASIComponentReadableFuture<T>>(
          readableFutureType!,
          endpoint,
        );
    }
  }

  Object liftReadableEndpoint(int handle) {
    _requireEndpointTransferable(handle);
    switch (kind) {
      case _WASIComponentAsyncValueKind.stream:
        table.borrow<WASIComponentReadableStream<T>, void>(
          readableStreamType!,
          handle,
          (endpoint) => endpoint.requireCopyIdle(),
        );
      case _WASIComponentAsyncValueKind.future:
        table.borrow<WASIComponentReadableFuture<T>, void>(
          readableFutureType!,
          handle,
          (endpoint) => endpoint.requireCopyIdle(),
        );
    }
    final endpoint = switch (kind) {
      _WASIComponentAsyncValueKind.stream =>
        table.take<WASIComponentReadableStream<T>>(readableStreamType!, handle),
      _WASIComponentAsyncValueKind.future =>
        table.take<WASIComponentReadableFuture<T>>(readableFutureType!, handle),
    };
    endpointWaitables.dropHandle(handle);
    return endpoint;
  }

  List<Object?> streamRead(Object? readable, int maxElements) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectReadableStream(readable);
    return stream.readForCopy(maxElements);
  }

  Future<List<Object?>> streamReadWhenAvailable(
    Object? readable,
    int maxElements,
  ) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    return _expectReadableStream(readable)
        .readWhenAvailableForCopy(maxElements)
        .then<List<Object?>>((values) => values);
  }

  List<Object?> streamReadHandle(int readable, int maxElements) {
    return table.borrow<WASIComponentReadableStream<T>, List<Object?>>(
      readableStreamType!,
      readable,
      (stream) => stream.readForCopy(maxElements),
    );
  }

  Future<List<Object?>> streamReadHandleWhenAvailable(
    int readable,
    int maxElements,
  ) {
    return table.borrowAsync<WASIComponentReadableStream<T>, List<Object?>>(
      readableStreamType!,
      readable,
      (stream) => stream
          .readWhenAvailableForCopy(maxElements)
          .then<List<Object?>>((values) => values),
    );
  }

  int streamWrite(Object? writable, Object? values) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectWritableStream(writable);
    final typedValues = _expectIterableValues(values);
    return stream.writeAllForCopy(typedValues);
  }

  Future<int> streamWriteWhenAvailable(Object? writable, Object? values) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectWritableStream(writable);
    final typedValues = _expectIterableValues(values);
    return stream.writeWhenAvailableForCopy(typedValues);
  }

  WASIComponentAsyncCopyResult streamWriteFromMemory(
    Object? writable,
    wasm.Memory memory,
    int pointer,
    int elementCount, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  ]) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectWritableStream(writable);
    final values = _readValuesFromMemory<T>(
      valueValidator,
      name,
      memory,
      pointer,
      elementCount,
      stringEncoding,
    );
    try {
      final written = stream.writeAllForCopy(values);
      return WASIComponentAsyncCopyResult.completed(written);
    } on WASIComponentAsyncEndpointStateError catch (error) {
      return _endpointFailureCopyResult(error);
    }
  }

  int streamWriteHandle(int writable, Object? values) {
    return table.borrow<WASIComponentWritableStream<T>, int>(
      writableStreamType!,
      writable,
      (stream) {
        final typedValues = _expectIterableValues(values);
        return stream.writeAllForCopy(typedValues);
      },
    );
  }

  WASIComponentAsyncCopyResult streamWriteHandleFromMemory(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  ]) {
    return table
        .borrow<WASIComponentWritableStream<T>, WASIComponentAsyncCopyResult>(
          writableStreamType!,
          writable,
          (stream) {
            final values = _readValuesFromMemory<T>(
              valueValidator,
              name,
              memory,
              pointer,
              elementCount,
              stringEncoding,
            );
            try {
              final written = stream.writeAllForCopy(values);
              return WASIComponentAsyncCopyResult.completed(written);
            } on WASIComponentAsyncEndpointStateError catch (error) {
              return _endpointFailureCopyResult(error);
            }
          },
        );
  }

  Future<WASIComponentAsyncCopyResult> streamWriteHandleFromMemoryWhenAvailable(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  ]) {
    return table.borrowAsync<
      WASIComponentWritableStream<T>,
      WASIComponentAsyncCopyResult
    >(writableStreamType!, writable, (stream) async {
      final values = _readValuesFromMemory<T>(
        valueValidator,
        name,
        memory,
        pointer,
        elementCount,
        stringEncoding,
      );
      try {
        final written = await stream.writeWhenAvailableForCopy(
          values,
          asynchronous: false,
        );
        return WASIComponentAsyncCopyResult.completed(written);
      } on WASIComponentAsyncEndpointStateError catch (error) {
        return _endpointFailureCopyResult(error);
      }
    });
  }

  int streamWriteHandleFromMemoryEvent(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  ]) {
    final waitable = _existingEndpointWaitable(writable);
    return table.borrow<WASIComponentWritableStream<T>, int>(
      writableStreamType!,
      writable,
      (stream) {
        final values = _readValuesFromMemory<T>(
          valueValidator,
          name,
          memory,
          pointer,
          elementCount,
          stringEncoding,
        );
        if (stream.canWriteImmediately(values.length)) {
          try {
            final written = stream.writeAllForCopy(values);
            return WASIComponentAsyncCopyResult.completed(written).packedResult;
          } on WASIComponentAsyncEndpointStateError catch (error) {
            return _endpointFailureCopyResult(error).packedResult;
          }
        }

        stream.requireCopyIdle();
        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentWritableStream<T>,
              WASIComponentAsyncCopyResult
            >(writableStreamType!, writable, (stream) async {
              try {
                final written = await stream.writeWhenAvailableForCopy(
                  values,
                  deferCompletion: true,
                );
                return WASIComponentAsyncCopyResult.completed(written);
              } on WASIComponentAsyncEndpointStateError catch (error) {
                return _endpointFailureCopyResult(error);
              }
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.streamWrite,
          writable,
          pending,
          onDelivered: (result) => stream.finishDeferredCopy(
            dropped: result.status == WASIComponentAsyncCopyStatus.dropped,
          ),
        );
        return wasiComponentAsyncBlocked;
      },
    );
  }

  Future<WASIComponentAsyncCopyResult>
  streamWriteHandleWithoutMemoryWhenAvailable(int writable, int elementCount) {
    final values = _unitValues(elementCount);
    return table.borrowAsync<
      WASIComponentWritableStream<T>,
      WASIComponentAsyncCopyResult
    >(writableStreamType!, writable, (stream) async {
      try {
        final written = await stream.writeWhenAvailableForCopy(
          values,
          asynchronous: false,
        );
        return WASIComponentAsyncCopyResult.completed(written);
      } on WASIComponentAsyncEndpointStateError catch (error) {
        return _endpointFailureCopyResult(error);
      }
    });
  }

  int streamWriteHandleWithoutMemoryEvent(int writable, int elementCount) {
    final values = _unitValues(elementCount);
    final waitable = _existingEndpointWaitable(writable);
    return table.borrow<WASIComponentWritableStream<T>, int>(
      writableStreamType!,
      writable,
      (stream) {
        if (stream.canWriteImmediately(values.length)) {
          try {
            final written = stream.writeAllForCopy(values);
            return WASIComponentAsyncCopyResult.completed(written).packedResult;
          } on WASIComponentAsyncEndpointStateError catch (error) {
            return _endpointFailureCopyResult(error).packedResult;
          }
        }

        stream.requireCopyIdle();
        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentWritableStream<T>,
              WASIComponentAsyncCopyResult
            >(writableStreamType!, writable, (stream) async {
              try {
                final written = await stream.writeWhenAvailableForCopy(
                  values,
                  deferCompletion: true,
                );
                return WASIComponentAsyncCopyResult.completed(written);
              } on WASIComponentAsyncEndpointStateError catch (error) {
                return _endpointFailureCopyResult(error);
              }
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.streamWrite,
          writable,
          pending,
          onDelivered: (result) => stream.finishDeferredCopy(
            dropped: result.status == WASIComponentAsyncCopyStatus.dropped,
          ),
        );
        return wasiComponentAsyncBlocked;
      },
    );
  }

  Future<int> streamWriteHandleWhenAvailable(int writable, Object? values) {
    final typedValues = _expectIterableValues(values);
    return table.borrowAsync<WASIComponentWritableStream<T>, int>(
      writableStreamType!,
      writable,
      (stream) => stream.writeWhenAvailableForCopy(typedValues),
    );
  }

  WASIComponentAsyncCopyResult streamReadToMemory(
    Object? readable,
    wasm.Memory memory,
    int pointer,
    int maxElements, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _requireReallocForReadToMemory(valueValidator, name, realloc, maxElements);
    final stream = _expectReadableStream(readable);
    try {
      final values = stream.readForCopy(maxElements);
      _writeValuesToMemory(
        valueValidator,
        name,
        memory,
        pointer,
        values,
        stringEncoding,
        realloc,
      );
      return _streamReadResult(stream, values);
    } on WASIComponentAsyncEndpointStateError catch (error) {
      return _endpointFailureCopyResult(error);
    }
  }

  WASIComponentAsyncCopyResult streamReadHandleToMemory(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    return table
        .borrow<WASIComponentReadableStream<T>, WASIComponentAsyncCopyResult>(
          readableStreamType!,
          readable,
          (stream) {
            _requireReallocForReadToMemory(
              valueValidator,
              name,
              realloc,
              maxElements,
            );
            try {
              final values = stream.readForCopy(maxElements);
              _writeValuesToMemory(
                valueValidator,
                name,
                memory,
                pointer,
                values,
                stringEncoding,
                realloc,
              );
              return _streamReadResult(stream, values);
            } on WASIComponentAsyncEndpointStateError catch (error) {
              return _endpointFailureCopyResult(error);
            }
          },
        );
  }

  Future<WASIComponentAsyncCopyResult> streamReadHandleToMemoryWhenAvailable(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    return table.borrowAsync<
      WASIComponentReadableStream<T>,
      WASIComponentAsyncCopyResult
    >(readableStreamType!, readable, (stream) async {
      _requireReallocForReadToMemory(
        valueValidator,
        name,
        realloc,
        maxElements,
      );
      try {
        final values = await stream.readWhenAvailableForCopy(
          maxElements,
          asynchronous: false,
        );
        _writeValuesToMemory(
          valueValidator,
          name,
          memory,
          pointer,
          values,
          stringEncoding,
          realloc,
        );
        return _streamReadResult(stream, values);
      } on WASIComponentAsyncEndpointStateError catch (error) {
        return _endpointFailureCopyResult(error);
      }
    });
  }

  int streamReadHandleToMemoryEvent(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    final waitable = _existingEndpointWaitable(readable);
    return table.borrow<WASIComponentReadableStream<T>, int>(
      readableStreamType!,
      readable,
      (stream) {
        _requireReallocForReadToMemory(
          valueValidator,
          name,
          realloc,
          maxElements,
        );
        if (maxElements == 0 ||
            stream.hasQueuedValues ||
            stream.isEndOfStream) {
          final values = stream.readForCopy(maxElements);
          _writeValuesToMemory(
            valueValidator,
            name,
            memory,
            pointer,
            values,
            stringEncoding,
            realloc,
          );
          return _streamReadResult(stream, values).packedResult;
        }

        stream.requireCopyIdle();
        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentReadableStream<T>,
              WASIComponentAsyncCopyResult
            >(readableStreamType!, readable, (stream) {
              return stream
                  .readWhenAvailableForCopy(maxElements, deferCompletion: true)
                  .then<WASIComponentAsyncCopyResult>((values) {
                    _writeValuesToMemory(
                      valueValidator,
                      name,
                      memory,
                      pointer,
                      values,
                      stringEncoding,
                      realloc,
                    );
                    return _streamReadResult(stream, values);
                  });
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.streamRead,
          readable,
          pending,
          onDelivered: (result) => stream.finishDeferredCopy(
            dropped: result.status == WASIComponentAsyncCopyStatus.dropped,
          ),
        );
        return wasiComponentAsyncBlocked;
      },
    );
  }

  Future<WASIComponentAsyncCopyResult>
  streamReadHandleWithoutMemoryWhenAvailable(int readable, int maxElements) {
    _unitValue();
    return table.borrowAsync<
      WASIComponentReadableStream<T>,
      WASIComponentAsyncCopyResult
    >(readableStreamType!, readable, (stream) async {
      try {
        final values = await stream.readWhenAvailableForCopy(
          maxElements,
          asynchronous: false,
        );
        return _streamReadResult(stream, values);
      } on WASIComponentAsyncEndpointStateError catch (error) {
        return _endpointFailureCopyResult(error);
      }
    });
  }

  int streamReadHandleWithoutMemoryEvent(int readable, int maxElements) {
    _unitValue();
    final waitable = _existingEndpointWaitable(readable);
    return table.borrow<WASIComponentReadableStream<T>, int>(
      readableStreamType!,
      readable,
      (stream) {
        if (maxElements == 0 ||
            stream.hasQueuedValues ||
            stream.isEndOfStream) {
          final values = stream.readForCopy(maxElements);
          return _streamReadResult(stream, values).packedResult;
        }

        stream.requireCopyIdle();
        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentReadableStream<T>,
              WASIComponentAsyncCopyResult
            >(readableStreamType!, readable, (stream) {
              return stream
                  .readWhenAvailableForCopy(maxElements, deferCompletion: true)
                  .then<WASIComponentAsyncCopyResult>(
                    (values) => _streamReadResult(stream, values),
                  );
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.streamRead,
          readable,
          pending,
          onDelivered: (result) => stream.finishDeferredCopy(
            dropped: result.status == WASIComponentAsyncCopyStatus.dropped,
          ),
        );
        return wasiComponentAsyncBlocked;
      },
    );
  }

  WASIComponentAsyncCopyResult _streamReadResult(
    WASIComponentReadableStream<T> stream,
    List<T> values,
  ) {
    if (values.isEmpty && stream.isEndOfStream) {
      return WASIComponentAsyncCopyResult.dropped();
    }
    return WASIComponentAsyncCopyResult.completed(values.length);
  }

  void streamCancelRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectReadableStream(readable).cancelPendingCopy();
  }

  int streamCancelReadHandle(int readable, {required bool isAsync}) {
    return _cancelCopy(
      handle: readable,
      eventCode: WASIComponentWaitableEventCode.streamRead,
      isAsync: isAsync,
      requestCancel: () {
        table.borrow<WASIComponentReadableStream<T>, void>(
          readableStreamType!,
          readable,
          (stream) => stream.requestCopyCancellation(),
        );
      },
      cancel: () {
        table.borrow<WASIComponentReadableStream<T>, void>(
          readableStreamType!,
          readable,
          (stream) {
            stream.cancelRequestedCopy();
          },
        );
      },
    );
  }

  Future<int> streamCancelReadHandleWhenReady(
    int readable, {
    required bool isAsync,
  }) {
    return _cancelCopyWhenReady(
      handle: readable,
      eventCode: WASIComponentWaitableEventCode.streamRead,
      isAsync: isAsync,
      requestCancel: () {
        table.borrow<WASIComponentReadableStream<T>, void>(
          readableStreamType!,
          readable,
          (stream) => stream.requestCopyCancellation(),
        );
      },
      cancel: () {
        table.borrow<WASIComponentReadableStream<T>, void>(
          readableStreamType!,
          readable,
          (stream) {
            stream.cancelRequestedCopy();
          },
        );
      },
    );
  }

  void streamCancelWrite(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectWritableStream(writable).cancelPendingCopy();
  }

  int streamCancelWriteHandle(int writable, {required bool isAsync}) {
    return _cancelCopy(
      handle: writable,
      eventCode: WASIComponentWaitableEventCode.streamWrite,
      isAsync: isAsync,
      requestCancel: () {
        table.borrow<WASIComponentWritableStream<T>, void>(
          writableStreamType!,
          writable,
          (stream) => stream.requestCopyCancellation(),
        );
      },
      cancel: () {
        table.borrow<WASIComponentWritableStream<T>, void>(
          writableStreamType!,
          writable,
          (stream) {
            stream.cancelRequestedCopy();
          },
        );
      },
    );
  }

  Future<int> streamCancelWriteHandleWhenReady(
    int writable, {
    required bool isAsync,
  }) {
    return _cancelCopyWhenReady(
      handle: writable,
      eventCode: WASIComponentWaitableEventCode.streamWrite,
      isAsync: isAsync,
      requestCancel: () {
        table.borrow<WASIComponentWritableStream<T>, void>(
          writableStreamType!,
          writable,
          (stream) => stream.requestCopyCancellation(),
        );
      },
      cancel: () {
        table.borrow<WASIComponentWritableStream<T>, void>(
          writableStreamType!,
          writable,
          (stream) {
            stream.cancelRequestedCopy();
          },
        );
      },
    );
  }

  void streamDropReadable(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectReadableStream(readable).drop();
  }

  void streamDropReadableHandle(int readable) {
    _requireEndpointWaitableDroppable(readable);
    table.borrow<WASIComponentReadableStream<T>, void>(
      readableStreamType!,
      readable,
      (stream) => stream.requireDroppable(),
    );
    table.drop<WASIComponentReadableStream<T>>(readableStreamType!, readable);
  }

  void streamDropWritable(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectWritableStream(writable).drop();
  }

  void streamDropWritableHandle(int writable) {
    _requireEndpointWaitableDroppable(writable);
    table.borrow<WASIComponentWritableStream<T>, void>(
      writableStreamType!,
      writable,
      (stream) => stream.requireDroppable(),
    );
    table.drop<WASIComponentWritableStream<T>>(writableStreamType!, writable);
  }

  Object futureNew() {
    _requireKind(_WASIComponentAsyncValueKind.future);
    return WASIComponentFuture<T>(name, onDrop: onDrop, onDiscard: onDiscard);
  }

  WASIComponentAsyncEndpointHandles futureNewHandles() {
    final future = futureNew() as WASIComponentFuture<T>;
    final readable = table.insert<WASIComponentReadableFuture<T>>(
      readableFutureType!,
      future.readable,
    );
    final writable = table.insert<WASIComponentWritableFuture<T>>(
      writableFutureType!,
      future.writable,
    );
    return WASIComponentAsyncEndpointHandles(
      readable: readable,
      writable: writable,
    );
  }

  Object? futureRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    return _expectReadableFuture(readable).readForCopy();
  }

  Future<Object?> futureReadWhenReady(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    return _expectReadableFuture(readable).readWhenReadyForCopy();
  }

  Object? futureReadHandle(int readable) {
    return table.borrow<WASIComponentReadableFuture<T>, Object?>(
      readableFutureType!,
      readable,
      (future) => future.readForCopy(),
    );
  }

  Future<Object?> futureReadHandleWhenReady(int readable) {
    return table.borrowAsync<WASIComponentReadableFuture<T>, Object?>(
      readableFutureType!,
      readable,
      (future) => future.readWhenReadyForCopy(),
    );
  }

  WASIComponentAsyncCopyResult futureReadToMemory(
    Object? readable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _requireReallocForReadToMemory(valueValidator, name, realloc, 1);
    final value = _expectReadableFuture(readable).readForCopy();
    _writeValueToMemory(
      valueValidator,
      name,
      memory,
      pointer,
      value,
      stringEncoding,
      realloc,
    );
    return WASIComponentAsyncCopyResult.completed(0);
  }

  WASIComponentAsyncCopyResult futureReadHandleToMemory(
    int readable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    return table
        .borrow<WASIComponentReadableFuture<T>, WASIComponentAsyncCopyResult>(
          readableFutureType!,
          readable,
          (future) {
            _requireReallocForReadToMemory(valueValidator, name, realloc, 1);
            _writeValueToMemory(
              valueValidator,
              name,
              memory,
              pointer,
              future.readForCopy(),
              stringEncoding,
              realloc,
            );
            return WASIComponentAsyncCopyResult.completed(0);
          },
        );
  }

  Future<WASIComponentAsyncCopyResult> futureReadHandleToMemoryWhenReady(
    int readable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    return table.borrowAsync<
      WASIComponentReadableFuture<T>,
      WASIComponentAsyncCopyResult
    >(readableFutureType!, readable, (future) {
      _requireReallocForReadToMemory(valueValidator, name, realloc, 1);
      return future
          .readWhenReadyForCopy(asynchronous: false)
          .then<WASIComponentAsyncCopyResult>((value) {
            _writeValueToMemory(
              valueValidator,
              name,
              memory,
              pointer,
              value,
              stringEncoding,
              realloc,
            );
            return WASIComponentAsyncCopyResult.completed(0);
          });
    });
  }

  int futureReadHandleToMemoryEvent(
    int readable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
    WASIComponentCanonicalRealloc? realloc,
  ]) {
    final waitable = _existingEndpointWaitable(readable);
    return table.borrow<WASIComponentReadableFuture<T>, int>(
      readableFutureType!,
      readable,
      (future) {
        _requireReallocForReadToMemory(valueValidator, name, realloc, 1);
        if (future.isReady) {
          _writeValueToMemory(
            valueValidator,
            name,
            memory,
            pointer,
            future.readForCopy(),
            stringEncoding,
            realloc,
          );
          return WASIComponentAsyncCopyResult.completed(0).packedResult;
        }

        future.requireCopyIdle();
        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentReadableFuture<T>,
              WASIComponentAsyncCopyResult
            >(readableFutureType!, readable, (future) {
              return future
                  .readWhenReadyForCopy(deferCompletion: true)
                  .then<WASIComponentAsyncCopyResult>((value) {
                    _writeValueToMemory(
                      valueValidator,
                      name,
                      memory,
                      pointer,
                      value,
                      stringEncoding,
                      realloc,
                    );
                    return WASIComponentAsyncCopyResult.completed(0);
                  });
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.futureRead,
          readable,
          pending,
          onDelivered: (result) => future.finishDeferredCopy(
            cancelled: result.status == WASIComponentAsyncCopyStatus.cancelled,
          ),
        );
        return wasiComponentAsyncBlocked;
      },
    );
  }

  Future<WASIComponentAsyncCopyResult> futureReadHandleWithoutMemoryWhenReady(
    int readable,
  ) {
    _unitValue();
    return table.borrowAsync<
      WASIComponentReadableFuture<T>,
      WASIComponentAsyncCopyResult
    >(readableFutureType!, readable, (future) async {
      try {
        await future.readWhenReadyForCopy(asynchronous: false);
        return WASIComponentAsyncCopyResult.completed(0);
      } on WASIComponentAsyncEndpointStateError catch (error) {
        return _endpointFailureCopyResult(error);
      }
    });
  }

  int futureReadHandleWithoutMemoryEvent(int readable) {
    _unitValue();
    final waitable = _existingEndpointWaitable(readable);
    return table.borrow<WASIComponentReadableFuture<T>, int>(
      readableFutureType!,
      readable,
      (future) {
        if (future.isReady) {
          future.readForCopy();
          return WASIComponentAsyncCopyResult.completed(0).packedResult;
        }

        future.requireCopyIdle();
        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentReadableFuture<T>,
              WASIComponentAsyncCopyResult
            >(readableFutureType!, readable, (future) async {
              await future.readWhenReadyForCopy(deferCompletion: true);
              return WASIComponentAsyncCopyResult.completed(0);
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.futureRead,
          readable,
          pending,
          onDelivered: (result) => future.finishDeferredCopy(
            cancelled: result.status == WASIComponentAsyncCopyStatus.cancelled,
          ),
        );
        return wasiComponentAsyncBlocked;
      },
    );
  }

  WASIComponentAsyncCopyResult futureWrite(Object? writable, Object? value) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    if (value is! T) {
      throw StateError('WASI component async type $name expected $T value.');
    }
    valueValidator.validate(name, value);
    try {
      _expectWritableFuture(writable).completeForCopy(value);
      return WASIComponentAsyncCopyResult.completed(0);
    } on WASIComponentAsyncEndpointStateError catch (error) {
      return _endpointFailureCopyResult(error);
    }
  }

  WASIComponentAsyncCopyResult futureWriteFromMemory(
    Object? writable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  ]) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    final value = _readValueFromMemory<T>(
      valueValidator,
      name,
      memory,
      pointer,
      stringEncoding,
    );
    try {
      _expectWritableFuture(writable).completeForCopy(value);
      return WASIComponentAsyncCopyResult.completed(0);
    } on WASIComponentAsyncEndpointStateError catch (error) {
      return _endpointFailureCopyResult(error);
    }
  }

  WASIComponentAsyncCopyResult futureWriteHandle(int writable, Object? value) {
    return table.borrow<
      WASIComponentWritableFuture<T>,
      WASIComponentAsyncCopyResult
    >(writableFutureType!, writable, (future) {
      if (value is! T) {
        throw StateError('WASI component async type $name expected $T value.');
      }
      valueValidator.validate(name, value);
      try {
        future.completeForCopy(value);
        return WASIComponentAsyncCopyResult.completed(0);
      } on WASIComponentAsyncEndpointStateError catch (error) {
        return _endpointFailureCopyResult(error);
      }
    });
  }

  WASIComponentAsyncCopyResult futureWriteHandleFromMemory(
    int writable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  ]) {
    return table
        .borrow<WASIComponentWritableFuture<T>, WASIComponentAsyncCopyResult>(
          writableFutureType!,
          writable,
          (future) {
            final value = _readValueFromMemory<T>(
              valueValidator,
              name,
              memory,
              pointer,
              stringEncoding,
            );
            try {
              future.completeForCopy(value);
              return WASIComponentAsyncCopyResult.completed(0);
            } on WASIComponentAsyncEndpointStateError catch (error) {
              return _endpointFailureCopyResult(error);
            }
          },
        );
  }

  Future<WASIComponentAsyncCopyResult> futureWriteHandleFromMemoryWhenRead(
    int writable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  ]) {
    return table.borrowAsync<
      WASIComponentWritableFuture<T>,
      WASIComponentAsyncCopyResult
    >(writableFutureType!, writable, (future) async {
      final value = _readValueFromMemory<T>(
        valueValidator,
        name,
        memory,
        pointer,
        stringEncoding,
      );
      try {
        await future.completeWhenReadForCopy(value, asynchronous: false);
        return WASIComponentAsyncCopyResult.completed(0);
      } on WASIComponentAsyncEndpointStateError catch (error) {
        return _endpointFailureCopyResult(error);
      }
    });
  }

  int futureWriteHandleFromMemoryEvent(
    int writable,
    wasm.Memory memory,
    int pointer, [
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  ]) {
    final waitable = _existingEndpointWaitable(writable);
    return table.borrow<WASIComponentWritableFuture<T>, int>(
      writableFutureType!,
      writable,
      (future) {
        final value = _readValueFromMemory<T>(
          valueValidator,
          name,
          memory,
          pointer,
          stringEncoding,
        );
        if (!future.canComplete || future.hasPendingReader) {
          try {
            future.completeForCopy(value);
            return WASIComponentAsyncCopyResult.completed(0).packedResult;
          } on WASIComponentAsyncEndpointStateError catch (error) {
            return _endpointFailureCopyResult(error).packedResult;
          }
        }

        future.requireCopyIdle();
        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentWritableFuture<T>,
              WASIComponentAsyncCopyResult
            >(writableFutureType!, writable, (future) {
              return future
                  .completeWhenReadForCopy(value, deferCompletion: true)
                  .then((_) {
                    return WASIComponentAsyncCopyResult.completed(0);
                  });
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.futureWrite,
          writable,
          pending,
          onDelivered: (result) => future.finishDeferredCopy(
            cancelled: result.status == WASIComponentAsyncCopyStatus.cancelled,
          ),
        );
        return wasiComponentAsyncBlocked;
      },
    );
  }

  Future<WASIComponentAsyncCopyResult> futureWriteHandleWithoutMemoryWhenRead(
    int writable,
  ) {
    final value = _unitValue();
    return table.borrowAsync<
      WASIComponentWritableFuture<T>,
      WASIComponentAsyncCopyResult
    >(writableFutureType!, writable, (future) async {
      try {
        await future.completeWhenReadForCopy(value, asynchronous: false);
        return WASIComponentAsyncCopyResult.completed(0);
      } on WASIComponentAsyncEndpointStateError catch (error) {
        return _endpointFailureCopyResult(error);
      }
    });
  }

  int futureWriteHandleWithoutMemoryEvent(int writable) {
    final value = _unitValue();
    final waitable = _existingEndpointWaitable(writable);
    return table.borrow<WASIComponentWritableFuture<T>, int>(
      writableFutureType!,
      writable,
      (future) {
        if (!future.canComplete || future.hasPendingReader) {
          try {
            future.completeForCopy(value);
            return WASIComponentAsyncCopyResult.completed(0).packedResult;
          } on WASIComponentAsyncEndpointStateError catch (error) {
            return _endpointFailureCopyResult(error).packedResult;
          }
        }

        future.requireCopyIdle();
        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentWritableFuture<T>,
              WASIComponentAsyncCopyResult
            >(writableFutureType!, writable, (future) async {
              await future.completeWhenReadForCopy(
                value,
                deferCompletion: true,
              );
              return WASIComponentAsyncCopyResult.completed(0);
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.futureWrite,
          writable,
          pending,
          onDelivered: (result) => future.finishDeferredCopy(
            cancelled: result.status == WASIComponentAsyncCopyStatus.cancelled,
          ),
        );
        return wasiComponentAsyncBlocked;
      },
    );
  }

  void futureCancelRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectReadableFuture(readable).cancelPendingCopy();
  }

  int futureCancelReadHandle(int readable, {required bool isAsync}) {
    return _cancelCopy(
      handle: readable,
      eventCode: WASIComponentWaitableEventCode.futureRead,
      isAsync: isAsync,
      requestCancel: () {
        table.borrow<WASIComponentReadableFuture<T>, void>(
          readableFutureType!,
          readable,
          (future) => future.requestCopyCancellation(),
        );
      },
      cancel: () {
        table.borrow<WASIComponentReadableFuture<T>, void>(
          readableFutureType!,
          readable,
          (future) {
            future.cancelRequestedCopy();
          },
        );
      },
    );
  }

  Future<int> futureCancelReadHandleWhenReady(
    int readable, {
    required bool isAsync,
  }) {
    return _cancelCopyWhenReady(
      handle: readable,
      eventCode: WASIComponentWaitableEventCode.futureRead,
      isAsync: isAsync,
      requestCancel: () {
        table.borrow<WASIComponentReadableFuture<T>, void>(
          readableFutureType!,
          readable,
          (future) => future.requestCopyCancellation(),
        );
      },
      cancel: () {
        table.borrow<WASIComponentReadableFuture<T>, void>(
          readableFutureType!,
          readable,
          (future) {
            future.cancelRequestedCopy();
          },
        );
      },
    );
  }

  void futureCancelWrite(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectWritableFuture(writable).cancelPendingCopy();
  }

  int futureCancelWriteHandle(int writable, {required bool isAsync}) {
    return _cancelCopy(
      handle: writable,
      eventCode: WASIComponentWaitableEventCode.futureWrite,
      isAsync: isAsync,
      requestCancel: () {
        table.borrow<WASIComponentWritableFuture<T>, void>(
          writableFutureType!,
          writable,
          (future) => future.requestCopyCancellation(),
        );
      },
      cancel: () {
        table.borrow<WASIComponentWritableFuture<T>, void>(
          writableFutureType!,
          writable,
          (future) {
            future.cancelRequestedCopy();
          },
        );
      },
    );
  }

  Future<int> futureCancelWriteHandleWhenReady(
    int writable, {
    required bool isAsync,
  }) {
    return _cancelCopyWhenReady(
      handle: writable,
      eventCode: WASIComponentWaitableEventCode.futureWrite,
      isAsync: isAsync,
      requestCancel: () {
        table.borrow<WASIComponentWritableFuture<T>, void>(
          writableFutureType!,
          writable,
          (future) => future.requestCopyCancellation(),
        );
      },
      cancel: () {
        table.borrow<WASIComponentWritableFuture<T>, void>(
          writableFutureType!,
          writable,
          (future) {
            future.cancelRequestedCopy();
          },
        );
      },
    );
  }

  void futureDropReadable(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectReadableFuture(readable).drop();
  }

  void futureDropReadableHandle(int readable) {
    _requireEndpointWaitableDroppable(readable);
    table.borrow<WASIComponentReadableFuture<T>, void>(
      readableFutureType!,
      readable,
      (future) => future.requireDroppable(),
    );
    table.drop<WASIComponentReadableFuture<T>>(readableFutureType!, readable);
  }

  void futureDropWritable(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectWritableFuture(writable).drop();
  }

  void futureDropWritableHandle(int writable) {
    _requireEndpointWaitableDroppable(writable);
    table.borrow<WASIComponentWritableFuture<T>, void>(
      writableFutureType!,
      writable,
      (future) => future.requireDroppable(),
    );
    table.drop<WASIComponentWritableFuture<T>>(writableFutureType!, writable);
  }

  WASIComponentWaitable? waitableForHandle(int handle) {
    if (readableStreamType != null &&
        table.containsType<WASIComponentReadableStream<T>>(
          readableStreamType!,
          handle,
        )) {
      return _endpointWaitable(
        handle,
        table.get<WASIComponentReadableStream<T>>(readableStreamType!, handle),
        '$name.readable',
      );
    }
    if (writableStreamType != null &&
        table.containsType<WASIComponentWritableStream<T>>(
          writableStreamType!,
          handle,
        )) {
      return _endpointWaitable(
        handle,
        table.get<WASIComponentWritableStream<T>>(writableStreamType!, handle),
        '$name.writable',
      );
    }
    if (readableFutureType != null &&
        table.containsType<WASIComponentReadableFuture<T>>(
          readableFutureType!,
          handle,
        )) {
      return _endpointWaitable(
        handle,
        table.get<WASIComponentReadableFuture<T>>(readableFutureType!, handle),
        '$name.readable',
      );
    }
    if (writableFutureType != null &&
        table.containsType<WASIComponentWritableFuture<T>>(
          writableFutureType!,
          handle,
        )) {
      return _endpointWaitable(
        handle,
        table.get<WASIComponentWritableFuture<T>>(writableFutureType!, handle),
        '$name.writable',
      );
    }
    return null;
  }

  WASIComponentWaitable _endpointWaitable(
    int handle,
    Object endpoint,
    String name,
  ) {
    return endpointWaitables.forEndpoint(handle, endpoint, '$name#$handle');
  }

  WASIComponentWaitable _existingEndpointWaitable(int handle) {
    final waitable = waitableForHandle(handle);
    if (waitable != null) {
      return waitable;
    }
    throw StateError('Unknown WASI component async endpoint handle: $handle.');
  }

  void _requireEndpointWaitableDroppable(int handle) {
    endpointWaitables[handle]?.requireDroppable();
  }

  void _requireEndpointTransferable(int handle) {
    final waitable = endpointWaitables[handle];
    if (waitable?.inWaitableSet ?? false) {
      throw StateError(
        'WASI component async endpoint $handle is joined to a waitable set.',
      );
    }
    waitable?.requireDroppable();
  }

  int _cancelCopy({
    required int handle,
    required WASIComponentWaitableEventCode eventCode,
    required bool isAsync,
    required void Function() requestCancel,
    required void Function() cancel,
  }) {
    final waitable = _existingEndpointWaitable(handle);
    final event = waitable.cancelCopy(
      asynchronous: isAsync,
      requestCancel: requestCancel,
      cancel: cancel,
    );
    if (event == null) {
      return wasiComponentAsyncBlocked;
    }
    return _expectCopyEventPayload(
      waitable: waitable,
      event: event,
      eventCode: eventCode,
      handle: handle,
    );
  }

  Future<int> _cancelCopyWhenReady({
    required int handle,
    required WASIComponentWaitableEventCode eventCode,
    required bool isAsync,
    required void Function() requestCancel,
    required void Function() cancel,
  }) async {
    if (isAsync) {
      return _cancelCopy(
        handle: handle,
        eventCode: eventCode,
        isAsync: isAsync,
        requestCancel: requestCancel,
        cancel: cancel,
      );
    }
    final waitable = _existingEndpointWaitable(handle);
    final event = await waitable.cancelCopyWhenReady(
      requestCancel: requestCancel,
      cancel: cancel,
    );
    return _expectCopyEventPayload(
      waitable: waitable,
      event: event,
      eventCode: eventCode,
      handle: handle,
    );
  }

  int _expectCopyEventPayload({
    required WASIComponentWaitable waitable,
    required WASIComponentWaitableEvent event,
    required WASIComponentWaitableEventCode eventCode,
    required int handle,
  }) {
    if (event.code != eventCode || event.payload1 != handle) {
      throw StateError(
        'WASI component waitable ${waitable.name} produced ${event.code.name} '
        'for handle ${event.payload1}, expected ${eventCode.name} for '
        'handle $handle.',
      );
    }
    return event.payload2;
  }

  void _publishCopyEvent(
    WASIComponentWaitable waitable,
    WASIComponentWaitableEventCode code,
    int handle,
    Future<WASIComponentAsyncCopyResult> result, {
    required void Function(WASIComponentAsyncCopyResult result) onDelivered,
  }) {
    void publish(WASIComponentAsyncCopyResult copyResult) {
      waitable.setPendingEvent(() {
        onDelivered(copyResult);
        waitable.finishCopy(
          dropped: copyResult.status == WASIComponentAsyncCopyStatus.dropped,
        );
        return WASIComponentWaitableEvent(
          code: code,
          payload1: handle,
          payload2: copyResult.packedResult,
        );
      });
    }

    unawaited(
      result.then<void>(
        publish,
        onError: (Object error, StackTrace stackTrace) {
          final copyResult = switch (error) {
            WASIComponentAsyncEndpointStateError() =>
              _endpointFailureCopyResult(error),
            _ => WASIComponentAsyncCopyResult.cancelled(),
          };
          publish(copyResult);
        },
      ),
    );
  }

  WASIComponentReadableStream<T> _expectReadableStream(Object? value) {
    if (value is WASIComponentReadableStream<T>) {
      return value;
    }
    throw StateError(
      'WASI component async type $name expected readable stream endpoint.',
    );
  }

  WASIComponentWritableStream<T> _expectWritableStream(Object? value) {
    if (value is WASIComponentWritableStream<T>) {
      return value;
    }
    throw StateError(
      'WASI component async type $name expected writable stream endpoint.',
    );
  }

  WASIComponentReadableFuture<T> _expectReadableFuture(Object? value) {
    if (value is WASIComponentReadableFuture<T>) {
      return value;
    }
    throw StateError(
      'WASI component async type $name expected readable future endpoint.',
    );
  }

  WASIComponentWritableFuture<T> _expectWritableFuture(Object? value) {
    if (value is WASIComponentWritableFuture<T>) {
      return value;
    }
    throw StateError(
      'WASI component async type $name expected writable future endpoint.',
    );
  }

  List<T> _expectIterableValues(Object? values) {
    if (values is List<T>) {
      valueValidator.validateAll(name, values);
      return values;
    }
    if (values is! Iterable) {
      throw StateError(
        'WASI component async type $name expected iterable stream values.',
      );
    }

    final typedValues = <T>[];
    for (final value in values) {
      if (value is! T) {
        throw StateError('WASI component async type $name expected $T value.');
      }
      valueValidator.validate(name, value);
      typedValues.add(value);
    }
    return typedValues;
  }

  T _unitValue() {
    if (valueValidator.kind != _WASIComponentAsyncValueShape.unit ||
        null is! T) {
      throw StateError(
        'WASI component async type $name requires canonical memory for its payload.',
      );
    }
    return null as T;
  }

  List<T> _unitValues(int elementCount) {
    _checkCopyElementCount(elementCount);
    final value = _unitValue();
    return List<T>.filled(elementCount, value, growable: false);
  }

  void _requireKind(_WASIComponentAsyncValueKind expected) {
    if (kind != expected) {
      throw StateError(
        'WASI component async type $name is ${kind.name}, expected ${expected.name}.',
      );
    }
  }
}

_WASIComponentAsyncValueKind? _asyncValueKindForCanonicalKind(
  WasmComponentCanonicalKind kind,
) {
  return switch (kind) {
    WasmComponentCanonicalKind.streamNew ||
    WasmComponentCanonicalKind.streamRead ||
    WasmComponentCanonicalKind.streamWrite ||
    WasmComponentCanonicalKind.streamCancelRead ||
    WasmComponentCanonicalKind.streamCancelWrite ||
    WasmComponentCanonicalKind.streamDropReadable ||
    WasmComponentCanonicalKind.streamDropWritable =>
      _WASIComponentAsyncValueKind.stream,
    WasmComponentCanonicalKind.futureNew ||
    WasmComponentCanonicalKind.futureRead ||
    WasmComponentCanonicalKind.futureWrite ||
    WasmComponentCanonicalKind.futureCancelRead ||
    WasmComponentCanonicalKind.futureCancelWrite ||
    WasmComponentCanonicalKind.futureDropReadable ||
    WasmComponentCanonicalKind.futureDropWritable =>
      _WASIComponentAsyncValueKind.future,
    _ => null,
  };
}

bool _canonicalDefinitionUsesBackpressure(WasmComponentCanonicalKind kind) {
  return kind == WasmComponentCanonicalKind.backpressureInc ||
      kind == WasmComponentCanonicalKind.backpressureDec;
}

_WASIComponentAsyncValueValidator _expectDecodedAsyncType(
  WasmComponent component,
  int componentTypeIndex,
  WasmComponentDefinedValueTypeKind expected,
) {
  if (componentTypeIndex < 0 ||
      componentTypeIndex >= component.componentTypeIndexDefinitions.length) {
    throw StateError(
      'Unknown WASI component async type index: $componentTypeIndex.',
    );
  }
  final definition =
      component.componentTypeIndexDefinitions[componentTypeIndex];
  final definedValue = definition.definedValue;
  if (definition.kind != WasmComponentTypeKind.definedValue ||
      definedValue == null ||
      definedValue.kind != expected) {
    throw StateError(
      'WASI component type index $componentTypeIndex is not a ${expected.name} type.',
    );
  }
  return _asyncValueValidatorForElementType(
    definedValue.elementType,
    component.componentTypeIndexDefinitions,
  );
}

_WASIComponentAsyncValueValidator _asyncValueValidatorForElementType(
  WasmComponentValueType? elementType,
  List<WasmComponentTypeDefinition> definitions,
) {
  if (elementType == null) {
    return _WASIComponentAsyncValueValidator.unit;
  }
  final primitive = _primitiveElementType(elementType, definitions);
  if (primitive != null) {
    return _WASIComponentAsyncValueValidator._(
      kind: _WASIComponentAsyncValueShape.primitive,
      primitive: primitive,
      memoryCodec: WASIComponentCanonicalValueMemoryCodec.fromValueType(
        elementType,
        definitions,
      ),
    );
  }
  final memoryCodec =
      WASIComponentCanonicalValueMemoryCodec.fromAsyncElementType(
        elementType,
        definitions,
      );
  if (memoryCodec == null) {
    throw UnsupportedError(
      'WASI component async host currently supports only stream/future element '
      'types with a supported canonical memory layout.',
    );
  }
  return _WASIComponentAsyncValueValidator._(
    kind: _WASIComponentAsyncValueShape.canonicalValue,
    memoryCodec: memoryCodec,
  );
}

_WASIComponentAsyncValueValidator? _supportedAsyncValueValidatorForElementType(
  WasmComponentValueType? elementType,
  List<WasmComponentTypeDefinition> definitions,
) {
  try {
    return _asyncValueValidatorForElementType(elementType, definitions);
  } on UnsupportedError {
    return null;
  }
}

WasmComponentPrimitiveValueType? _primitiveElementType(
  WasmComponentValueType elementType,
  List<WasmComponentTypeDefinition> definitions,
) {
  if (elementType.kind == WasmComponentValueTypeKind.primitive) {
    return elementType.primitive;
  }

  final typeIndex = elementType.typeIndex;
  if (typeIndex == null || typeIndex < 0 || typeIndex >= definitions.length) {
    return null;
  }
  final definition = definitions[typeIndex];
  final definedValue = definition.definedValue;
  if (definition.kind != WasmComponentTypeKind.definedValue ||
      definedValue == null ||
      definedValue.kind != WasmComponentDefinedValueTypeKind.primitive) {
    return null;
  }
  return definedValue.primitive;
}

bool _primitiveValueMatches(
  WasmComponentPrimitiveValueType primitive,
  Object value,
) {
  return switch (primitive) {
    WasmComponentPrimitiveValueType.boolean => value is bool,
    WasmComponentPrimitiveValueType.s8 =>
      value is int && value >= -0x80 && value <= 0x7f,
    WasmComponentPrimitiveValueType.u8 =>
      value is int && value >= 0 && value <= 0xff,
    WasmComponentPrimitiveValueType.s16 =>
      value is int && value >= -0x8000 && value <= 0x7fff,
    WasmComponentPrimitiveValueType.u16 =>
      value is int && value >= 0 && value <= 0xffff,
    WasmComponentPrimitiveValueType.s32 =>
      value is int && value >= -0x80000000 && value <= 0x7fffffff,
    WasmComponentPrimitiveValueType.u32 =>
      value is int && value >= 0 && value <= 0xffffffff,
    WasmComponentPrimitiveValueType.s64 => wasiComponentIsI64Int(value),
    WasmComponentPrimitiveValueType.u64 => wasiComponentIsU64Int(value),
    WasmComponentPrimitiveValueType.f32 ||
    WasmComponentPrimitiveValueType.f64 => value is num,
    WasmComponentPrimitiveValueType.char =>
      singleWASIComponentUnicodeScalar(value) != null,
    WasmComponentPrimitiveValueType.string => value is String,
    WasmComponentPrimitiveValueType.errorContext =>
      value is int && value >= 0 && value <= 0xffffffff,
  };
}

List<T> _readValuesFromMemory<T>(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  int elementCount,
  WASIComponentCanonicalStringEncoding stringEncoding,
) {
  if (validator.primitive == WasmComponentPrimitiveValueType.string) {
    _checkCopyElementCount(elementCount);
    checkWASIComponentCanonicalStringRecordRange(memory, pointer, elementCount);
    return List<T>.generate(
      elementCount,
      (index) => _readStringValueFromMemory<T>(
        name,
        memory,
        pointer + index * 8,
        stringEncoding,
      ),
      growable: false,
    );
  }
  return _readCanonicalValuesFromMemory<T>(
    validator,
    name,
    memory,
    pointer,
    elementCount,
    stringEncoding,
  );
}

T _readValueFromMemory<T>(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  WASIComponentCanonicalStringEncoding stringEncoding,
) {
  if (validator.primitive == WasmComponentPrimitiveValueType.string) {
    return _readStringValueFromMemory<T>(name, memory, pointer, stringEncoding);
  }
  return _readCanonicalValueFromMemory<T>(
    validator,
    name,
    memory,
    pointer,
    stringEncoding,
  );
}

T _readStringValueFromMemory<T>(
  String name,
  wasm.Memory memory,
  int pointer,
  WASIComponentCanonicalStringEncoding stringEncoding,
) {
  final value = readWASIComponentCanonicalStringRecord(
    memory,
    pointer,
    stringEncoding,
  );
  if (value is T) {
    return value as T;
  }
  throw StateError('WASI component async type $name expected $T value.');
}

void _writeValuesToMemory(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  List<Object?> values,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentCanonicalRealloc? realloc,
) {
  if (validator.primitive == WasmComponentPrimitiveValueType.string) {
    _checkCopyElementCount(values.length);
    validator.validateAll(name, values);
    checkWASIComponentCanonicalStringRecordRange(
      memory,
      pointer,
      values.length,
    );
    if (values.isEmpty) {
      return;
    }
    final canonicalRealloc = _requireRealloc(name, realloc);
    for (var index = 0; index < values.length; index++) {
      final memoryString = writeWASIComponentCanonicalString(
        memory,
        canonicalRealloc,
        values[index] as String,
        stringEncoding,
      );
      writeWASIComponentMemoryStringRecord(
        memory,
        pointer + index * 8,
        memoryString,
      );
    }
    return;
  }
  _writeCanonicalValuesToMemory(
    validator,
    name,
    memory,
    pointer,
    values,
    stringEncoding,
    realloc,
  );
}

void _writeValueToMemory(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  Object? value,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentCanonicalRealloc? realloc,
) {
  if (validator.primitive == WasmComponentPrimitiveValueType.string) {
    final canonicalRealloc = _requireRealloc(name, realloc);
    validator.validate(name, value);
    checkWASIComponentCanonicalStringRecordRange(memory, pointer, 1);
    final memoryString = writeWASIComponentCanonicalString(
      memory,
      canonicalRealloc,
      value as String,
      stringEncoding,
    );
    writeWASIComponentMemoryStringRecord(memory, pointer, memoryString);
    return;
  }
  _writeCanonicalValueToMemory(
    validator,
    name,
    memory,
    pointer,
    value,
    stringEncoding,
    realloc,
  );
}

WASIComponentCanonicalRealloc _requireRealloc(
  String name,
  WASIComponentCanonicalRealloc? realloc,
) {
  if (realloc != null) {
    return realloc;
  }
  throw UnsupportedError(
    'WASI component async type $name requires a canonical realloc callback '
    'to write dynamic values to memory.',
  );
}

void _requireReallocForReadToMemory(
  _WASIComponentAsyncValueValidator validator,
  String name,
  WASIComponentCanonicalRealloc? realloc,
  int maxElements,
) {
  if (maxElements <= 0) {
    return;
  }
  if (validator.primitive == WasmComponentPrimitiveValueType.string ||
      (validator.memoryCodec?.requiresRealloc ?? false)) {
    _requireRealloc(name, realloc);
  }
}

List<T> _readCanonicalValuesFromMemory<T>(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  int elementCount,
  WASIComponentCanonicalStringEncoding stringEncoding,
) {
  _checkCopyElementCount(elementCount);
  if (validator.kind == _WASIComponentAsyncValueShape.unit) {
    if (null is! T) {
      throw StateError('WASI component async type $name expected $T value.');
    }
    return List<T>.filled(elementCount, null as T);
  }
  final codec = validator.memoryCodec;
  if (codec == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a canonical memory element type.',
    );
  }
  return codec.loadManyAs<T>(
    memory,
    pointer,
    elementCount,
    name,
    stringEncoding: stringEncoding,
  );
}

T _readCanonicalValueFromMemory<T>(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  WASIComponentCanonicalStringEncoding stringEncoding,
) {
  if (validator.kind == _WASIComponentAsyncValueShape.unit) {
    if (null is! T) {
      throw StateError('WASI component async type $name expected $T value.');
    }
    return null as T;
  }
  final codec = validator.memoryCodec;
  if (codec == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a canonical memory element type.',
    );
  }
  return codec.loadAs<T>(memory, pointer, name, stringEncoding: stringEncoding);
}

void _writeCanonicalValuesToMemory(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  List<Object?> values,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentCanonicalRealloc? realloc,
) {
  _checkCopyElementCount(values.length);
  validator.validateAll(name, values);
  if (validator.kind == _WASIComponentAsyncValueShape.unit) {
    return;
  }
  final codec = validator.memoryCodec;
  if (codec == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a canonical memory element type.',
    );
  }
  codec.storeMany(
    memory,
    pointer,
    values,
    realloc: realloc,
    stringEncoding: stringEncoding,
  );
}

void _writeCanonicalValueToMemory(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  Object? value,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentCanonicalRealloc? realloc,
) {
  validator.validate(name, value);
  if (validator.kind == _WASIComponentAsyncValueShape.unit) {
    return;
  }
  final codec = validator.memoryCodec;
  if (codec == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a canonical memory element type.',
    );
  }
  codec.store(
    memory,
    pointer,
    value,
    realloc: realloc,
    stringEncoding: stringEncoding,
  );
}

WASIComponentAsyncValueMemoryLayout? _memoryLayoutFor(
  _WASIComponentAsyncValueValidator validator,
) {
  final codec = validator.memoryCodec;
  if (codec == null) {
    return null;
  }
  return WASIComponentAsyncValueMemoryLayout._(
    byteLength: codec.byteLength,
    alignment: codec.alignment,
  );
}

const int _maxPackedCopyElements = 0x0fffffff;

void _checkCopyElementCount(int elementCount) {
  RangeError.checkNotNegative(elementCount, 'elementCount');
  if (elementCount > _maxPackedCopyElements) {
    throw RangeError.range(
      elementCount,
      0,
      _maxPackedCopyElements,
      'elementCount',
    );
  }
}

void _checkU32Handle(int handle, String name) {
  RangeError.checkNotNegative(handle, name);
  if (handle > _u32Mask) {
    throw RangeError.range(handle, 0, _u32Mask, name);
  }
}

void _checkI64Bits(int value, String name) {
  if (value >= 0) {
    if (value.bitLength > 64) {
      throw RangeError.value(value, name, 'does not fit in an unsigned i64');
    }
    return;
  }
  if (value < _i64Min) {
    throw RangeError.value(value, name, 'does not fit in a signed i64');
  }
}

int _floorDivideByU32Base(int value) {
  if (value >= 0) {
    return value ~/ _u32Base;
  }
  return -(((-value) + _u32Base - 1) ~/ _u32Base);
}

void _expectArity(int canonicalIndex, List<Object?> args, int expected) {
  if (args.length != expected) {
    throw StateError(
      'WASI component canonical async index $canonicalIndex expected '
      '$expected arguments, got ${args.length}.',
    );
  }
}

int _expectNonNegativeInt(int canonicalIndex, Object? value, String name) {
  if (value is int && value >= 0) {
    return value;
  }
  throw StateError(
    'WASI component canonical async index $canonicalIndex expected non-negative $name.',
  );
}

int _expectHandle(int canonicalIndex, Object? value, String name) {
  if (value is int) {
    return value;
  }
  throw StateError(
    'WASI component canonical async index $canonicalIndex expected $name handle.',
  );
}
