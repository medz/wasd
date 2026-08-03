import 'dart:async';

import '../../wasm/backend/native/interpreter/component.dart';
import 'async_values.dart';
import 'unicode_scalar.dart';
import 'wit_document.dart';

/// Callback used by generated WIT adapter operations.
typedef WASIComponentWitAdapterCallback =
    FutureOr<Object?> Function(List<Object?> args);

/// Resolves a qualified WIT target such as `wasi:random/imports@0.3.0`.
typedef WASIComponentWitTargetResolver =
    WASIComponentWitResolvedTarget? Function(String target);

/// Standard or external WIT target resolved to a parsed document member.
final class WASIComponentWitResolvedTarget {
  /// Creates a resolved WIT target.
  const WASIComponentWitResolvedTarget({
    required this.document,
    required this.memberName,
  });

  /// Parsed WIT document containing [memberName].
  final WASIComponentWitDocument document;

  /// Interface or world member name inside [document].
  final String memberName;

  /// Canonical interface callback name for [interfaceName].
  String qualifiedInterfaceName(String interfaceName) {
    final package = document.package;
    if (package == null) {
      return interfaceName;
    }
    final version = package.version == null ? '' : '@${package.version}';
    return '${package.namespace}:${package.name}/$interfaceName$version';
  }
}

/// Thrown when a qualified WIT world target cannot be resolved completely.
final class WASIComponentWitTargetResolutionException implements Exception {
  /// Creates an unresolved-target error for [target].
  const WASIComponentWitTargetResolutionException(this.target, this.reason);

  /// Qualified WIT target that could not be expanded.
  final String target;

  /// Resolution failure detail.
  final String reason;

  @override
  String toString() {
    return 'Unable to resolve qualified WIT target $target: $reason';
  }
}

/// Expands local and resolved WIT import/export interface functions from [world].
List<WASIComponentWitFunctionBinding> wasiComponentWitWorldFunctions(
  WASIComponentWitDocument document,
  WASIComponentWitWorld world, {
  WASIComponentWitTargetResolver? resolveTarget,
  Set<String>? visiting,
  String Function(String interfaceName)? qualifyInterfaceName,
}) {
  final active = visiting ?? <String>{};
  final visitKey = _witWorldVisitKey(document, world);
  if (!active.add(visitKey)) {
    return const <WASIComponentWitFunctionBinding>[];
  }
  final functions = <WASIComponentWitFunctionBinding>[];
  for (final item in world.items) {
    final target = item.target;
    if (item.direction == WASIComponentWitWorldItemDirection.include) {
      if (target.isQualified) {
        final resolved = resolveTarget?.call(target.text);
        if (resolved == null) {
          throw WASIComponentWitTargetResolutionException(
            target.text,
            'no resolver result',
          );
        }
        final included = resolved.document.worldNamed(resolved.memberName);
        if (included == null) {
          throw WASIComponentWitTargetResolutionException(
            target.text,
            "world '${resolved.memberName}' does not exist in the resolved document",
          );
        }
        functions.addAll(
          wasiComponentWitWorldFunctions(
            resolved.document,
            included,
            resolveTarget: resolveTarget,
            visiting: active,
            qualifyInterfaceName: resolved.qualifiedInterfaceName,
          ),
        );
        continue;
      }
      final included = document.worldNamed(target.text);
      if (included != null) {
        functions.addAll(
          wasiComponentWitWorldFunctions(
            document,
            included,
            resolveTarget: resolveTarget,
            visiting: active,
            qualifyInterfaceName: qualifyInterfaceName,
          ),
        );
      }
      continue;
    }
    final resolved = target.isQualified
        ? resolveTarget?.call(target.text)
        : null;
    if (target.isQualified && resolved == null) {
      throw WASIComponentWitTargetResolutionException(
        target.text,
        'no resolver result',
      );
    }
    final interfaceDocument = resolved?.document ?? document;
    final interfaceName = resolved?.memberName ?? target.text;
    final interface = interfaceDocument.interfaceNamed(interfaceName);
    if (interface == null) {
      if (target.isQualified) {
        throw WASIComponentWitTargetResolutionException(
          target.text,
          "interface '$interfaceName' does not exist in the resolved document",
        );
      }
      continue;
    }
    final callbackInterfaceName =
        resolved?.qualifiedInterfaceName(interface.name) ??
        qualifyInterfaceName?.call(interface.name) ??
        interface.name;
    for (final function in interface.functions) {
      functions.add(
        WASIComponentWitFunctionBinding._(
          item: item,
          interfaceName: callbackInterfaceName,
          function: function,
          direction: item.direction,
          signature: _parseWitAdapterSignature(
            function,
            interface,
            document: interfaceDocument,
            resolveTarget: resolveTarget,
          ),
        ),
      );
    }
  }
  active.remove(visitKey);
  return List<WASIComponentWitFunctionBinding>.unmodifiable(functions);
}

String _witWorldVisitKey(
  WASIComponentWitDocument document,
  WASIComponentWitWorld world,
) {
  return '${document.package?.text ?? '<local>'}#${world.name}';
}

/// Reports functions that cannot bind to executable adapters.
List<WASIComponentWitAdapterBindingError> wasiComponentWitAdapterBindingErrors(
  List<WASIComponentWitFunctionBinding> functions,
) {
  final errors = <WASIComponentWitAdapterBindingError>[];
  for (final function in functions) {
    final signature = function.signature;
    final reason = signature.unsupportedReason;
    if (reason != null) {
      errors.add(
        WASIComponentWitAdapterBindingError(function: function, reason: reason),
      );
    }
  }
  return List<WASIComponentWitAdapterBindingError>.unmodifiable(errors);
}

/// A WIT interface function expanded from a world boundary.
final class WASIComponentWitFunctionBinding {
  const WASIComponentWitFunctionBinding._({
    required this.item,
    required this.interfaceName,
    required this.function,
    required this.direction,
    required this.signature,
  });

  /// World item that introduced [function].
  final WASIComponentWitWorldItem item;

  /// Local interface name that declares [function].
  final String interfaceName;

  /// WIT function boundary.
  final WASIComponentWitFunction function;

  /// Whether this is an import or export boundary.
  final WASIComponentWitWorldItemDirection direction;

  /// Parsed executable adapter signature.
  final WASIComponentWitAdapterSignature signature;

  /// Stable callback key, such as `filesystem.open-at`.
  String get qualifiedName => '$interfaceName.${function.name}';
}

/// Parsed subset of a WIT function signature that can drive adapters.
final class WASIComponentWitAdapterSignature {
  const WASIComponentWitAdapterSignature._({
    required this.params,
    required this.result,
    required this.isAsync,
    required this.unsupportedReason,
  });

  /// Ordered function parameters.
  final List<WASIComponentWitAdapterParam> params;

  /// Single function result, when declared.
  final WASIComponentWitAdapterValueType? result;

  /// Whether the WIT function uses `async func`.
  final bool isAsync;

  /// Reason this signature cannot be bound by the current executable adapter.
  final String? unsupportedReason;

  /// Whether the signature can be bound as an executable adapter.
  bool get canBind => unsupportedReason == null;
}

