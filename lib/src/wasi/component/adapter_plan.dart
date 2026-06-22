import '../../wasm/backend/native/interpreter/component.dart';
import 'resource_host.dart';
import 'string_memory.dart';
import 'value_memory.dart';

/// Prepared canonical `lift`/`lower` adapter generation metadata.
///
/// This is not an executable adapter. It is the typed input future adapter
/// generation consumes after component validation: decoded function signatures,
/// canonical options, value memory layouts, and resource-handle uses are
/// resolved once during component-host preparation.
final class WASIComponentCanonicalAdapterPlan {
  /// Creates a canonical adapter plan.
  const WASIComponentCanonicalAdapterPlan({
    required this.canonicalIndex,
    required this.definition,
    required this.functionType,
    required this.params,
    required this.result,
    required this.resourceUses,
    required this.stringEncoding,
    required this.memoryIndex,
    required this.reallocIndex,
    required this.postReturnIndex,
    required this.callbackIndex,
    required this.isAsync,
  });

  /// Canonical definition index for this adapter.
  final int canonicalIndex;

  /// Decoded canonical definition for this adapter.
  final WasmComponentCanonicalDefinition definition;

  /// Component function type this adapter bridges.
  final WasmComponentFunctionType functionType;

  /// Planned adapter parameters.
  final List<WASIComponentCanonicalAdapterValuePlan> params;

  /// Planned adapter result, when present.
  final WASIComponentCanonicalAdapterValuePlan? result;

  /// Resource handle uses inside this adapter signature.
  final List<WASIComponentResourceUse> resourceUses;

  /// Canonical string encoding selected by adapter options.
  final WASIComponentCanonicalStringEncoding stringEncoding;

  /// Core memory index selected by the adapter, when present.
  final int? memoryIndex;

  /// Core realloc function index selected by the adapter, when present.
  final int? reallocIndex;

  /// Core post-return function index selected by the adapter, when present.
  final int? postReturnIndex;

  /// Core callback function index selected by the adapter, when present.
  final int? callbackIndex;

  /// Whether the adapter has the canonical `async` option.
  final bool isAsync;

  /// Canonical adapter kind.
  WasmComponentCanonicalKind get kind => definition.kind;

  /// Whether any parameter or result has a dynamic string/list payload.
  bool get hasDynamicPayload =>
      params.any((param) => param.hasDynamicPayload) ||
      (result?.hasDynamicPayload ?? false);

  /// Whether any parameter, result, or nested value uses a resource handle.
  bool get hasResourceHandles => resourceUses.isNotEmpty;
}

/// Planned value inside a canonical adapter signature.
final class WASIComponentCanonicalAdapterValuePlan {
  /// Creates an adapter value plan.
  const WASIComponentCanonicalAdapterValuePlan({
    required this.path,
    required this.label,
    required this.type,
    required this.memoryCodec,
    required this.resourceUses,
  });

  /// Stable debug path to this value within the canonical adapter signature.
  final String path;

  /// Component parameter label, or `null` for results and unlabeled values.
  final String? label;

  /// Decoded component value type.
  final WasmComponentValueType type;

  /// Canonical ABI memory codec for this value shape, when currently supported.
  final WASIComponentCanonicalValueMemoryCodec? memoryCodec;

  /// Resource handle uses inside this value.
  final List<WASIComponentResourceUse> resourceUses;

  /// Whether this value shape has a supported Canonical ABI memory codec.
  bool get hasMemoryCodec => memoryCodec != null;

  /// Whether this value has a dynamic string/list payload.
  bool get hasDynamicPayload => memoryCodec?.requiresRealloc ?? false;

  /// Guest-memory byte length for one value, when supported.
  int? get byteLength => memoryCodec?.byteLength;

  /// Guest-memory alignment for one value, when supported.
  int? get alignment => memoryCodec?.alignment;
}

