import '../../wasm/backend/native/interpreter/component.dart';
import 'integer_bounds.dart';
import 'resource_table.dart';

/// Core representation type for a component resource.
enum WASIComponentResourceRepresentation {
  /// No decoded representation constraint is known.
  unconstrained(null),

  /// Core `i32` representation.
  i32(0x7f),

  /// Core `i64` representation.
  i64(0x7e),

  /// Core `f32` representation.
  f32(0x7d),

  /// Core `f64` representation.
  f64(0x7c);

  const WASIComponentResourceRepresentation(this.coreValueTypeCode);

  /// Component binary core value type code, when known.
  final int? coreValueTypeCode;

  /// Returns the representation for a component core value type [code].
  static WASIComponentResourceRepresentation fromCoreValueTypeCode(int? code) {
    for (final representation in values) {
      if (representation.coreValueTypeCode == code) {
        return representation;
      }
    }
    throw StateError(
      'Unsupported WASI component resource representation type: $code.',
    );
  }
}

/// Ownership flavor of a resource handle in a canonical adapter signature.
enum WASIComponentResourceHandleKind {
  /// Owned resource handle.
  own,

  /// Borrowed resource handle.
  borrow,
}

/// Binds component resource type indexes to a WASI component resource table.
///
/// This is the first execution-facing layer above [WASIComponentResourceTable]:
/// decoded canonical resource definitions are resolved against table-local
/// nominal resource types, then exposed as executable resource operations.
final class WASIComponentResourceHost {
  /// Creates a resource host backed by [table] or a new resource table.
  WASIComponentResourceHost({WASIComponentResourceTable? table})
    : table = table ?? WASIComponentResourceTable();

  /// Resource table used by this host.
  final WASIComponentResourceTable table;

  final Map<int, _RegisteredResourceType> _resourceTypes =
      <int, _RegisteredResourceType>{};

  /// Defines the host resource type for a component type index.
  WASIComponentResourceType<T> defineResourceType<T extends Object>(
    int componentTypeIndex,
    String name, {
    void Function(T resource)? onDrop,
  }) {
    return _defineResourceType<T>(
      componentTypeIndex,
      name,
      representation: WASIComponentResourceRepresentation.unconstrained,
      onDrop: onDrop,
    );
  }

  /// Defines a host resource type from a decoded component resource type.
  WASIComponentResourceType<T>
  defineResourceTypeFromComponent<T extends Object>(
    WasmComponent component,
    int componentTypeIndex,
    String name, {
    void Function(T resource)? onDrop,
  }) {
    final resource = _decodedResourceType(component, componentTypeIndex);
    return _defineResourceType<T>(
      componentTypeIndex,
      name,
      representation: _resourceRepresentation(resource),
      onDrop: onDrop,
    );
  }

  /// Returns the component resource type bindings in component type-index order.
  List<WASIComponentResourceBinding> componentResourceBindings(
    WasmComponent component,
  ) {
    final bindings = <WASIComponentResourceBinding>[];
    final definitions = component.componentTypeIndexDefinitions;
    for (
      var componentTypeIndex = 0;
      componentTypeIndex < definitions.length;
      componentTypeIndex++
    ) {
      final definition = definitions[componentTypeIndex];
      final resource = definition.resource;
      if (definition.kind != WasmComponentTypeKind.resource ||
          resource == null) {
        continue;
      }
      bindings.add(
        WASIComponentResourceBinding(
          componentTypeIndex: componentTypeIndex,
          name: 'resource[$componentTypeIndex]',
          representation: _resourceRepresentation(resource),
          isAbstract: resource.isAbstract,
        ),
      );
    }
    return List<WASIComponentResourceBinding>.unmodifiable(bindings);
  }