/// WIT adapter function parameter.
final class WASIComponentWitAdapterParam {
  /// Creates a WIT adapter function parameter.
  const WASIComponentWitAdapterParam({required this.label, required this.type});

  /// WIT parameter label, when present.
  final String? label;

  /// WIT adapter value type.
  final WASIComponentWitAdapterValueType type;
}

/// WIT value type supported by executable WIT adapters.
final class WASIComponentWitAdapterValueType {
  WASIComponentWitAdapterValueType._({
    required this.kind,
    required this.text,
    this.primitive,
    this.element,
    List<WASIComponentWitAdapterValueType> elements = const [],
    List<WASIComponentWitAdapterRecordField> fields = const [],
    List<String> labels = const [],
    List<WASIComponentWitAdapterVariantCase> cases = const [],
    this.ok,
    this.error,
    this.resourceName,
    this.isBorrowedResource = false,
  }) : elements = List<WASIComponentWitAdapterValueType>.unmodifiable(elements),
       fields = List<WASIComponentWitAdapterRecordField>.unmodifiable(fields),
       labels = List<String>.unmodifiable(labels),
       cases = List<WASIComponentWitAdapterVariantCase>.unmodifiable(cases);

  /// Creates a primitive WIT adapter value type.
  WASIComponentWitAdapterValueType.primitive({
    required String text,
    required WasmComponentPrimitiveValueType primitive,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.primitive,
         text: text,
         primitive: primitive,
       );

  /// Creates an `option<T>` WIT adapter value type.
  WASIComponentWitAdapterValueType.option({
    required String text,
    required WASIComponentWitAdapterValueType element,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.option,
         text: text,
         element: element,
       );

  /// Creates a `list<T>` WIT adapter value type.
  WASIComponentWitAdapterValueType.list({
    required String text,
    required WASIComponentWitAdapterValueType element,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.list,
         text: text,
         element: element,
       );

  /// Creates a `stream<T>` WIT adapter value type.
  WASIComponentWitAdapterValueType.stream({
    required String text,
    required WASIComponentWitAdapterValueType element,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.stream,
         text: text,
         element: element,
       );

  /// Creates a `future<T>` WIT adapter value type.
  WASIComponentWitAdapterValueType.future({
    required String text,
    required WASIComponentWitAdapterValueType element,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.future,
         text: text,
         element: element,
       );

  /// Creates a `tuple<T...>` WIT adapter value type.
  WASIComponentWitAdapterValueType.tuple({
    required String text,
    required List<WASIComponentWitAdapterValueType> elements,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.tuple,
         text: text,
         elements: elements,
       );

  /// Creates a named WIT `record` adapter value type.
  WASIComponentWitAdapterValueType.record({
    required String text,
    required List<WASIComponentWitAdapterRecordField> fields,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.record,
         text: text,
         fields: fields,
       );

  /// Creates a named WIT `flags` adapter value type.
  WASIComponentWitAdapterValueType.flags({
    required String text,
    required List<String> labels,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.flags,
         text: text,
         labels: labels,
       );

  /// Creates a named WIT `enum` adapter value type.
  WASIComponentWitAdapterValueType.enumeration({
    required String text,
    required List<String> labels,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.enumeration,
         text: text,
         labels: labels,
       );

  /// Creates a named WIT `variant` adapter value type.
  WASIComponentWitAdapterValueType.variant({
    required String text,
    required List<WASIComponentWitAdapterVariantCase> cases,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.variant,
         text: text,
         cases: cases,
       );

  /// Creates a local WIT `resource` handle adapter value type.
  WASIComponentWitAdapterValueType.resource({
    required String text,
    required String resourceName,
    required bool isBorrowed,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.resource,
         text: text,
         resourceName: resourceName,
         isBorrowedResource: isBorrowed,
       );

  /// Creates a `result<T, E>` WIT adapter value type.
  WASIComponentWitAdapterValueType.result({
    required String text,
    required WASIComponentWitAdapterValueType? ok,
    required WASIComponentWitAdapterValueType? error,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.result,
         text: text,
         ok: ok,
         error: error,
       );

  /// WIT adapter value category.
  final WASIComponentWitAdapterValueKind kind;

  /// WIT spelling.
  final String text;

  /// Component-model primitive represented by [text], for primitive values.
  final WasmComponentPrimitiveValueType? primitive;

  /// Option payload type.
  final WASIComponentWitAdapterValueType? element;

  /// Tuple element types.
  final List<WASIComponentWitAdapterValueType> elements;

  /// Record field types.
  final List<WASIComponentWitAdapterRecordField> fields;

  /// Labels used by WIT `flags` and `enum` adapter value types.
  final List<String> labels;

  /// Variant case types.
  final List<WASIComponentWitAdapterVariantCase> cases;

  /// Result success payload type.
  final WASIComponentWitAdapterValueType? ok;

  /// Result error payload type.
  final WASIComponentWitAdapterValueType? error;

  /// Local WIT resource name for resource-handle values.
  final String? resourceName;

  /// Whether a resource-handle value is declared as `borrow<T>`.
  final bool isBorrowedResource;
}

/// WIT adapter record field type.
final class WASIComponentWitAdapterRecordField {
  /// Creates a WIT adapter record field type.
  const WASIComponentWitAdapterRecordField({
    required this.name,
    required this.type,
  });

  /// WIT record field name.
  final String name;

  /// WIT record field value type.
  final WASIComponentWitAdapterValueType type;
}

/// WIT adapter variant case type.
final class WASIComponentWitAdapterVariantCase {
  /// Creates a WIT adapter variant case type.
  const WASIComponentWitAdapterVariantCase({
    required this.name,
    required this.type,
  });

  /// WIT variant case name.
  final String name;

  /// Case payload type, if any.
  final WASIComponentWitAdapterValueType? type;
}

/// WIT adapter value category.
enum WASIComponentWitAdapterValueKind {
  /// Primitive WIT scalar/string type.
  primitive,

  /// `option<T>`.
  option,

  /// `list<T>`.
  list,

  /// `stream<T>`.
  stream,

  /// `future<T>`.
  future,

  /// `tuple<T...>`.
  tuple,

  /// Named WIT `record`.
  record,

  /// Named WIT `flags`.
  flags,

  /// Named WIT `enum`.
  enumeration,

  /// Named WIT `variant`.
  variant,

  /// Local WIT resource handle represented by a canonical `u32`.
  resource,

  /// `result`, `result<T>`, or `result<T, E>`.
  result,
}

/// WIT function signature that cannot bind to an executable adapter.
final class WASIComponentWitAdapterBindingError {
  /// Creates a WIT adapter binding error.
  const WASIComponentWitAdapterBindingError({
    required this.function,
    required this.reason,
  });

  /// Function that cannot be bound.
  final WASIComponentWitFunctionBinding function;

  /// Human-readable binding gap.
  final String reason;

  @override
  String toString() => '${function.qualifiedName}: $reason';
}

/// Thrown when a WIT world cannot produce executable adapter bindings.
final class WASIComponentWitAdapterBindingException implements Exception {
  /// Creates an exception from WIT adapter binding [errors].
  WASIComponentWitAdapterBindingException(
    Iterable<WASIComponentWitAdapterBindingError> errors,
  ) : errors = List<WASIComponentWitAdapterBindingError>.unmodifiable(errors);

  /// WIT adapter binding errors.
  final List<WASIComponentWitAdapterBindingError> errors;

  @override
  String toString() {
    final buffer = StringBuffer('WASI component cannot bind WIT adapters');
    for (final error in errors) {
      buffer
        ..write('\n')
        ..write(error);
    }
    return buffer.toString();
  }
}

/// Executable WIT adapter program indexed by import/export function name.
final class WASIComponentWitAdapterProgram {
  WASIComponentWitAdapterProgram._(
    List<WASIComponentWitAdapterOperation> operations,
  ) : operations = List<WASIComponentWitAdapterOperation>.unmodifiable(
        operations,
      ),
      _imports = _indexWitAdapterOperations(
        operations,
        WASIComponentWitWorldItemDirection.import,
      ),
      _exports = _indexWitAdapterOperations(
        operations,
        WASIComponentWitWorldItemDirection.export,
      );

  /// Binds [functions] to executable WIT adapter callbacks.
  factory WASIComponentWitAdapterProgram.bind(
    Iterable<WASIComponentWitFunctionBinding> functions, {
    Map<String, WASIComponentWitAdapterCallback> imports =
        const <String, WASIComponentWitAdapterCallback>{},
    Map<String, WASIComponentWitAdapterCallback> exports =
        const <String, WASIComponentWitAdapterCallback>{},
  }) {
    final operations = <WASIComponentWitAdapterOperation>[];
    for (final function in functions) {
      final callbacks = switch (function.direction) {
        WASIComponentWitWorldItemDirection.import => imports,
        WASIComponentWitWorldItemDirection.export => exports,
        WASIComponentWitWorldItemDirection.include =>
          const <String, WASIComponentWitAdapterCallback>{},
      };
      final callback = callbacks[function.qualifiedName];
      if (callback == null) {
        throw StateError(
          'Missing WIT ${function.direction.name} adapter callback for '
          '${function.qualifiedName}.',
        );
      }
      operations.add(
        WASIComponentWitAdapterOperation._(
          function: function,
          callback: callback,
        ),
      );
    }
    return WASIComponentWitAdapterProgram._(operations);
  }

  /// Adapter operations in expanded world order.
  final List<WASIComponentWitAdapterOperation> operations;

  final Map<String, WASIComponentWitAdapterOperation> _imports;
  final Map<String, WASIComponentWitAdapterOperation> _exports;

  /// Invokes an imported WIT function adapter by qualified name.
  Object? invokeImport(String qualifiedName, List<Object?> args) {
    return _invoke(_imports, 'import', qualifiedName, args);
  }

  /// Invokes an imported WIT function adapter by qualified name asynchronously.
  Future<Object?> invokeImportAsync(String qualifiedName, List<Object?> args) {
    return _invokeAsync(_imports, 'import', qualifiedName, args);
  }

  /// Invokes an exported WIT function adapter by qualified name.
  Object? invokeExport(String qualifiedName, List<Object?> args) {
    return _invoke(_exports, 'export', qualifiedName, args);
  }

  /// Invokes an exported WIT function adapter by qualified name asynchronously.
  Future<Object?> invokeExportAsync(String qualifiedName, List<Object?> args) {
    return _invokeAsync(_exports, 'export', qualifiedName, args);
  }

  Object? _invoke(
    Map<String, WASIComponentWitAdapterOperation> operations,
    String direction,
    String qualifiedName,
    List<Object?> args,
  ) {
    final operation = operations[qualifiedName];
    if (operation == null) {
      throw StateError('Unknown WIT $direction adapter: $qualifiedName.');
    }
    return operation.invoke(args);
  }

  Future<Object?> _invokeAsync(
    Map<String, WASIComponentWitAdapterOperation> operations,
    String direction,
    String qualifiedName,
    List<Object?> args,
  ) {
    final operation = operations[qualifiedName];
    if (operation == null) {
      throw StateError('Unknown WIT $direction adapter: $qualifiedName.');
    }
    return operation.invokeAsync(args);
  }
}

/// Executable WIT adapter operation.
final class WASIComponentWitAdapterOperation {
  const WASIComponentWitAdapterOperation._({
    required this.function,
    required WASIComponentWitAdapterCallback callback,
  }) : _callback = callback;

  /// WIT function boundary this operation executes.
  final WASIComponentWitFunctionBinding function;

  final WASIComponentWitAdapterCallback _callback;

  /// Stable callback key, such as `filesystem.open-at`.
  String get qualifiedName => function.qualifiedName;

  /// Whether this operation is an import or export.
  WASIComponentWitWorldItemDirection get direction => function.direction;

  /// Invokes this adapter with validated WIT values.
  Object? invoke(List<Object?> args) {
    final signature = function.signature;
    if (!signature.canBind) {
      throw StateError(
        'WIT adapter $qualifiedName is not executable: '
        '${signature.unsupportedReason}.',
      );
    }
    if (signature.isAsync) {
      throw StateError('WIT adapter $qualifiedName is async; use invokeAsync.');
    }

    final checkedArgs = _validateArgs(args);
    final result = _callback(List<Object?>.unmodifiable(checkedArgs));
    if (result is Future) {
      throw StateError(
        'WIT adapter $qualifiedName returned a Future; use invokeAsync.',
      );
    }
    return _validateResult(result);
  }

  /// Invokes this adapter asynchronously with validated WIT values.
  Future<Object?> invokeAsync(List<Object?> args) async {
    final signature = function.signature;
    if (!signature.canBind) {
      throw StateError(
        'WIT adapter $qualifiedName is not executable: '
        '${signature.unsupportedReason}.',
      );
    }

    final checkedArgs = _validateArgs(args);
    final result = await _callback(List<Object?>.unmodifiable(checkedArgs));
    return _validateResult(result);
  }

  List<Object?> _validateArgs(List<Object?> args) {
    final signature = function.signature;
    if (args.length != signature.params.length) {
      throw StateError(
        'WIT adapter $qualifiedName expected ${signature.params.length} '
        'arguments, got ${args.length}.',
      );
    }
    final checkedArgs = <Object?>[];
    for (var i = 0; i < signature.params.length; i++) {
      final param = signature.params[i];
      checkedArgs.add(
        _validateWitAdapterValue(
          param.type,
          args[i],
          '$qualifiedName.${param.label ?? 'param[$i]'}',
        ),
      );
    }
    return checkedArgs;
  }

  Object? _validateResult(Object? result) {
    final signature = function.signature;
    final resultType = signature.result;
    if (resultType == null) {
      if (result != null) {
        throw StateError('WIT adapter $qualifiedName expected no result.');
      }
      return null;
    }
    return _validateWitAdapterValue(
      resultType,
      result,
      '$qualifiedName.result',
    );
  }
}

WASIComponentWitAdapterSignature _parseWitAdapterSignature(
  WASIComponentWitFunction function,
  WASIComponentWitInterface interface, {
  required WASIComponentWitDocument document,
  WASIComponentWitTargetResolver? resolveTarget,
}) {
  final signature = function.signature;
  final isAsync = signature.startsWith('asyncfunc');
  final prefix = isAsync ? 'asyncfunc' : 'func';
  final typeContext = _WitAdapterTypeContext(
    document: document,
    interface: interface,
    resolveTarget: resolveTarget,
  );
  if (signature == prefix) {
    return WASIComponentWitAdapterSignature._(
      params: const <WASIComponentWitAdapterParam>[],
      result: null,
      isAsync: isAsync,
      unsupportedReason: null,
    );
  }
  if (!signature.startsWith('$prefix(')) {
    return _unsupportedWitAdapterSignature(
      isAsync: isAsync,
      reason: 'unsupported WIT function signature ${function.signature}',
    );
  }
  final paramsStart = prefix.length + 1;
  final paramsEnd = _findMatchingParen(signature, paramsStart - 1);
  if (paramsEnd == null) {
    return _unsupportedWitAdapterSignature(
      isAsync: isAsync,
      reason: 'unterminated WIT function parameter list',
    );
  }
  final suffix = signature.substring(paramsEnd + 1);
  WASIComponentWitAdapterValueType? result;
  if (suffix.isNotEmpty) {
    if (!suffix.startsWith('->')) {
      return _unsupportedWitAdapterSignature(
        isAsync: isAsync,
        reason: 'unsupported WIT function result suffix $suffix',
      );
    }
    final parsedResult = _parseWitAdapterValueType(
      suffix.substring(2),
      'result',
      typeContext,
    );
    if (parsedResult.error != null) {
      return _unsupportedWitAdapterSignature(
        isAsync: isAsync,
        reason: parsedResult.error!,
      );
    }
    result = parsedResult.type;
  }

  final params = <WASIComponentWitAdapterParam>[];
  final paramsText = signature.substring(paramsStart, paramsEnd);
  if (paramsText.isNotEmpty) {
    for (final paramText in _splitWitTopLevel(paramsText, ',')) {
      if (paramText.isEmpty) {
        continue;
      }
      final colon = _findWitTopLevelSymbol(paramText, ':');
      final label = colon == null ? null : paramText.substring(0, colon);
      final typeText = colon == null
          ? paramText
          : paramText.substring(colon + 1);
      if (label != null && label.isEmpty) {
        return _unsupportedWitAdapterSignature(
          isAsync: isAsync,
          reason: 'empty WIT function parameter label',
        );
      }
      final parsedType = _parseWitAdapterValueType(
        typeText,
        'parameter',
        typeContext,
      );
      if (parsedType.error != null) {
        return _unsupportedWitAdapterSignature(
          isAsync: isAsync,
          reason: parsedType.error!,
        );
      }
      params.add(
        WASIComponentWitAdapterParam(label: label, type: parsedType.type!),
      );
    }
  }

  return WASIComponentWitAdapterSignature._(
    params: List<WASIComponentWitAdapterParam>.unmodifiable(params),
    result: result,
    isAsync: isAsync,
    unsupportedReason: null,
  );
}

WASIComponentWitAdapterSignature _unsupportedWitAdapterSignature({
  required bool isAsync,
  required String reason,
}) {
  return WASIComponentWitAdapterSignature._(
    params: const <WASIComponentWitAdapterParam>[],
    result: null,
    isAsync: isAsync,
    unsupportedReason: reason,
  );
}

final class _WitAdapterTypeContext {
  const _WitAdapterTypeContext({
    required this.document,
    required this.interface,
    required this.resolveTarget,
  });

  final WASIComponentWitDocument document;
  final WASIComponentWitInterface interface;
  final WASIComponentWitTargetResolver? resolveTarget;

  _WitAdapterTypeContext withInterface(
    WASIComponentWitDocument nextDocument,
    WASIComponentWitInterface nextInterface,
  ) {
    return _WitAdapterTypeContext(
      document: nextDocument,
      interface: nextInterface,
      resolveTarget: resolveTarget,
    );
  }

  String get visitPrefix =>
      '${document.package?.text ?? '<local>'}'
      '/${interface.name}';
}

({WASIComponentWitAdapterValueType? type, String? error})
_parseWitAdapterValueType(
  String text,
  String context,
  _WitAdapterTypeContext typeContext, [
  Set<String>? visitingTypes,
]) {
  final primitive = _witPrimitiveValueType(text);
  if (primitive != null) {
    return (
      type: WASIComponentWitAdapterValueType.primitive(
        text: text,
        primitive: primitive,
      ),
      error: null,
    );
  }
  final optionArgs = _genericArgs('option', text);
  if (optionArgs != null) {
    if (optionArgs.length != 1 || optionArgs.single.isEmpty) {
      return (type: null, error: 'unsupported WIT adapter $context type $text');
    }
    final element = _parseWitAdapterValueType(
      optionArgs.single,
      '$context option payload',
      typeContext,
      visitingTypes,
    );
    if (element.error != null) {
      return (type: null, error: element.error);
    }
    return (
      type: WASIComponentWitAdapterValueType.option(
        text: text,
        element: element.type!,
      ),
      error: null,
    );
  }
  final listArgs = _genericArgs('list', text);
  if (listArgs != null) {
    if (listArgs.length != 1 || listArgs.single.isEmpty) {
      return (type: null, error: 'unsupported WIT adapter $context type $text');
    }
    final element = _parseWitAdapterValueType(
      listArgs.single,
      '$context list element',
      typeContext,
      visitingTypes,
    );
    if (element.error != null) {
      return (type: null, error: element.error);
    }
    return (
      type: WASIComponentWitAdapterValueType.list(
        text: text,
        element: element.type!,
      ),
      error: null,
    );
  }
  final streamArgs = _genericArgs('stream', text);
  if (streamArgs != null) {
    final element = _parseWitAdapterAsyncElementValueType(
      text,
      streamArgs,
      '$context stream element',
      typeContext,
      visitingTypes,
    );
    if (element.error != null) {
      return (type: null, error: element.error);
    }
    return (
      type: WASIComponentWitAdapterValueType.stream(
        text: text,
        element: element.type!,
      ),
      error: null,
    );
  }
  final futureArgs = _genericArgs('future', text);
  if (futureArgs != null) {
    final element = _parseWitAdapterAsyncElementValueType(
      text,
      futureArgs,
      '$context future element',
      typeContext,
      visitingTypes,
    );
    if (element.error != null) {
      return (type: null, error: element.error);
    }
    return (
      type: WASIComponentWitAdapterValueType.future(
        text: text,
        element: element.type!,
      ),
      error: null,
    );
  }
  final tupleArgs = _genericArgs('tuple', text);
  if (tupleArgs != null) {
    if (tupleArgs.isEmpty || tupleArgs.any((arg) => arg.isEmpty)) {
      return (type: null, error: 'unsupported WIT adapter $context type $text');
    }
    final elements = <WASIComponentWitAdapterValueType>[];
    for (var i = 0; i < tupleArgs.length; i++) {
      final element = _parseWitAdapterValueType(
        tupleArgs[i],
        '$context tuple element[$i]',
        typeContext,
        visitingTypes,
      );
      if (element.error != null) {
        return (type: null, error: element.error);
      }
      elements.add(element.type!);
    }
    return (
      type: WASIComponentWitAdapterValueType.tuple(
        text: text,
        elements: elements,
      ),
      error: null,
    );
  }
  if (text == 'result') {
    return (
      type: WASIComponentWitAdapterValueType.result(
        text: text,
        ok: null,
        error: null,
      ),
      error: null,
    );
  }
  final resultArgs = _genericArgs('result', text);
  if (resultArgs != null) {
    if (resultArgs.isEmpty || resultArgs.length > 2) {
      return (type: null, error: 'unsupported WIT adapter $context type $text');
    }
    final ok = _parseOptionalWitAdapterValueType(
      resultArgs[0],
      '$context result ok payload',
      typeContext,
      visitingTypes,
    );
    if (ok.error != null) {
      return (type: null, error: ok.error);
    }
    final error = resultArgs.length == 1
        ? (type: null, error: null)
        : _parseOptionalWitAdapterValueType(
            resultArgs[1],
            '$context result error payload',
            typeContext,
            visitingTypes,
          );
    if (error.error != null) {
      return (type: null, error: error.error);
    }
    return (
      type: WASIComponentWitAdapterValueType.result(
        text: text,
        ok: ok.type,
        error: error.type,
      ),
      error: null,
    );
  }
  final borrowedResourceArgs = _genericArgs('borrow', text);
  if (borrowedResourceArgs != null) {
    return _parseWitAdapterResourceValueType(
      text,
      borrowedResourceArgs,
      context,
      typeContext,
      isBorrowed: true,
    );
  }
  final alias = typeContext.interface.typeAliasNamed(text);
  if (alias != null) {
    final visiting = visitingTypes ?? <String>{};
    final typeKey = '${typeContext.visitPrefix}:alias:${alias.name}';
    if (!visiting.add(typeKey)) {
      return (
        type: null,
        error: 'unsupported recursive WIT adapter $context type $text',
      );
    }
    final parsed = _parseWitAdapterValueType(
      alias.target,
      '$context alias ${alias.name}',
      typeContext,
      visiting,
    );
    visiting.remove(typeKey);
    return parsed;
  }
  final record = typeContext.interface.recordNamed(text);
  if (record != null) {
    final visiting = visitingTypes ?? <String>{};
    final typeKey = '${typeContext.visitPrefix}:record:${record.name}';
    if (!visiting.add(typeKey)) {
      return (
        type: null,
        error: 'unsupported recursive WIT adapter $context type $text',
      );
    }
    final fields = <WASIComponentWitAdapterRecordField>[];
    for (final field in record.fields) {
      final parsedField = _parseWitAdapterValueType(
        field.type,
        '$context record ${record.name}.${field.name}',
        typeContext,
        visiting,
      );
      if (parsedField.error != null) {
        visiting.remove(typeKey);
        return (type: null, error: parsedField.error);
      }
      fields.add(
        WASIComponentWitAdapterRecordField(
          name: field.name,
          type: parsedField.type!,
        ),
      );
    }
    visiting.remove(typeKey);
    return (
      type: WASIComponentWitAdapterValueType.record(text: text, fields: fields),
      error: null,
    );
  }
  final flags = typeContext.interface.flagsNamed(text);
  if (flags != null) {
    return (
      type: WASIComponentWitAdapterValueType.flags(
        text: text,
        labels: [for (final label in flags.labels) label.name],
      ),
      error: null,
    );
  }
  final enum_ = typeContext.interface.enumNamed(text);
  if (enum_ != null) {
    return (
      type: WASIComponentWitAdapterValueType.enumeration(
        text: text,
        labels: [for (final case_ in enum_.cases) case_.name],
      ),
      error: null,
    );
  }
  final variant = typeContext.interface.variantNamed(text);
  if (variant != null) {
    final visiting = visitingTypes ?? <String>{};
    final typeKey = '${typeContext.visitPrefix}:variant:${variant.name}';
    if (!visiting.add(typeKey)) {
      return (
        type: null,
        error: 'unsupported recursive WIT adapter $context type $text',
      );
    }
    final cases = <WASIComponentWitAdapterVariantCase>[];
    for (final case_ in variant.cases) {
      final caseType = case_.type == null
          ? (type: null, error: null)
          : _parseWitAdapterValueType(
              case_.type!,
              '$context variant ${variant.name}.${case_.name}',
              typeContext,
              visiting,
            );
      if (caseType.error != null) {
        visiting.remove(typeKey);
        return (type: null, error: caseType.error);
      }
      cases.add(
        WASIComponentWitAdapterVariantCase(
          name: case_.name,
          type: caseType.type,
        ),
      );
    }
    visiting.remove(typeKey);
    return (
      type: WASIComponentWitAdapterValueType.variant(text: text, cases: cases),
      error: null,
    );
  }
  final resource = typeContext.interface.resourceNamed(text);
  if (resource != null) {
    return (
      type: WASIComponentWitAdapterValueType.resource(
        text: text,
        resourceName: resource.name,
        isBorrowed: false,
      ),
      error: null,
    );
  }
  final used = _parseWitAdapterUsedValueType(
    text,
    context,
    typeContext,
    visitingTypes,
  );
  if (used.type != null || used.error != null) {
    return used;
  }
  return (type: null, error: 'unsupported WIT adapter $context type $text');
}

({WASIComponentWitAdapterValueType? type, String? error})
_parseWitAdapterUsedValueType(
  String text,
  String context,
  _WitAdapterTypeContext typeContext, [
  Set<String>? visitingTypes,
]) {
  final used = typeContext.interface.useItemNamed(text);
  if (used == null) {
    return (type: null, error: null);
  }
  final resolved = _resolveWitAdapterUsedInterface(typeContext, used.target);
  if (resolved == null) {
    return (
      type: null,
      error:
          'unknown WIT adapter $context used type ${used.target.text}.'
          '${used.name}',
    );
  }
  final usedContext = typeContext.withInterface(
    resolved.document,
    resolved.interface,
  );
  final visiting = visitingTypes ?? <String>{};
  final typeKey = '${usedContext.visitPrefix}:use:${used.name}';
  if (!visiting.add(typeKey)) {
    return (
      type: null,
      error: 'unsupported recursive WIT adapter $context type $text',
    );
  }
  final parsed = _parseWitAdapterValueType(
    used.name,
    '$context use ${used.target.text}.${used.name}',
    usedContext,
    visiting,
  );
  visiting.remove(typeKey);
  if (parsed.type == null || used.alias == used.name) {
    return parsed;
  }
  final type = parsed.type!;
  if (type.kind == WASIComponentWitAdapterValueKind.resource) {
    return (
      type: WASIComponentWitAdapterValueType.resource(
        text: text,
        resourceName: used.alias,
        isBorrowed: type.isBorrowedResource,
      ),
      error: null,
    );
  }
  return parsed;
}

({WASIComponentWitAdapterValueType? type, String? error})
_parseWitAdapterUsedResourceValueType(
  String text,
  String resourceName,
  String context,
  _WitAdapterTypeContext typeContext, {
  required bool isBorrowed,
}) {
  final used = typeContext.interface.useItemNamed(resourceName);
  if (used == null) {
    return (type: null, error: null);
  }
  final resolved = _resolveWitAdapterUsedInterface(typeContext, used.target);
  if (resolved == null) {
    return (
      type: null,
      error:
          'unknown WIT adapter $context used resource ${used.target.text}.'
          '${used.name}',
    );
  }
  if (resolved.interface.resourceNamed(used.name) == null) {
    return (
      type: null,
      error: 'unknown WIT adapter $context resource type $resourceName',
    );
  }
  return (
    type: WASIComponentWitAdapterValueType.resource(
      text: text,
      resourceName: used.alias,
      isBorrowed: isBorrowed,
    ),
    error: null,
  );
}

({WASIComponentWitDocument document, WASIComponentWitInterface interface})?
_resolveWitAdapterUsedInterface(
  _WitAdapterTypeContext typeContext,
  WASIComponentWitTarget target,
) {
  if (target.isLocal) {
    final interface = typeContext.document.interfaceNamed(target.text);
    return interface == null
        ? null
        : (document: typeContext.document, interface: interface);
  }
  final resolved = typeContext.resolveTarget?.call(target.text);
  if (resolved == null) {
    return null;
  }
  final interface = resolved.document.interfaceNamed(resolved.memberName);
  return interface == null
      ? null
      : (document: resolved.document, interface: interface);
}

({WASIComponentWitAdapterValueType? type, String? error})
_parseWitAdapterAsyncElementValueType(
  String text,
  List<String> args,
  String context,
  _WitAdapterTypeContext typeContext, [
  Set<String>? visitingTypes,
]) {
  if (args.length != 1 || args.single.isEmpty) {
    return (type: null, error: 'unsupported WIT adapter $context type $text');
  }
  final element = _parseWitAdapterValueType(
    args.single,
    context,
    typeContext,
    visitingTypes,
  );
  if (element.error != null) {
    return (type: null, error: element.error);
  }
  if (_containsWitAdapterAsyncValueType(element.type!)) {
    return (
      type: null,
      error: 'unsupported nested async WIT adapter $context type $text',
    );
  }
  return element;
}

bool _containsWitAdapterAsyncValueType(WASIComponentWitAdapterValueType type) {
  switch (type.kind) {
    case WASIComponentWitAdapterValueKind.stream:
    case WASIComponentWitAdapterValueKind.future:
      return true;
    case WASIComponentWitAdapterValueKind.option:
    case WASIComponentWitAdapterValueKind.list:
      return _containsWitAdapterAsyncValueType(type.element!);
    case WASIComponentWitAdapterValueKind.tuple:
      return type.elements.any(_containsWitAdapterAsyncValueType);
    case WASIComponentWitAdapterValueKind.record:
      return type.fields.any(
        (field) => _containsWitAdapterAsyncValueType(field.type),
      );
    case WASIComponentWitAdapterValueKind.variant:
      return type.cases.any((case_) {
        final caseType = case_.type;
        return caseType != null && _containsWitAdapterAsyncValueType(caseType);
      });
    case WASIComponentWitAdapterValueKind.result:
      final ok = type.ok;
      final error = type.error;
      return (ok != null && _containsWitAdapterAsyncValueType(ok)) ||
          (error != null && _containsWitAdapterAsyncValueType(error));
    case WASIComponentWitAdapterValueKind.primitive:
    case WASIComponentWitAdapterValueKind.flags:
    case WASIComponentWitAdapterValueKind.enumeration:
    case WASIComponentWitAdapterValueKind.resource:
      return false;
  }
}

({WASIComponentWitAdapterValueType? type, String? error})
_parseWitAdapterResourceValueType(
  String text,
  List<String> args,
  String context,
  _WitAdapterTypeContext typeContext, {
  required bool isBorrowed,
}) {
  if (args.length != 1 || args.single.isEmpty) {
    return (type: null, error: 'unsupported WIT adapter $context type $text');
  }
  final resource = typeContext.interface.resourceNamed(args.single);
  if (resource == null) {
    final usedResource = _parseWitAdapterUsedResourceValueType(
      text,
      args.single,
      context,
      typeContext,
      isBorrowed: isBorrowed,
    );
    if (usedResource.type != null || usedResource.error != null) {
      return usedResource;
    }
    return (
      type: null,
      error: 'unknown WIT adapter $context resource type ${args.single}',
    );
  }
  return (
    type: WASIComponentWitAdapterValueType.resource(
      text: text,
      resourceName: resource.name,
      isBorrowed: isBorrowed,
    ),
    error: null,
  );
}

({WASIComponentWitAdapterValueType? type, String? error})
_parseOptionalWitAdapterValueType(
  String text,
  String context,
  _WitAdapterTypeContext typeContext, [
  Set<String>? visitingTypes,
]) {
  if (text == '_' || text.isEmpty) {
    return (type: null, error: null);
  }
  return _parseWitAdapterValueType(text, context, typeContext, visitingTypes);
}

List<String>? _genericArgs(String name, String text) {
  final prefix = '$name<';
  if (!text.startsWith(prefix) || !text.endsWith('>')) {
    return null;
  }
  final close = _findMatchingAngle(text, name.length);
  if (close != text.length - 1) {
    return null;
  }
  final body = text.substring(prefix.length, close);
  return _splitWitTopLevel(body, ',');
}

int? _findMatchingAngle(String text, int openIndex) {
  var depth = 0;
  for (var i = openIndex; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (code == 60) {
      depth++;
    } else if (code == 62) {
      depth--;
      if (depth == 0) {
        return i;
      }
    }
  }
  return null;
}

WasmComponentPrimitiveValueType? _witPrimitiveValueType(String text) {
  return switch (text) {
    'bool' => WasmComponentPrimitiveValueType.boolean,
    's8' => WasmComponentPrimitiveValueType.s8,
    'u8' => WasmComponentPrimitiveValueType.u8,
    's16' => WasmComponentPrimitiveValueType.s16,
    'u16' => WasmComponentPrimitiveValueType.u16,
    's32' => WasmComponentPrimitiveValueType.s32,
    'u32' => WasmComponentPrimitiveValueType.u32,
    's64' => WasmComponentPrimitiveValueType.s64,
    'u64' => WasmComponentPrimitiveValueType.u64,
    'float32' || 'f32' => WasmComponentPrimitiveValueType.f32,
    'float64' || 'f64' => WasmComponentPrimitiveValueType.f64,
    'char' => WasmComponentPrimitiveValueType.char,
    'string' => WasmComponentPrimitiveValueType.string,
    _ => null,
  };
}

int? _findMatchingParen(String text, int openIndex) {
  var depth = 0;
  for (var i = openIndex; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (code == 40) {
      depth++;
    } else if (code == 41) {
      depth--;
      if (depth == 0) {
        return i;
      }
    }
  }
  return null;
}

List<String> _splitWitTopLevel(String text, String separator) {
  final parts = <String>[];
  var start = 0;
  var angleDepth = 0;
  var parenDepth = 0;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == '<') {
      angleDepth++;
    } else if (char == '>' && angleDepth > 0) {
      angleDepth--;
    } else if (char == '(') {
      parenDepth++;
    } else if (char == ')' && parenDepth > 0) {
      parenDepth--;
    } else if (char == separator && angleDepth == 0 && parenDepth == 0) {
      parts.add(text.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(text.substring(start));
  return parts;
}

int? _findWitTopLevelSymbol(String text, String symbol) {
  var angleDepth = 0;
  var parenDepth = 0;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == '<') {
      angleDepth++;
    } else if (char == '>' && angleDepth > 0) {
      angleDepth--;
    } else if (char == '(') {
      parenDepth++;
    } else if (char == ')' && parenDepth > 0) {
      parenDepth--;
    } else if (char == symbol && angleDepth == 0 && parenDepth == 0) {
      return i;
    }
  }
  return null;
}

Map<String, WASIComponentWitAdapterOperation> _indexWitAdapterOperations(
  List<WASIComponentWitAdapterOperation> operations,
  WASIComponentWitWorldItemDirection direction,
) {
  final byName = <String, WASIComponentWitAdapterOperation>{};
  for (final operation in operations) {
    if (operation.direction != direction) {
      continue;
    }
    final existing = byName[operation.qualifiedName];
    if (existing != null) {
      throw StateError(
        'Duplicate WIT ${direction.name} adapter: ${operation.qualifiedName}.',
      );
    }
    byName[operation.qualifiedName] = operation;
  }
  return Map<String, WASIComponentWitAdapterOperation>.unmodifiable(byName);
}

Object? _validateWitAdapterValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  switch (type.kind) {
    case WASIComponentWitAdapterValueKind.primitive:
      return _validateWitAdapterPrimitiveValue(
        type.primitive!,
        type.text,
        value,
        path,
      );
    case WASIComponentWitAdapterValueKind.option:
      return _validateWitAdapterOptionValue(type, value, path);
    case WASIComponentWitAdapterValueKind.list:
      return _validateWitAdapterListValue(type, value, path);
    case WASIComponentWitAdapterValueKind.stream:
      return _validateWitAdapterStreamValue(type, value, path);
    case WASIComponentWitAdapterValueKind.future:
      return _validateWitAdapterFutureValue(type, value, path);
    case WASIComponentWitAdapterValueKind.tuple:
      return _validateWitAdapterTupleValue(type, value, path);
    case WASIComponentWitAdapterValueKind.record:
      return _validateWitAdapterRecordValue(type, value, path);
    case WASIComponentWitAdapterValueKind.flags:
      return _validateWitAdapterFlagsValue(type, value, path);
    case WASIComponentWitAdapterValueKind.enumeration:
      return _validateWitAdapterEnumValue(type, value, path);
    case WASIComponentWitAdapterValueKind.variant:
      return _validateWitAdapterVariantValue(type, value, path);
    case WASIComponentWitAdapterValueKind.resource:
      return _validateWitAdapterResourceValue(type, value, path);
    case WASIComponentWitAdapterValueKind.result:
      return _validateWitAdapterResultValue(type, value, path);
  }
}

Object? _validateWitAdapterStreamValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  if (value is WASIComponentStream || value is WASIComponentReadableStream) {
    return value;
  }
  throw StateError('WIT adapter value $path does not match ${type.text}.');
}

Object? _validateWitAdapterFutureValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  if (value is WASIComponentFuture || value is WASIComponentReadableFuture) {
    return value;
  }
  throw StateError('WIT adapter value $path does not match ${type.text}.');
}

Object? _validateWitAdapterPrimitiveValue(
  WasmComponentPrimitiveValueType primitive,
  String text,
  Object? value,
  String path,
) {
  final directValue = _directPrimitiveValue(primitive, value);
  switch (primitive) {
    case WasmComponentPrimitiveValueType.boolean:
      if (directValue is bool) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.s8:
      if (_isIntInRange(directValue, -0x80, 0x7f)) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.u8:
      if (_isIntInRange(directValue, 0, 0xff)) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.s16:
      if (_isIntInRange(directValue, -0x8000, 0x7fff)) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.u16:
      if (_isIntInRange(directValue, 0, 0xffff)) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.s32:
      if (_isIntInRange(directValue, -0x80000000, 0x7fffffff)) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.u32:
      if (_isIntInRange(directValue, 0, 0xffffffff)) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.s64:
      if (_isBigIntInRange(directValue, _s64Min, _s64Max)) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.u64:
      if (_isBigIntInRange(directValue, BigInt.zero, _u64Max)) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.f32:
    case WasmComponentPrimitiveValueType.f64:
      if (directValue is num) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.char:
      if (singleWASIComponentUnicodeScalar(directValue) != null) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.string:
      if (directValue is String) {
        return directValue;
      }
      break;
    case WasmComponentPrimitiveValueType.errorContext:
      break;
  }
  throw StateError('WIT adapter value $path does not match $text.');
}

Object? _directPrimitiveValue(
  WasmComponentPrimitiveValueType primitive,
  Object? value,
) {
  if (value is! WasmComponentValueData) {
    return value;
  }
  switch (primitive) {
    case WasmComponentPrimitiveValueType.boolean:
      return value.kind == WasmComponentValueDataKind.boolean
          ? value.boolean
          : null;
    case WasmComponentPrimitiveValueType.s8:
    case WasmComponentPrimitiveValueType.u8:
    case WasmComponentPrimitiveValueType.s16:
    case WasmComponentPrimitiveValueType.u16:
    case WasmComponentPrimitiveValueType.s32:
    case WasmComponentPrimitiveValueType.u32:
    case WasmComponentPrimitiveValueType.s64:
    case WasmComponentPrimitiveValueType.u64:
      return value.kind == WasmComponentValueDataKind.integer
          ? value.integer
          : null;
    case WasmComponentPrimitiveValueType.f32:
    case WasmComponentPrimitiveValueType.f64:
      return value.kind == WasmComponentValueDataKind.floatingPoint
          ? value.floatingPoint
          : null;
    case WasmComponentPrimitiveValueType.char:
    case WasmComponentPrimitiveValueType.string:
      return value.kind == WasmComponentValueDataKind.string
          ? value.string
          : null;
    case WasmComponentPrimitiveValueType.errorContext:
      return null;
  }
}

Object? _validateWitAdapterOptionValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.option) {
    throw StateError('WIT adapter value $path does not match ${type.text}.');
  }
  final isSome = _witOptionIsSome(value, path);
  final associated = value.payload;
  if (!isSome) {
    if (associated != null) {
      throw StateError('WIT adapter value $path.none does not take payload.');
    }
    return value;
  }
  if (associated == null) {
    throw StateError('WIT adapter value $path.some needs payload.');
  }
  _validateWitAdapterValue(type.element!, associated, '$path.some');
  return value;
}

Object? _validateWitAdapterListValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.list) {
    throw StateError('WIT adapter value $path does not match ${type.text}.');
  }
  final elementType = type.element!;
  final items = value.itemValues;
  for (var i = 0; i < items.length; i++) {
    _validateWitAdapterValue(elementType, items[i], '$path[$i]');
  }
  return value;
}

Object? _validateWitAdapterTupleValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  final items = switch (value) {
    WasmComponentValueData(kind: WasmComponentValueDataKind.tuple) =>
      value.itemValues,
    List<Object?>() => value,
    _ => null,
  };
  if (items == null) {
    throw StateError('WIT adapter value $path does not match ${type.text}.');
  }
  final elements = type.elements;
  if (items.length != elements.length) {
    throw StateError(
      'WIT adapter value $path expected ${elements.length} tuple fields, '
      'got ${items.length}.',
    );
  }
  for (var i = 0; i < elements.length; i++) {
    _validateWitAdapterValue(elements[i], items[i], '$path.$i');
  }
  return value;
}

Object? _validateWitAdapterRecordValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.record) {
    throw StateError('WIT adapter value $path does not match ${type.text}.');
  }
  final fields = type.fields;
  final items = value.itemValues;
  if (items.length != fields.length) {
    throw StateError(
      'WIT adapter value $path expected ${fields.length} record fields, '
      'got ${items.length}.',
    );
  }
  for (var i = 0; i < fields.length; i++) {
    final field = fields[i];
    _validateWitAdapterValue(field.type, items[i], '$path.${field.name}');
  }
  return value;
}

Object? _validateWitAdapterFlagsValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.flags) {
    throw StateError('WIT adapter value $path does not match ${type.text}.');
  }
  final seen = <String>{};
  for (final label in value.labels) {
    if (!seen.add(label)) {
      throw StateError('WIT adapter value $path has duplicate flag $label.');
    }
    if (!type.labels.contains(label)) {
      throw StateError('WIT adapter value $path has unknown flag $label.');
    }
  }
  return value;
}

