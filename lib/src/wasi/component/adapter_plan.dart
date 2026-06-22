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
    required this.flatLayout,
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

  /// Canonical ABI flat scalar layout for this value shape, when supported.
  final WASIComponentCanonicalAdapterFlatValuePlan? flatLayout;

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

  /// Number of flat Canonical ABI scalar values, when supported.
  int? get flatLength => flatLayout?.flatLength;
}

/// Prepared flat Canonical ABI scalar layout for an adapter value.
final class WASIComponentCanonicalAdapterFlatValuePlan {
  /// Primitive scalar flat layout.
  const WASIComponentCanonicalAdapterFlatValuePlan.primitive(this.primitive)
    : kind = WASIComponentCanonicalAdapterFlatValueKind.primitive,
      memoryCodec = null,
      labels = const <String>[],
      element = null,
      ok = null,
      error = null,
      cases = const <WASIComponentCanonicalAdapterFlatCasePlan>[],
      handleKind = null,
      resourceTypeIndex = null,
      fields = const <WASIComponentCanonicalAdapterFlatFieldPlan>[];

  /// Flags bitset flat layout.
  const WASIComponentCanonicalAdapterFlatValuePlan.flags({required this.labels})
    : kind = WASIComponentCanonicalAdapterFlatValueKind.flags,
      primitive = null,
      memoryCodec = null,
      element = null,
      ok = null,
      error = null,
      cases = const <WASIComponentCanonicalAdapterFlatCasePlan>[],
      handleKind = null,
      resourceTypeIndex = null,
      fields = const <WASIComponentCanonicalAdapterFlatFieldPlan>[];

  /// Enum discriminant flat layout.
  const WASIComponentCanonicalAdapterFlatValuePlan.enumeration({
    required this.labels,
  }) : kind = WASIComponentCanonicalAdapterFlatValueKind.enumeration,
       primitive = null,
       memoryCodec = null,
       element = null,
       ok = null,
       error = null,
       cases = const <WASIComponentCanonicalAdapterFlatCasePlan>[],
       handleKind = null,
       resourceTypeIndex = null,
       fields = const <WASIComponentCanonicalAdapterFlatFieldPlan>[];

  /// Dynamic list `(ptr, len)` flat layout.
  const WASIComponentCanonicalAdapterFlatValuePlan.list({
    required this.element,
    required this.memoryCodec,
  }) : kind = WASIComponentCanonicalAdapterFlatValueKind.list,
       primitive = null,
       labels = const <String>[],
       ok = null,
       error = null,
       cases = const <WASIComponentCanonicalAdapterFlatCasePlan>[],
       handleKind = null,
       resourceTypeIndex = null,
       fields = const <WASIComponentCanonicalAdapterFlatFieldPlan>[];

  /// Option tag plus payload flat layout.
  const WASIComponentCanonicalAdapterFlatValuePlan.option({
    required this.element,
  }) : kind = WASIComponentCanonicalAdapterFlatValueKind.option,
       primitive = null,
       memoryCodec = null,
       labels = const <String>[],
       ok = null,
       error = null,
       cases = const <WASIComponentCanonicalAdapterFlatCasePlan>[],
       handleKind = null,
       resourceTypeIndex = null,
       fields = const <WASIComponentCanonicalAdapterFlatFieldPlan>[];

  /// Result tag plus the maximum ok/error payload flat layout.
  const WASIComponentCanonicalAdapterFlatValuePlan.result({
    required this.ok,
    required this.error,
  }) : kind = WASIComponentCanonicalAdapterFlatValueKind.result,
       primitive = null,
       memoryCodec = null,
       labels = const <String>[],
       element = null,
       cases = const <WASIComponentCanonicalAdapterFlatCasePlan>[],
       handleKind = null,
       resourceTypeIndex = null,
       fields = const <WASIComponentCanonicalAdapterFlatFieldPlan>[];

