import '../../wasm/backend/native/interpreter/component.dart';
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
    _checkResourceBindingsAvailable(bindingList);
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

  void _checkResourceBindingsAvailable(
    List<WASIComponentResourceBinding> bindings,
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
      if (_resourceTypes.containsKey(componentTypeIndex)) {
        throw StateError(
          'WASI component resource type index $componentTypeIndex is already bound.',
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
      if (value is int &&
          value >= -0x8000000000000000 &&
          value <= 0x7fffffffffffffff) {
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