  /// Reports resource handles used by canonical `lift` and `lower` adapters.
  ///
  /// This is a planning API for component hosts: it walks the decoded
  /// canonical adapter function signatures and returns every `own` or `borrow`
  /// resource handle with the decoded resource binding when one is available.
  List<WASIComponentResourceUse> componentCanonicalResourceUses(
    WasmComponent component, {
    Iterable<WASIComponentResourceBinding>? resourceBindings,
  }) {
    final componentBindingsByTypeIndex = <int, WASIComponentResourceBinding>{
      for (final binding
          in resourceBindings ?? componentResourceBindings(component))
        binding.componentTypeIndex: binding,
    };
    final componentTypeIndexes =
        Map<WasmComponentTypeDefinition, int>.identity();
    final componentDefinitions = component.componentTypeIndexDefinitions;
    for (var index = 0; index < componentDefinitions.length; index++) {
      componentTypeIndexes.putIfAbsent(
        componentDefinitions[index],
        () => index,
      );
    }
    final uses = <WASIComponentResourceUse>[];

    for (
      var canonicalIndex = 0;
      canonicalIndex < component.canonicalDefinitions.length;
      canonicalIndex++
    ) {
      final definition = component.canonicalDefinitions[canonicalIndex];
      final context = _canonicalAdapterFunctionTypeContext(
        component,
        definition,
      );
      if (context == null) {
        continue;
      }
      final functionType = context.functionType;
      final definitions = context.typeDefinitions;
      final bindingsByTypeIndex = _resourceBindingsForTypeContext(
        definitions,
        componentTypeIndexes,
        componentBindingsByTypeIndex,
      );

      for (
        var paramIndex = 0;
        paramIndex < functionType.params.length;
        paramIndex++
      ) {
        final param = functionType.params[paramIndex];
        _collectResourceUses(
          param.type,
          definitions,
          bindingsByTypeIndex,
          canonicalIndex: canonicalIndex,
          canonicalKind: definition.kind,
          path: _canonicalParamPath(canonicalIndex, paramIndex, param.label),
          uses: uses,
          visiting: <int>{},
        );
      }

      _collectResourceUses(
        functionType.result,
        definitions,
        bindingsByTypeIndex,
        canonicalIndex: canonicalIndex,
        canonicalKind: definition.kind,
        path: 'canonical[$canonicalIndex].result',
        uses: uses,
        visiting: <int>{},
      );
    }

    return List<WASIComponentResourceUse>.unmodifiable(uses);
  }

  /// Defines all decoded component resource types from one component scan.
  List<WASIComponentResourceType<T>>
  defineComponentResourceTypes<T extends Object>(
    WasmComponent component, {
    String Function(WASIComponentResourceBinding binding)? nameForBinding,
    void Function(WASIComponentResourceBinding binding, T resource)? onDrop,
  }) {
    return defineResourceBindings<T>(
      componentResourceBindings(component),
      nameForBinding: nameForBinding,
      onDrop: onDrop,
    );
  }

  /// Defines resource types from a prepared component resource binding list.
  List<WASIComponentResourceType<T>> defineResourceBindings<T extends Object>(
    Iterable<WASIComponentResourceBinding> bindings, {
    String Function(WASIComponentResourceBinding binding)? nameForBinding,
    void Function(WASIComponentResourceBinding binding, T resource)? onDrop,
  }) {
    final bindingList = bindings is List<WASIComponentResourceBinding>
        ? bindings
        : bindings.toList(growable: false);
    checkResourceBindingsAvailable(bindingList);
    final types = <WASIComponentResourceType<T>>[];
    for (final binding in bindingList) {
      types.add(
        _defineResourceType<T>(
          binding.componentTypeIndex,
          nameForBinding?.call(binding) ?? binding.name,
          representation: binding.representation,
          onDrop: onDrop == null
              ? null
              : (resource) => onDrop(binding, resource),
        ),
      );
    }
    return List<WASIComponentResourceType<T>>.unmodifiable(types);
  }