  /// Variant tag plus the maximum case payload flat layout.
  const WASIComponentCanonicalAdapterFlatValuePlan.variant({
    required this.cases,
  }) : kind = WASIComponentCanonicalAdapterFlatValueKind.variant,
       primitive = null,
       memoryCodec = null,
       labels = const <String>[],
       element = null,
       ok = null,
       error = null,
       handleKind = null,
       resourceTypeIndex = null,
       fields = const <WASIComponentCanonicalAdapterFlatFieldPlan>[];

  /// Resource handle represented by a canonical `u32` scalar.
  const WASIComponentCanonicalAdapterFlatValuePlan.resource({
    required this.handleKind,
    required this.resourceTypeIndex,
  }) : kind = WASIComponentCanonicalAdapterFlatValueKind.resource,
       primitive = null,
       memoryCodec = null,
       labels = const <String>[],
       element = null,
       ok = null,
       error = null,
       cases = const <WASIComponentCanonicalAdapterFlatCasePlan>[],
       fields = const <WASIComponentCanonicalAdapterFlatFieldPlan>[];

  /// Error-context handle represented by a canonical `u32` scalar.
  const WASIComponentCanonicalAdapterFlatValuePlan.errorContext()
    : kind = WASIComponentCanonicalAdapterFlatValueKind.errorContext,
      primitive = null,
      memoryCodec = null,
      labels = const <String>[],
      element = null,
      ok = null,
      error = null,
      cases = const <WASIComponentCanonicalAdapterFlatCasePlan>[],
      handleKind = null,
      resourceTypeIndex = null,
      fields = const <WASIComponentCanonicalAdapterFlatFieldPlan>[];

  /// Composite scalar flat layout.
  const WASIComponentCanonicalAdapterFlatValuePlan.composite({
    required this.kind,
    required this.fields,
  }) : primitive = null,
       memoryCodec = null,
       labels = const <String>[],
       element = null,
       ok = null,
       error = null,
       cases = const <WASIComponentCanonicalAdapterFlatCasePlan>[],
       handleKind = null,
       resourceTypeIndex = null;

  /// Flat layout kind.
  final WASIComponentCanonicalAdapterFlatValueKind kind;

  /// Primitive represented by this layout.
  final WasmComponentPrimitiveValueType? primitive;

  /// Canonical memory codec needed by dynamic flat layouts.
  final WASIComponentCanonicalValueMemoryCodec? memoryCodec;

  /// Labels used by flags or enum layouts.
  final List<String> labels;

  /// Element layout used by dynamic list layouts.
  final WASIComponentCanonicalAdapterFlatValuePlan? element;

  /// Success payload layout used by result layouts.
  final WASIComponentCanonicalAdapterFlatValuePlan? ok;

  /// Error payload layout used by result layouts.
  final WASIComponentCanonicalAdapterFlatValuePlan? error;

  /// Case layouts used by variant layouts.
  final List<WASIComponentCanonicalAdapterFlatCasePlan> cases;

  /// Resource ownership flavor used by resource handle layouts.
  final WASIComponentResourceHandleKind? handleKind;

  /// Component resource type index used by resource handle layouts.
  final int? resourceTypeIndex;

  /// Nested flat fields for composite layouts.
  final List<WASIComponentCanonicalAdapterFlatFieldPlan> fields;

  /// Number of flat Canonical ABI scalar values represented by this layout.
  int get flatLength {
    final primitive = this.primitive;
    if (primitive != null) {
      return primitive == WasmComponentPrimitiveValueType.string ? 2 : 1;
    }
    if (kind == WASIComponentCanonicalAdapterFlatValueKind.flags ||
        kind == WASIComponentCanonicalAdapterFlatValueKind.enumeration) {
      return 1;
    }
    if (kind == WASIComponentCanonicalAdapterFlatValueKind.list) {
      return 2;
    }
    if (kind == WASIComponentCanonicalAdapterFlatValueKind.resource ||
        kind == WASIComponentCanonicalAdapterFlatValueKind.errorContext) {
      return 1;
    }
    if (kind == WASIComponentCanonicalAdapterFlatValueKind.option) {
      return 1 + element!.flatLength;
    }
    if (kind == WASIComponentCanonicalAdapterFlatValueKind.result) {
      final okLength = ok?.flatLength ?? 0;
      final errorLength = error?.flatLength ?? 0;
      return 1 + (okLength > errorLength ? okLength : errorLength);
    }
    if (kind == WASIComponentCanonicalAdapterFlatValueKind.variant) {
      var maxPayloadLength = 0;
      for (final case_ in cases) {
        final payloadLength = case_.value?.flatLength ?? 0;
        if (payloadLength > maxPayloadLength) {
          maxPayloadLength = payloadLength;
        }
      }
      return 1 + maxPayloadLength;
    }
    return fields.fold<int>(
      0,
      (length, field) => length + field.value.flatLength,
    );
  }
}