Object? _validateWitAdapterEnumValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.enumeration) {
    throw StateError('WIT adapter value $path does not match ${type.text}.');
  }
  _witCaseIndex(type.labels, value, path, 'enum');
  return value;
}

Object? _validateWitAdapterVariantValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.variant) {
    throw StateError('WIT adapter value $path does not match ${type.text}.');
  }
  final labels = [for (final case_ in type.cases) case_.name];
  final index = _witCaseIndex(labels, value, path, 'variant');
  final case_ = type.cases[index];
  final associated = value.payload;
  final payloadType = case_.type;
  if (payloadType == null) {
    if (associated != null) {
      throw StateError(
        'WIT adapter value $path.${case_.name} does not take payload.',
      );
    }
    return value;
  }
  if (associated == null) {
    throw StateError('WIT adapter value $path.${case_.name} needs payload.');
  }
  _validateWitAdapterValue(payloadType, associated, '$path.${case_.name}');
  return value;
}

Object? _validateWitAdapterResultValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.result) {
    throw StateError('WIT adapter value $path does not match ${type.text}.');
  }
  final isOk = _witResultIsOk(value, path);
  final payloadType = isOk ? type.ok : type.error;
  final label = isOk ? 'ok' : 'error';
  final associated = value.payload;
  if (payloadType == null) {
    if (associated != null) {
      throw StateError('WIT adapter value $path.$label does not take payload.');
    }
    return value;
  }
  if (associated == null) {
    throw StateError('WIT adapter value $path.$label needs payload.');
  }
  _validateWitAdapterValue(payloadType, associated, '$path.$label');
  return value;
}

