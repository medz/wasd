import '../../wasm/backend/native/interpreter/component.dart';
import 'resource_table.dart';

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
    if (_resourceTypes.containsKey(componentTypeIndex)) {
      throw StateError(
        'WASI component resource type index $componentTypeIndex is already bound.',
      );
    }
    final type = table.defineType<T>(name, onDrop: onDrop);
    _resourceTypes[componentTypeIndex] = _RegisteredResourceType<T>(type);
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
  const _RegisteredResourceType(this.type);

  final WASIComponentResourceType<T> type;

  int resourceNew(WASIComponentResourceTable table, Object representation) {
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