/// Kind of prepared flat Canonical ABI scalar layout.
enum WASIComponentCanonicalAdapterFlatValueKind {
  /// Primitive scalar or canonical string `(ptr, len)`.
  primitive,

  /// Component record flattened field-by-field.
  record,

  /// Component tuple flattened item-by-item.
  tuple,

  /// Fixed-list flattened element-by-element.
  fixedList,

  /// Flags represented by one bitset scalar.
  flags,

  /// Enum represented by one discriminant scalar.
  enumeration,

  /// Dynamic list represented by a `(ptr, len)` scalar pair.
  list,

  /// Option represented by a tag plus payload scalar sequence.
  option,

  /// Result represented by a tag plus maximum payload scalar sequence.
  result,

  /// Variant represented by a tag plus maximum case payload scalar sequence.
  variant,

  /// Resource handle represented by a canonical `u32` scalar.
  resource,

  /// Error-context handle represented by a canonical `u32` scalar.
  errorContext,
}

/// Case in a flat Canonical ABI variant layout.
final class WASIComponentCanonicalAdapterFlatCasePlan {
  /// Creates a flat variant case layout.
  const WASIComponentCanonicalAdapterFlatCasePlan({
    required this.label,
    required this.value,
  });

  /// Case label.
  final String label;

  /// Optional case payload layout.
  final WASIComponentCanonicalAdapterFlatValuePlan? value;
}

/// Nested field in a flat Canonical ABI scalar layout.
final class WASIComponentCanonicalAdapterFlatFieldPlan {
  /// Creates a flat field layout.
  const WASIComponentCanonicalAdapterFlatFieldPlan({
    required this.label,
    required this.value,
  });

  /// Field label or stable element index.
  final String label;

  /// Nested value layout.
  final WASIComponentCanonicalAdapterFlatValuePlan value;
}

/// Builds canonical `lift`/`lower` adapter plans for [component].
List<WASIComponentCanonicalAdapterPlan> componentCanonicalAdapterPlans(
  WasmComponent component, {
  Iterable<WASIComponentResourceUse>? resourceUses,
}) {
  final definitions = component.componentTypeIndexDefinitions;
  final flatLayouts = _FlatLayoutResolver(definitions);
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
          flatLayouts: flatLayouts,
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
                flatLayouts: flatLayouts,
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
  required _FlatLayoutResolver flatLayouts,
  required List<WASIComponentResourceUse> resourceUses,
}) {
  final flatLayout = flatLayouts.resolveValueType(type);
  return WASIComponentCanonicalAdapterValuePlan(
    path: path,
    label: label,
    type: type,
    memoryCodec: _memoryCodecForAdapterValue(type, definitions, flatLayout),
    flatLayout: flatLayout,
    resourceUses: List<WASIComponentResourceUse>.unmodifiable(
      resourceUses.where((use) => _resourceUseBelongsToPath(use.path, path)),
    ),
  );
}

WASIComponentCanonicalValueMemoryCodec? _memoryCodecForAdapterValue(
  WasmComponentValueType type,
  List<WasmComponentTypeDefinition> definitions,
  WASIComponentCanonicalAdapterFlatValuePlan? flatLayout,
) {
  final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
    type,
    definitions,
  );
  if (codec != null) {
    return codec;
  }
  return flatLayout?.kind == WASIComponentCanonicalAdapterFlatValueKind.resource
      ? WASIComponentCanonicalValueMemoryCodec.canonicalU32Handle
      : null;
}