Object? _validateWitAdapterResourceValue(
  WASIComponentWitAdapterValueType type,
  Object? value,
  String path,
) {
  return _validateWitAdapterPrimitiveValue(
    WasmComponentPrimitiveValueType.u32,
    type.text,
    value,
    path,
  );
}

int _witCaseIndex(
  List<String> labels,
  WasmComponentValueData value,
  String path,
  String kind,
) {
  int? selected;
  void select(int next, String source) {
    if (selected != null && selected != next) {
      throw StateError(
        'WIT adapter value $path has conflicting $kind $source.',
      );
    }
    selected = next;
  }

  final index = value.index;
  if (index != null) {
    if (index < 0 || index >= labels.length) {
      throw StateError(
        'WIT adapter value $path has invalid $kind index $index.',
      );
    }
    select(index, 'index');
  }
  final label = value.label;
  if (label != null) {
    final labelIndex = labels.indexOf(label);
    if (labelIndex < 0) {
      throw StateError(
        'WIT adapter value $path has invalid $kind label $label.',
      );
    }
    select(labelIndex, 'label');
  }
  final result = selected;
  if (result == null) {
    throw StateError('WIT adapter value $path needs a $kind case.');
  }
  return result;
}

bool _witOptionIsSome(WasmComponentValueData value, String path) {
  bool? selected;
  void select(bool next, String source) {
    if (selected != null && selected != next) {
      throw StateError(
        'WIT adapter value $path has conflicting option $source.',
      );
    }
    selected = next;
  }

  final isSome = value.isSome;
  if (isSome != null) {
    select(isSome, 'isSome');
  }
  final index = value.index;
  if (index != null) {
    if (index == 0) {
      select(false, 'index');
    } else if (index == 1) {
      select(true, 'index');
    } else {
      throw StateError(
        'WIT adapter value $path has invalid option index $index.',
      );
    }
  }
  final label = value.label;
  if (label != null) {
    if (label == 'none') {
      select(false, 'label');
    } else if (label == 'some') {
      select(true, 'label');
    } else {
      throw StateError(
        'WIT adapter value $path has invalid option label $label.',
      );
    }
  }
  final result = selected;
  if (result == null) {
    throw StateError('WIT adapter value $path needs an option case.');
  }
  return result;
}