/// Builds canonical `lift`/`lower` adapter plans for [component].
List<WASIComponentCanonicalAdapterPlan> componentCanonicalAdapterPlans(
  WasmComponent component, {
  Iterable<WASIComponentResourceUse>? resourceUses,
}) {
  final definitions = component.componentTypeIndexDefinitions;
  final resourceUseList = resourceUses is List<WASIComponentResourceUse>
      ? resourceUses
      : resourceUses?.toList(growable: false) ??
            WASIComponentResourceHost().componentCanonicalResourceUses(
              component,
            );
  final plans = <WASIComponentCanonicalAdapterPlan>[];

  for (
    var canonicalIndex = 0;
    canonicalIndex < component.canonicalDefinitions.length;
    canonicalIndex++
  ) {
    final definition = component.canonicalDefinitions[canonicalIndex];
    final functionType = _canonicalAdapterFunctionType(component, definition);
    if (functionType == null) {
      continue;
    }

    final uses = List<WASIComponentResourceUse>.unmodifiable(
      resourceUseList.where((use) => use.canonicalIndex == canonicalIndex),
    );
    final params = <WASIComponentCanonicalAdapterValuePlan>[];
    for (
      var paramIndex = 0;
      paramIndex < functionType.params.length;
      paramIndex++
    ) {
      final param = functionType.params[paramIndex];
      final path = _canonicalParamPath(canonicalIndex, paramIndex, param.label);
      params.add(
        _valuePlan(
          path: path,
          label: param.label.isEmpty ? null : param.label,
          type: param.type,
          definitions: definitions,
          resourceUses: uses,
        ),
      );
    }

    final resultType = functionType.result;
    plans.add(
      WASIComponentCanonicalAdapterPlan(
        canonicalIndex: canonicalIndex,
        definition: definition,
        functionType: functionType,
        params: List<WASIComponentCanonicalAdapterValuePlan>.unmodifiable(
          params,
        ),
        result: resultType == null
            ? null
            : _valuePlan(
                path: 'canonical[$canonicalIndex].result',
                label: null,
                type: resultType,
                definitions: definitions,
                resourceUses: uses,
              ),
        resourceUses: uses,
        stringEncoding:
            WASIComponentCanonicalStringEncoding.fromCanonicalOptions(
              definition.options,
            ),
        memoryIndex: _canonicalOptionIndex(
          definition,
          WasmComponentCanonicalOptionKind.memory,
        ),
        reallocIndex: _canonicalOptionIndex(
          definition,
          WasmComponentCanonicalOptionKind.realloc,
        ),
        postReturnIndex: _canonicalOptionIndex(
          definition,
          WasmComponentCanonicalOptionKind.postReturn,
        ),
        callbackIndex: _canonicalOptionIndex(
          definition,
          WasmComponentCanonicalOptionKind.callback,
        ),
        isAsync: _hasCanonicalOption(
          definition,
          WasmComponentCanonicalOptionKind.async,
        ),
      ),
    );
  }

  return List<WASIComponentCanonicalAdapterPlan>.unmodifiable(plans);
}

WASIComponentCanonicalAdapterValuePlan _valuePlan({
  required String path,
  required String? label,
  required WasmComponentValueType type,
  required List<WasmComponentTypeDefinition> definitions,
  required List<WASIComponentResourceUse> resourceUses,
}) {
  return WASIComponentCanonicalAdapterValuePlan(
    path: path,
    label: label,
    type: type,
    memoryCodec: WASIComponentCanonicalValueMemoryCodec.fromValueType(
      type,
      definitions,
    ),
    resourceUses: List<WASIComponentResourceUse>.unmodifiable(
      resourceUses.where((use) => _resourceUseBelongsToPath(use.path, path)),
    ),
  );
}

bool _resourceUseBelongsToPath(String resourcePath, String valuePath) {
  return resourcePath == valuePath || resourcePath.startsWith('$valuePath.');
}

WasmComponentFunctionType? _canonicalAdapterFunctionType(
  WasmComponent component,
  WasmComponentCanonicalDefinition definition,
) {
  switch (definition.kind) {
    case WasmComponentCanonicalKind.lift:
      return _componentFunctionType(
        component.componentTypeIndexDefinitions,
        definition.typeIndex,
      );
    case WasmComponentCanonicalKind.lower:
      return _componentFunctionIndexType(
        component.componentFunctionIndexTypes,
        definition.functionIndex,
      );
    default:
      return null;
  }
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

WasmComponentFunctionType? _componentFunctionIndexType(
  List<WasmComponentFunctionType?> functionTypes,
  int? functionIndex,
) {
  if (functionIndex == null ||
      functionIndex < 0 ||
      functionIndex >= functionTypes.length) {
    return null;
  }
  return functionTypes[functionIndex];
}

String _canonicalParamPath(int canonicalIndex, int paramIndex, String label) {
  final base = 'canonical[$canonicalIndex].param[$paramIndex]';
  return label.isEmpty ? base : '$base.$label';
}

int? _canonicalOptionIndex(
  WasmComponentCanonicalDefinition definition,
  WasmComponentCanonicalOptionKind kind,
) {
  for (final option in definition.options) {
    if (option.kind == kind) {
      return option.index;
    }
  }
  return null;
}

bool _hasCanonicalOption(
  WasmComponentCanonicalDefinition definition,
  WasmComponentCanonicalOptionKind kind,
) {
  return definition.options.any((option) => option.kind == kind);
}
