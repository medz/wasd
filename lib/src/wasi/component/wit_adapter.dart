import '../../wasm/backend/native/interpreter/component.dart';
import 'unicode_scalar.dart';
import 'wit_document.dart';

/// Callback used by generated WIT adapter operations.
typedef WASIComponentWitAdapterCallback = Object? Function(List<Object?> args);

/// Expands local WIT import/export interface functions from [world].
List<WASIComponentWitFunctionBinding> wasiComponentWitWorldFunctions(
  WASIComponentWitDocument document,
  WASIComponentWitWorld world, [
  Set<String>? visiting,
]) {
  final active = visiting ?? <String>{};
  if (!active.add(world.name)) {
    return const <WASIComponentWitFunctionBinding>[];
  }
  final functions = <WASIComponentWitFunctionBinding>[];
  for (final item in world.items) {
    final target = item.target;
    if (target.isQualified) {
      continue;
    }
    if (item.direction == WASIComponentWitWorldItemDirection.include) {
      final included = document.worldNamed(target.text);
      if (included != null) {
        functions.addAll(
          wasiComponentWitWorldFunctions(document, included, active),
        );
      }
      continue;
    }
    final interface = document.interfaceNamed(target.text);
    if (interface == null) {
      continue;
    }
    for (final function in interface.functions) {
      functions.add(
        WASIComponentWitFunctionBinding._(
          item: item,
          interfaceName: interface.name,
          function: function,
          direction: item.direction,
          signature: _parseWitAdapterSignature(function),
        ),
      );
    }
  }
  active.remove(world.name);
  return List<WASIComponentWitFunctionBinding>.unmodifiable(functions);
}

/// Reports functions that cannot bind to executable synchronous adapters.
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
      continue;
    }
    if (signature.isAsync) {
      errors.add(
        WASIComponentWitAdapterBindingError(
          function: function,
          reason: 'async WIT function adapters require Preview3 scheduling',
        ),
      );
    }
  }
  return List<WASIComponentWitAdapterBindingError>.unmodifiable(errors);
}

/// A local WIT interface function expanded from a world boundary.
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

  /// Whether the signature can be bound as a synchronous adapter.
  bool get canBind => unsupportedReason == null && !isAsync;
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
    this.ok,
    this.error,
  }) : elements = List<WASIComponentWitAdapterValueType>.unmodifiable(elements);

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

  /// Creates a `tuple<T...>` WIT adapter value type.
  WASIComponentWitAdapterValueType.tuple({
    required String text,
    required List<WASIComponentWitAdapterValueType> elements,
  }) : this._(
         kind: WASIComponentWitAdapterValueKind.tuple,
         text: text,
         elements: elements,
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

  /// Result success payload type.
  final WASIComponentWitAdapterValueType? ok;

  /// Result error payload type.
  final WASIComponentWitAdapterValueType? error;
}

/// WIT adapter value category.
enum WASIComponentWitAdapterValueKind {
  /// Primitive WIT scalar/string type.
  primitive,

  /// `option<T>`.
  option,

  /// `list<T>`.
  list,

  /// `tuple<T...>`.
  tuple,

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

  /// Invokes an exported WIT function adapter by qualified name.
  Object? invokeExport(String qualifiedName, List<Object?> args) {
    return _invoke(_exports, 'export', qualifiedName, args);
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
        '${signature.unsupportedReason ?? 'async function'}.',
      );
    }
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

    final result = _callback(List<Object?>.unmodifiable(checkedArgs));
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
) {
  final signature = function.signature;
  final isAsync = signature.startsWith('asyncfunc');
  final prefix = isAsync ? 'asyncfunc' : 'func';
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
      final parsedType = _parseWitAdapterValueType(typeText, 'parameter');
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

({WASIComponentWitAdapterValueType? type, String? error})
_parseWitAdapterValueType(String text, String context) {
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
    );
    if (ok.error != null) {
      return (type: null, error: ok.error);
    }
    final error = resultArgs.length == 1
        ? (type: null, error: null)
        : _parseOptionalWitAdapterValueType(
            resultArgs[1],
            '$context result error payload',
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
  return (type: null, error: 'unsupported WIT adapter $context type $text');
}

({WASIComponentWitAdapterValueType? type, String? error})
_parseOptionalWitAdapterValueType(String text, String context) {
  if (text == '_' || text.isEmpty) {
    return (type: null, error: null);
  }
  return _parseWitAdapterValueType(text, context);
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
    case WASIComponentWitAdapterValueKind.tuple:
      return _validateWitAdapterTupleValue(type, value, path);
    case WASIComponentWitAdapterValueKind.result:
      return _validateWitAdapterResultValue(type, value, path);
  }
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
  final associated = value.associatedValue;
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
  final items = value.items;
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
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.tuple) {
    throw StateError('WIT adapter value $path does not match ${type.text}.');
  }
  final elements = type.elements;
  if (value.items.length != elements.length) {
    throw StateError(
      'WIT adapter value $path expected ${elements.length} tuple fields, '
      'got ${value.items.length}.',
    );
  }
  for (var i = 0; i < elements.length; i++) {
    _validateWitAdapterValue(elements[i], value.items[i], '$path.$i');
  }
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
  final associated = value.associatedValue;
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