  /// Creates an instance-local resource binding without mutating index state.
  WASIComponentResourceBindingSet<T> createResourceBindingSet<T extends Object>(
    Iterable<WASIComponentResourceBinding> bindings, {
    String Function(WASIComponentResourceBinding binding)? nameForBinding,
    void Function(WASIComponentResourceBinding binding, T resource)? onDrop,
  }) {
    final bindingList = bindings is List<WASIComponentResourceBinding>
        ? bindings
        : bindings.toList(growable: false);
    _checkResourceBindingDescriptors(bindingList);
    final resolvedNames = <String>[];
    final seenNames = <String>{};
    for (final binding in bindingList) {
      final name = nameForBinding?.call(binding) ?? binding.name;
      if (!seenNames.add(name)) {
        throw StateError(
          'WASI component resource name $name is bound more than once.',
        );
      }
      resolvedNames.add(name);
    }
    final types = <WASIComponentResourceType<T>>[];
    final registered = <int, _RegisteredResourceType>{};
    for (var index = 0; index < bindingList.length; index++) {
      final binding = bindingList[index];
      final type = table.defineType<T>(
        resolvedNames[index],
        onDrop: onDrop == null ? null : (resource) => onDrop(binding, resource),
      );
      types.add(type);
      registered[binding.componentTypeIndex] = _RegisteredResourceType<T>(
        type,
        binding.representation,
      );
    }
    return WASIComponentResourceBindingSet<T>._(
      table: table,
      resourceTypes: List<WASIComponentResourceType<T>>.unmodifiable(types),
      registeredTypes: Map<int, _RegisteredResourceType>.unmodifiable(
        registered,
      ),
    );
  }

  /// Throws if [bindings] cannot be added to this host's legacy index registry.
  ///
  /// Instance-local bindings should use [createResourceBindingSet], which does
  /// not reserve component-local type indexes on the shared host.
  void checkResourceBindingsAvailable(
    Iterable<WASIComponentResourceBinding> bindings,
  ) {
    final bindingList = bindings is List<WASIComponentResourceBinding>
        ? bindings
        : bindings.toList(growable: false);
    _checkResourceBindingDescriptors(bindingList);
    for (final binding in bindingList) {
      final componentTypeIndex = binding.componentTypeIndex;
      if (_resourceTypes.containsKey(componentTypeIndex)) {
        throw StateError(
          'WASI component resource type index $componentTypeIndex is already bound.',
        );
      }
    }
  }

  void _checkResourceBindingDescriptors(
    Iterable<WASIComponentResourceBinding> bindings,
  ) {
    final seen = <int>{};
    for (final binding in bindings) {
      final componentTypeIndex = binding.componentTypeIndex;
      if (componentTypeIndex < 0) {
        throw StateError(
          'WASI component resource type index $componentTypeIndex is invalid.',
        );
      }
      if (!seen.add(componentTypeIndex)) {
        throw StateError(
          'WASI component resource type index $componentTypeIndex is bound more than once.',
        );
      }
    }
  }

  WASIComponentResourceType<T> _defineResourceType<T extends Object>(
    int componentTypeIndex,
    String name, {
    required WASIComponentResourceRepresentation representation,
    void Function(T resource)? onDrop,
  }) {
    if (_resourceTypes.containsKey(componentTypeIndex)) {
      throw StateError(
        'WASI component resource type index $componentTypeIndex is already bound.',
      );
    }
    final type = table.defineType<T>(name, onDrop: onDrop);
    _resourceTypes[componentTypeIndex] = _RegisteredResourceType<T>(
      type,
      representation,
    );
    return type;
  }

  /// Binds a decoded canonical resource definition to an executable operation.
  WASIComponentCanonicalResourceOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    if (!_isResourceCanonicalKind(definition.kind)) {
      throw UnsupportedError(
        'Wasm component canonical ${definition.kind.name} is not a resource operation.',
      );
    }
    final typeIndex = definition.typeIndex;
    final resourceType = typeIndex == null ? null : _resourceTypes[typeIndex];
    if (typeIndex == null || resourceType == null) {
      throw StateError(
        'Unknown WASI component resource type index: $typeIndex.',
      );
    }
    return WASIComponentCanonicalResourceOperation._(
      table: table,
      kind: definition.kind,
      componentTypeIndex: typeIndex,
      resourceType: resourceType,
    );
  }

  /// Binds all decoded canonical resource definitions in [component].
  WASIComponentCanonicalResourceProgram bindCanonicalDefinitions(
    WasmComponent component,
  ) {
    return WASIComponentCanonicalResourceProgram(
      operations: List<WASIComponentCanonicalResourceOperation>.unmodifiable([
        for (final definition in component.canonicalDefinitions)
          bindCanonicalDefinition(definition),
      ]),
    );
  }
}