final class _FlatLayoutResolver {
  _FlatLayoutResolver(this.definitions);

  final List<WasmComponentTypeDefinition> definitions;
  final Map<int, WASIComponentCanonicalAdapterFlatValuePlan?> _cache =
      <int, WASIComponentCanonicalAdapterFlatValuePlan?>{};
  final Set<int> _visiting = <int>{};

  WASIComponentCanonicalAdapterFlatValuePlan? resolveValueType(
    WasmComponentValueType type,
  ) {
    switch (type.kind) {
      case WasmComponentValueTypeKind.primitive:
        final primitive = type.primitive;
        if (primitive == null) {
          return null;
        }
        return primitive == WasmComponentPrimitiveValueType.errorContext
            ? const WASIComponentCanonicalAdapterFlatValuePlan.errorContext()
            : WASIComponentCanonicalAdapterFlatValuePlan.primitive(primitive);
      case WasmComponentValueTypeKind.typeIndex:
        final typeIndex = type.typeIndex;
        if (typeIndex == null ||
            typeIndex < 0 ||
            typeIndex >= definitions.length) {
          return null;
        }
        if (_cache.containsKey(typeIndex)) {
          return _cache[typeIndex];
        }
        if (!_visiting.add(typeIndex)) {
          return null;
        }
        _cache[typeIndex] = null;
        final definition = definitions[typeIndex];
        final definedValue = definition.definedValue;
        final memoryCodec =
            WASIComponentCanonicalValueMemoryCodec.fromValueType(
              type,
              definitions,
            );
        final layout =
            definition.kind == WasmComponentTypeKind.definedValue &&
                definedValue != null
            ? _resolveDefinedValue(definedValue, memoryCodec)
            : null;
        _visiting.remove(typeIndex);
        _cache[typeIndex] = layout;
        return layout;
    }
  }