bool _witResultIsOk(WasmComponentValueData value, String path) {
  bool? selected;
  void select(bool next, String source) {
    if (selected != null && selected != next) {
      throw StateError(
        'WIT adapter value $path has conflicting result $source.',
      );
    }
    selected = next;
  }

  final isOk = value.isOk;
  if (isOk != null) {
    select(isOk, 'isOk');
  }
  final index = value.index;
  if (index != null) {
    if (index == 0) {
      select(true, 'index');
    } else if (index == 1) {
      select(false, 'index');
    } else {
      throw StateError(
        'WIT adapter value $path has invalid result index $index.',
      );
    }
  }
  final label = value.label;
  if (label != null) {
    if (label == 'ok') {
      select(true, 'label');
    } else if (label == 'error') {
      select(false, 'label');
    } else {
      throw StateError(
        'WIT adapter value $path has invalid result label $label.',
      );
    }
  }
  final result = selected;
  if (result == null) {
    throw StateError('WIT adapter value $path needs a result case.');
  }
  return result;
}

bool _isIntInRange(Object? value, int min, int max) {
  return value is int && value >= min && value <= max;
}

bool _isBigIntInRange(Object? value, BigInt min, BigInt max) {
  final integer = switch (value) {
    int() => BigInt.from(value),
    BigInt() => value,
    _ => null,
  };
  return integer != null && integer >= min && integer <= max;
}

final BigInt _s64Min = -(BigInt.one << 63);
final BigInt _s64Max = (BigInt.one << 63) - BigInt.one;
final BigInt _u64Max = (BigInt.one << 64) - BigInt.one;