/// A decoded component resource type that can be bound to a host type.
final class WASIComponentResourceBinding {
  /// Creates a resource binding descriptor.
  const WASIComponentResourceBinding({
    required this.componentTypeIndex,
    required this.name,
    required this.representation,
    required this.isAbstract,
  });

  /// Component type index of the resource.
  final int componentTypeIndex;

  /// Stable debug name for this component resource.
  final String name;

  /// Core representation constraint decoded for this resource.
  final WASIComponentResourceRepresentation representation;

  /// Whether this resource was introduced without a concrete core
  /// representation.
  final bool isAbstract;
}

/// Resource types and canonical bindings owned by one component instance.
final class WASIComponentResourceBindingSet<T extends Object> {
  const WASIComponentResourceBindingSet._({
    required this.table,
    required this.resourceTypes,
    required Map<int, _RegisteredResourceType> registeredTypes,
  }) : _registeredTypes = registeredTypes;

  /// Shared resource table that stores handles created by this binding.
  final WASIComponentResourceTable table;

  /// Nominal resource types defined for this component instance.
  final List<WASIComponentResourceType<T>> resourceTypes;

  final Map<int, _RegisteredResourceType> _registeredTypes;

  /// Binds [definition] against this instance's local type index space.
  WASIComponentCanonicalResourceOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    if (!_isResourceCanonicalKind(definition.kind)) {
      throw UnsupportedError(
        'Wasm component canonical ${definition.kind.name} is not a resource operation.',
      );
    }
    final typeIndex = definition.typeIndex;
    final resourceType = typeIndex == null ? null : _registeredTypes[typeIndex];
    if (typeIndex == null || resourceType == null) {
      throw StateError(
        'Unknown WASI component resource type index: $typeIndex.',
      );
    }
    return WASIComponentCanonicalResourceOperation._(
      table: table,
      kind: definition.kind,
      componentTypeIndex: typeIndex,
      resourceType: resourceType,
    );
  }
}

/// One resource handle occurrence in a canonical adapter signature.
final class WASIComponentResourceUse {
  /// Creates a decoded resource-use descriptor.
  const WASIComponentResourceUse({
    required this.canonicalIndex,
    required this.canonicalKind,
    required this.path,
    required this.handleKind,
    required this.resourceTypeIndex,
    required this.binding,
  });

  /// Canonical definition index containing this handle.
  final int canonicalIndex;

  /// Canonical definition kind containing this handle.
  final WasmComponentCanonicalKind canonicalKind;

  /// Stable debug path to the handle within the canonical adapter signature.
  final String path;

  /// Whether this is an owned or borrowed handle.
  final WASIComponentResourceHandleKind handleKind;

  /// Component type index of the referenced resource type.
  final int resourceTypeIndex;

  /// Decoded resource binding, or `null` when the component is not valid
  /// enough to resolve the handle to a resource type.
  final WASIComponentResourceBinding? binding;
}

/// Executable resource-only canonical program for a decoded component.
final class WASIComponentCanonicalResourceProgram {
  /// Creates a canonical resource program from ordered [operations].
  const WASIComponentCanonicalResourceProgram({required this.operations});

  /// Resource operations in component canonical definition order.
  final List<WASIComponentCanonicalResourceOperation> operations;

  /// Invokes the canonical resource operation at [canonicalIndex].
  Object? invoke(int canonicalIndex, List<Object?> args) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical resource index: $canonicalIndex.',
      );
    }
    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.resourceNew:
        _expectArity(canonicalIndex, args, 1);
        final representation = args.single;
        if (representation == null) {
          throw StateError(
            'WASI component canonical resource.new requires a representation.',
          );
        }
        return operation.resourceNew(representation);
      case WasmComponentCanonicalKind.resourceRep:
        _expectArity(canonicalIndex, args, 1);
        return operation.resourceRep(
          _expectHandle(canonicalIndex, args.single),
        );
      case WasmComponentCanonicalKind.resourceDrop:
        _expectArity(canonicalIndex, args, 1);
        operation.resourceDrop(_expectHandle(canonicalIndex, args.single));
        return null;
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the resource program.',
        );
    }
  }
}