  WASIComponentCanonicalAdapterFlatValuePlan? _resolveDefinedValue(
    WasmComponentDefinedValueType type,
    WASIComponentCanonicalValueMemoryCodec? memoryCodec,
  ) {
    switch (type.kind) {
      case WasmComponentDefinedValueTypeKind.primitive:
        final primitive = type.primitive;
        if (primitive == null) {
          return null;
        }
        return primitive == WasmComponentPrimitiveValueType.errorContext
            ? const WASIComponentCanonicalAdapterFlatValuePlan.errorContext()
            : WASIComponentCanonicalAdapterFlatValuePlan.primitive(primitive);
      case WasmComponentDefinedValueTypeKind.record:
        final fields = <WASIComponentCanonicalAdapterFlatFieldPlan>[];
        for (final field in type.fields) {
          final layout = resolveValueType(field.type);
          if (layout == null) {
            return null;
          }
          fields.add(
            WASIComponentCanonicalAdapterFlatFieldPlan(
              label: field.label,
              value: layout,
            ),
          );
        }
        return WASIComponentCanonicalAdapterFlatValuePlan.composite(
          kind: WASIComponentCanonicalAdapterFlatValueKind.record,
          fields: List<WASIComponentCanonicalAdapterFlatFieldPlan>.unmodifiable(
            fields,
          ),
        );
      case WasmComponentDefinedValueTypeKind.tuple:
        final fields = <WASIComponentCanonicalAdapterFlatFieldPlan>[];
        for (var i = 0; i < type.types.length; i++) {
          final layout = resolveValueType(type.types[i]);
          if (layout == null) {
            return null;
          }
          fields.add(
            WASIComponentCanonicalAdapterFlatFieldPlan(
              label: '$i',
              value: layout,
            ),
          );
        }
        return WASIComponentCanonicalAdapterFlatValuePlan.composite(
          kind: WASIComponentCanonicalAdapterFlatValueKind.tuple,
          fields: List<WASIComponentCanonicalAdapterFlatFieldPlan>.unmodifiable(
            fields,
          ),
        );
      case WasmComponentDefinedValueTypeKind.fixedList:
        final elementType = type.elementType;
        final fixedLength = type.fixedLength;
        if (elementType == null || fixedLength == null) {
          return null;
        }
        final elementLayout = resolveValueType(elementType);
        if (elementLayout == null) {
          return null;
        }
        return WASIComponentCanonicalAdapterFlatValuePlan.composite(
          kind: WASIComponentCanonicalAdapterFlatValueKind.fixedList,
          fields:
              List<WASIComponentCanonicalAdapterFlatFieldPlan>.unmodifiable([
                for (var i = 0; i < fixedLength; i++)
                  WASIComponentCanonicalAdapterFlatFieldPlan(
                    label: '$i',
                    value: elementLayout,
                  ),
              ]),
        );
      case WasmComponentDefinedValueTypeKind.flags:
        return WASIComponentCanonicalAdapterFlatValuePlan.flags(
          labels: List<String>.unmodifiable(type.labels),
        );
      case WasmComponentDefinedValueTypeKind.enumeration:
        return WASIComponentCanonicalAdapterFlatValuePlan.enumeration(
          labels: List<String>.unmodifiable(type.labels),
        );
      case WasmComponentDefinedValueTypeKind.list:
        final elementType = type.elementType;
        if (elementType == null || memoryCodec == null) {
          return null;
        }
        final elementLayout = resolveValueType(elementType);
        return elementLayout == null
            ? null
            : WASIComponentCanonicalAdapterFlatValuePlan.list(
                element: elementLayout,
                memoryCodec: memoryCodec,
              );
      case WasmComponentDefinedValueTypeKind.option:
        final elementType = type.elementType;
        if (elementType == null) {
          return null;
        }
        final elementLayout = resolveValueType(elementType);
        return elementLayout == null
            ? null
            : WASIComponentCanonicalAdapterFlatValuePlan.option(
                element: elementLayout,
              );
      case WasmComponentDefinedValueTypeKind.result:
        final okType = type.okType;
        final errorType = type.errorType;
        final okLayout = okType == null ? null : resolveValueType(okType);
        final errorLayout = errorType == null
            ? null
            : resolveValueType(errorType);
        if ((okType != null && okLayout == null) ||
            (errorType != null && errorLayout == null)) {
          return null;
        }
        return WASIComponentCanonicalAdapterFlatValuePlan.result(
          ok: okLayout,
          error: errorLayout,
        );
      case WasmComponentDefinedValueTypeKind.variant:
        final cases = <WASIComponentCanonicalAdapterFlatCasePlan>[];
        for (final case_ in type.cases) {
          final caseType = case_.type;
          final layout = caseType == null ? null : resolveValueType(caseType);
          if (caseType != null && layout == null) {
            return null;
          }
          cases.add(
            WASIComponentCanonicalAdapterFlatCasePlan(
              label: case_.label,
              value: layout,
            ),
          );
        }
        return WASIComponentCanonicalAdapterFlatValuePlan.variant(
          cases: List<WASIComponentCanonicalAdapterFlatCasePlan>.unmodifiable(
            cases,
          ),
        );
      case WasmComponentDefinedValueTypeKind.own:
      case WasmComponentDefinedValueTypeKind.borrow:
        final resourceTypeIndex = type.typeIndex;
        if (resourceTypeIndex == null || resourceTypeIndex < 0) {
          return null;
        }
        return WASIComponentCanonicalAdapterFlatValuePlan.resource(
          handleKind: type.kind == WasmComponentDefinedValueTypeKind.own
              ? WASIComponentResourceHandleKind.own
              : WASIComponentResourceHandleKind.borrow,
          resourceTypeIndex: resourceTypeIndex,
        );
      case WasmComponentDefinedValueTypeKind.stream:
      case WasmComponentDefinedValueTypeKind.future:
        return null;
    }
  }
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