/// Executable form of a canonical resource operation.
final class WASIComponentCanonicalResourceOperation {
  const WASIComponentCanonicalResourceOperation._({
    required this.table,
    required this.kind,
    required this.componentTypeIndex,
    required _RegisteredResourceType resourceType,
  }) : _resourceType = resourceType;

  /// Resource table used by this operation.
  final WASIComponentResourceTable table;

  /// Canonical resource operation kind.
  final WasmComponentCanonicalKind kind;

  /// Component type index the operation targets.
  final int componentTypeIndex;

  final _RegisteredResourceType _resourceType;

  /// Executes `resource.new`.
  int resourceNew(Object representation) {
    _requireKind(WasmComponentCanonicalKind.resourceNew);
    return _resourceType.resourceNew(table, representation);
  }

  /// Executes `resource.rep`.
  Object resourceRep(int handle) {
    _requireKind(WasmComponentCanonicalKind.resourceRep);
    return _resourceType.resourceRep(table, handle);
  }

  /// Executes `resource.drop`.
  void resourceDrop(int handle) {
    _requireKind(WasmComponentCanonicalKind.resourceDrop);
    _resourceType.resourceDrop(table, handle);
  }

  void _requireKind(WasmComponentCanonicalKind expected) {
    if (kind != expected) {
      throw StateError(
        'WASI component canonical ${kind.name} cannot execute ${expected.name}.',
      );
    }
  }
}

bool _isResourceCanonicalKind(WasmComponentCanonicalKind kind) =>
    kind == WasmComponentCanonicalKind.resourceNew ||
    kind == WasmComponentCanonicalKind.resourceRep ||
    kind == WasmComponentCanonicalKind.resourceDrop;

WasmComponentFunctionTypeContext? _canonicalAdapterFunctionTypeContext(
  WasmComponent component,
  WasmComponentCanonicalDefinition definition,
) {
  switch (definition.kind) {
    case WasmComponentCanonicalKind.lift:
      final definitions = component.componentTypeIndexDefinitions;
      final functionType = _componentFunctionType(
        definitions,
        definition.typeIndex,
      );
      return functionType == null
          ? null
          : WasmComponentFunctionTypeContext(
              functionType: functionType,
              typeDefinitions: definitions,
            );
    case WasmComponentCanonicalKind.lower:
      final functionIndex = definition.functionIndex;
      if (functionIndex == null ||
          functionIndex < 0 ||
          functionIndex >=
              component.componentFunctionIndexTypeContexts.length) {
        return null;
      }
      return component.componentFunctionIndexTypeContexts[functionIndex];
    default:
      return null;
  }
}

Map<int, WASIComponentResourceBinding> _resourceBindingsForTypeContext(
  List<WasmComponentTypeDefinition> definitions,
  Map<WasmComponentTypeDefinition, int> componentTypeIndexes,
  Map<int, WASIComponentResourceBinding> componentBindings,
) {
  final bindings = <int, WASIComponentResourceBinding>{};
  for (var index = 0; index < definitions.length; index++) {
    final definition = definitions[index];
    if (definition.kind != WasmComponentTypeKind.resource ||
        definition.resource == null) {
      continue;
    }
    final componentIndex = componentTypeIndexes[definition];
    if (componentIndex == null) {
      continue;
    }
    final binding = componentBindings[componentIndex];
    if (binding != null) {
      bindings[index] = binding;
    }
  }
  return bindings;
}

WasmComponentFunctionType? _componentFunctionType(
  List<WasmComponentTypeDefinition> definitions,
  int? typeIndex,
) {
  if (typeIndex == null || typeIndex < 0 || typeIndex >= definitions.length) {
    return null;
  }
  final definition = definitions[typeIndex];
  if (definition.kind != WasmComponentTypeKind.function) {
    return null;
  }
  return definition.function;
}

String _canonicalParamPath(int canonicalIndex, int paramIndex, String label) {
  final base = 'canonical[$canonicalIndex].param[$paramIndex]';
  return label.isEmpty ? base : '$base.$label';
}

void _collectResourceUses(
  WasmComponentValueType? valueType,
  List<WasmComponentTypeDefinition> definitions,
  Map<int, WASIComponentResourceBinding> bindingsByTypeIndex, {
  required int canonicalIndex,
  required WasmComponentCanonicalKind canonicalKind,
  required String path,
  required List<WASIComponentResourceUse> uses,
  required Set<int> visiting,
}) {
  if (valueType == null ||
      valueType.kind == WasmComponentValueTypeKind.primitive) {
    return;
  }

  final typeIndex = valueType.typeIndex;
  if (typeIndex == null ||
      typeIndex < 0 ||
      typeIndex >= definitions.length ||
      !visiting.add(typeIndex)) {
    return;
  }

  final definition = definitions[typeIndex];
  final definedValue = definition.definedValue;
  if (definition.kind == WasmComponentTypeKind.definedValue &&
      definedValue != null) {
    _collectDefinedValueResourceUses(
      definedValue,
      definitions,
      bindingsByTypeIndex,
      canonicalIndex: canonicalIndex,
      canonicalKind: canonicalKind,
      path: path,
      uses: uses,
      visiting: visiting,
    );
  }
  visiting.remove(typeIndex);
}

void _collectDefinedValueResourceUses(
  WasmComponentDefinedValueType definedValue,
  List<WasmComponentTypeDefinition> definitions,
  Map<int, WASIComponentResourceBinding> bindingsByTypeIndex, {
  required int canonicalIndex,
  required WasmComponentCanonicalKind canonicalKind,
  required String path,
  required List<WASIComponentResourceUse> uses,
  required Set<int> visiting,
}) {
  switch (definedValue.kind) {
    case WasmComponentDefinedValueTypeKind.own:
    case WasmComponentDefinedValueTypeKind.borrow:
      final resourceTypeIndex = definedValue.typeIndex;
      if (resourceTypeIndex == null || resourceTypeIndex < 0) {
        return;
      }
      uses.add(
        WASIComponentResourceUse(
          canonicalIndex: canonicalIndex,
          canonicalKind: canonicalKind,
          path: path,
          handleKind: definedValue.kind == WasmComponentDefinedValueTypeKind.own
              ? WASIComponentResourceHandleKind.own
              : WASIComponentResourceHandleKind.borrow,
          resourceTypeIndex: resourceTypeIndex,
          binding: bindingsByTypeIndex[resourceTypeIndex],
        ),
      );
      return;
    case WasmComponentDefinedValueTypeKind.record:
      for (final field in definedValue.fields) {
        _collectResourceUses(
          field.type,
          definitions,
          bindingsByTypeIndex,
          canonicalIndex: canonicalIndex,
          canonicalKind: canonicalKind,
          path: '$path.${field.label}',
          uses: uses,
          visiting: visiting,
        );
      }
      return;
    case WasmComponentDefinedValueTypeKind.variant:
      for (var i = 0; i < definedValue.cases.length; i++) {
        final case_ = definedValue.cases[i];
        _collectResourceUses(
          case_.type,
          definitions,
          bindingsByTypeIndex,
          canonicalIndex: canonicalIndex,
          canonicalKind: canonicalKind,
          path: '$path.case[$i].${case_.label}',
          uses: uses,
          visiting: visiting,
        );
      }
      return;
    case WasmComponentDefinedValueTypeKind.list:
    case WasmComponentDefinedValueTypeKind.fixedList:
    case WasmComponentDefinedValueTypeKind.option:
    case WasmComponentDefinedValueTypeKind.stream:
    case WasmComponentDefinedValueTypeKind.future:
      _collectResourceUses(
        definedValue.elementType,
        definitions,
        bindingsByTypeIndex,
        canonicalIndex: canonicalIndex,
        canonicalKind: canonicalKind,
        path: '$path.element',
        uses: uses,
        visiting: visiting,
      );
      return;
    case WasmComponentDefinedValueTypeKind.tuple:
      for (var i = 0; i < definedValue.types.length; i++) {
        _collectResourceUses(
          definedValue.types[i],
          definitions,
          bindingsByTypeIndex,
          canonicalIndex: canonicalIndex,
          canonicalKind: canonicalKind,
          path: '$path.item[$i]',
          uses: uses,
          visiting: visiting,
        );
      }
      return;
    case WasmComponentDefinedValueTypeKind.result:
      _collectResourceUses(
        definedValue.okType,
        definitions,
        bindingsByTypeIndex,
        canonicalIndex: canonicalIndex,
        canonicalKind: canonicalKind,
        path: '$path.ok',
        uses: uses,
        visiting: visiting,
      );
      _collectResourceUses(
        definedValue.errorType,
        definitions,
        bindingsByTypeIndex,
        canonicalIndex: canonicalIndex,
        canonicalKind: canonicalKind,
        path: '$path.error',
        uses: uses,
        visiting: visiting,
      );
      return;
    case WasmComponentDefinedValueTypeKind.primitive:
    case WasmComponentDefinedValueTypeKind.flags:
    case WasmComponentDefinedValueTypeKind.enumeration:
      return;
  }
}

final class _RegisteredResourceType<T extends Object> {
  const _RegisteredResourceType(this.type, this.representation);

  final WASIComponentResourceType<T> type;
  final WASIComponentResourceRepresentation representation;

  int resourceNew(WASIComponentResourceTable table, Object representation) {
    _validateRepresentation(type.name, this.representation, representation);
    if (representation is! T) {
      throw StateError(
        'WASI component resource ${type.name} expected $T representation.',
      );
    }
    return table.resourceNew<T>(type, representation);
  }

  Object resourceRep(WASIComponentResourceTable table, int handle) {
    return table.resourceRep<T>(type, handle);
  }

  void resourceDrop(WASIComponentResourceTable table, int handle) {
    table.resourceDrop<T>(type, handle);
  }
}

WasmComponentResourceType _decodedResourceType(
  WasmComponent component,
  int componentTypeIndex,
) {
  if (componentTypeIndex < 0 ||
      componentTypeIndex >= component.componentTypeIndexDefinitions.length) {
    throw StateError(
      'Unknown WASI component resource type index: $componentTypeIndex.',
    );
  }
  final definition =
      component.componentTypeIndexDefinitions[componentTypeIndex];
  final resource = definition.resource;
  if (definition.kind != WasmComponentTypeKind.resource || resource == null) {
    throw StateError(
      'WASI component type index $componentTypeIndex is not a resource type.',
    );
  }
  return resource;
}

WASIComponentResourceRepresentation _resourceRepresentation(
  WasmComponentResourceType resource,
) {
  return resource.isAbstract
      ? WASIComponentResourceRepresentation.unconstrained
      : WASIComponentResourceRepresentation.fromCoreValueTypeCode(
          resource.representationTypeCode,
        );
}

void _validateRepresentation(
  String name,
  WASIComponentResourceRepresentation representation,
  Object value,
) {
  switch (representation) {
    case WASIComponentResourceRepresentation.unconstrained:
      return;
    case WASIComponentResourceRepresentation.i32:
      if (value is int && value >= -0x80000000 && value <= 0x7fffffff) {
        return;
      }
    case WASIComponentResourceRepresentation.i64:
      if (wasiComponentIsI64Int(value)) {
        return;
      }
    case WASIComponentResourceRepresentation.f32:
    case WASIComponentResourceRepresentation.f64:
      if (value is num) {
        return;
      }
  }
  throw StateError(
    'WASI component resource $name expected ${representation.name} representation.',
  );
}

void _expectArity(int canonicalIndex, List<Object?> args, int expected) {
  if (args.length != expected) {
    throw StateError(
      'WASI component canonical resource index $canonicalIndex expected '
      '$expected arguments, got ${args.length}.',
    );
  }
}

int _expectHandle(int canonicalIndex, Object? value) {
  if (value is int) {
    return value;
  }
  throw StateError(
    'WASI component canonical resource index $canonicalIndex expected an i32 handle.',
  );
}
