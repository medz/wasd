import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'adapter_plan.dart';
import 'string_memory.dart';

/// Function callback used by direct canonical adapter operations.
typedef WASIComponentCanonicalAdapterCallback =
    Object? Function(List<Object?> args);

/// Host for executable canonical `lift`/`lower` adapter operations.
///
/// This is the first executable adapter boundary. It intentionally supports
/// only direct synchronous value signatures backed by the shared Canonical ABI
/// value codec. Resource handles, nested async values, and async adapters are
/// rejected instead of being approximated. Dynamic strings/lists are accepted
/// as direct Dart-side component values here; this is still separate from the
/// memory-backed core ABI flattening path.
final class WASIComponentCanonicalAdapterHost {
  /// Creates a canonical adapter host.
  const WASIComponentCanonicalAdapterHost();

  /// Binds a canonical `lift` plan to the core function it wraps.
  WASIComponentCanonicalAdapterOperation bindLiftCoreFunction(
    WASIComponentCanonicalAdapterPlan plan,
    WASIComponentCanonicalAdapterCallback coreFunction,
  ) {
    _requireAdapterKind(plan, WasmComponentCanonicalKind.lift);
    _checkDirectValuePlan(plan);
    return WASIComponentCanonicalAdapterOperation._(
      plan: plan,
      callback: coreFunction,
    );
  }

  /// Binds a canonical `lower` plan to the component function it wraps.
  WASIComponentCanonicalAdapterOperation bindLowerComponentFunction(
    WASIComponentCanonicalAdapterPlan plan,
    WASIComponentCanonicalAdapterCallback componentFunction,
  ) {
    _requireAdapterKind(plan, WasmComponentCanonicalKind.lower);
    _checkDirectValuePlan(plan);
    return WASIComponentCanonicalAdapterOperation._(
      plan: plan,
      callback: componentFunction,
    );
  }

  /// Binds adapter [plans] against decoded core/component function indexes.
  WASIComponentCanonicalAdapterProgram bindAdapterPlans(
    Iterable<WASIComponentCanonicalAdapterPlan> plans, {
    Map<int, WASIComponentCanonicalAdapterCallback> coreFunctions =
        const <int, WASIComponentCanonicalAdapterCallback>{},
    Map<int, WASIComponentCanonicalAdapterCallback> componentFunctions =
        const <int, WASIComponentCanonicalAdapterCallback>{},
  }) {
    final operations = <WASIComponentCanonicalAdapterOperation>[];
    for (final plan in plans) {
      switch (plan.kind) {
        case WasmComponentCanonicalKind.lift:
          final index = plan.definition.coreFunctionIndex;
          final callback = index == null ? null : coreFunctions[index];
          if (callback == null) {
            throw StateError(
              'Missing core function callback for canonical adapter index '
              '${plan.canonicalIndex}: $index.',
            );
          }
          operations.add(bindLiftCoreFunction(plan, callback));
        case WasmComponentCanonicalKind.lower:
          final index = plan.definition.functionIndex;
          final callback = index == null ? null : componentFunctions[index];
          if (callback == null) {
            throw StateError(
              'Missing component function callback for canonical adapter index '
              '${plan.canonicalIndex}: $index.',
            );
          }
          operations.add(bindLowerComponentFunction(plan, callback));
        default:
          throw UnsupportedError(
            'WASI component canonical ${plan.kind.name} is not an adapter.',
          );
      }
    }
    return WASIComponentCanonicalAdapterProgram(
      operations: List<WASIComponentCanonicalAdapterOperation>.unmodifiable(
        operations,
      ),
    );
  }
}

/// Canonical-indexed executable direct value adapter program.
final class WASIComponentCanonicalAdapterProgram {
  /// Creates a canonical adapter program from ordered [operations].
  WASIComponentCanonicalAdapterProgram({required this.operations})
    : _operationsByCanonicalIndex = _indexOperations(operations);

  /// Adapter operations in prepared plan order.
  final List<WASIComponentCanonicalAdapterOperation> operations;

  final Map<int, WASIComponentCanonicalAdapterOperation>
  _operationsByCanonicalIndex;

  /// Invokes the adapter operation at [canonicalIndex].
  Object? invoke(int canonicalIndex, List<Object?> args) {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.invoke(args);
  }

  /// Invokes an adapter operation through flat Canonical ABI scalar values.
  List<Object?> invokeFlat(
    int canonicalIndex,
    List<Object?> flatArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.invokeFlat(flatArgs, memory: memory, realloc: realloc);
  }

  /// Invokes an adapter operation by loading parameters from canonical memory.
  Object? invokeWithMemory(
    int canonicalIndex,
    wasm.Memory memory,
    List<int> paramPointers, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.invokeWithMemory(
      memory,
      paramPointers,
      resultPointer: resultPointer,
      realloc: realloc,
    );
  }
}

Map<int, WASIComponentCanonicalAdapterOperation> _indexOperations(
  List<WASIComponentCanonicalAdapterOperation> operations,
) {
  final byCanonicalIndex = <int, WASIComponentCanonicalAdapterOperation>{};
  for (final operation in operations) {
    final canonicalIndex = operation.canonicalIndex;
    if (byCanonicalIndex.containsKey(canonicalIndex)) {
      throw StateError(
        'Duplicate WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    byCanonicalIndex[canonicalIndex] = operation;
  }
  return Map<int, WASIComponentCanonicalAdapterOperation>.unmodifiable(
    byCanonicalIndex,
  );
}

/// Executable direct value canonical adapter operation.
final class WASIComponentCanonicalAdapterOperation {
  const WASIComponentCanonicalAdapterOperation._({
    required this.plan,
    required WASIComponentCanonicalAdapterCallback callback,
  }) : _callback = callback;

  /// Adapter generation plan this operation executes.
  final WASIComponentCanonicalAdapterPlan plan;

  final WASIComponentCanonicalAdapterCallback _callback;

  /// Canonical adapter kind.
  WasmComponentCanonicalKind get kind => plan.kind;

  /// Canonical definition index.
  int get canonicalIndex => plan.canonicalIndex;

  /// Invokes the adapter with direct component values.
  Object? invoke(List<Object?> args) {
    if (args.length != plan.params.length) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex expected '
        '${plan.params.length} arguments, got ${args.length}.',
      );
    }
    for (var i = 0; i < plan.params.length; i++) {
      plan.params[i].memoryCodec!.validate(plan.params[i].path, args[i]);
    }

    final result = _callback(List<Object?>.unmodifiable(args));
    final resultPlan = plan.result;
    if (resultPlan == null) {
      if (result != null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex expected no result.',
        );
      }
      return null;
    }
    resultPlan.memoryCodec!.validate(resultPlan.path, result);
    return result;
  }

  /// Invokes the adapter through flat Canonical ABI scalar values.
  List<Object?> invokeFlat(
    List<Object?> flatArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    var offset = 0;
    final args = <Object?>[];
    for (final param in plan.params) {
      final next = _loadFlatValue(
        param,
        flatArgs,
        offset,
        memory,
        plan.stringEncoding,
      );
      args.add(next.value);
      offset = next.nextOffset;
    }
    if (offset != flatArgs.length) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex expected '
        '$offset flat arguments, got ${flatArgs.length}.',
      );
    }

    final result = invoke(args);
    final resultPlan = plan.result;
    if (resultPlan == null) {
      return const <Object?>[];
    }
    return _storeFlatValue(
      resultPlan,
      result,
      memory,
      realloc,
      plan.stringEncoding,
    );
  }

  /// Invokes the adapter with parameter/result values stored in memory.
  Object? invokeWithMemory(
    wasm.Memory memory,
    List<int> paramPointers, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    if (paramPointers.length != plan.params.length) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex expected '
        '${plan.params.length} memory parameter pointers, got '
        '${paramPointers.length}.',
      );
    }
    final args = List<Object?>.generate(
      plan.params.length,
      (index) => plan.params[index].memoryCodec!.load(
        memory,
        paramPointers[index],
        stringEncoding: plan.stringEncoding,
      ),
      growable: false,
    );
    final result = invoke(args);
    final resultPlan = plan.result;
    if (resultPlan == null) {
      if (resultPointer != null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex expected no result pointer.',
        );
      }
      return null;
    }
    if (resultPointer == null) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex requires a result pointer.',
      );
    }
    resultPlan.memoryCodec!.store(
      memory,
      resultPointer,
      result,
      realloc: realloc,
      stringEncoding: plan.stringEncoding,
    );
    return result;
  }
}

({Object? value, int nextOffset}) _loadFlatValue(
  WASIComponentCanonicalAdapterValuePlan valuePlan,
  List<Object?> flatArgs,
  int offset,
  wasm.Memory? memory,
  WASIComponentCanonicalStringEncoding stringEncoding,
) {
  final primitive = valuePlan.memoryCodec!.primitive;
  if (primitive == null) {
    throw UnsupportedError(
      'WASI component canonical adapter value ${valuePlan.path} does not support flat values.',
    );
  }
  if (primitive == WasmComponentPrimitiveValueType.string) {
    if (offset + 2 > flatArgs.length) {
      throw StateError(
        'WASI component canonical adapter value ${valuePlan.path} expected 2 flat string arguments.',
      );
    }
    final memoryRef = _requireMemory(memory, valuePlan.path);
    final pointer = _expectFlatInt(valuePlan.path, flatArgs[offset]);
    final length = _expectFlatInt(valuePlan.path, flatArgs[offset + 1]);
    return (
      value: readWASIComponentCanonicalString(
        memoryRef,
        pointer,
        length,
        stringEncoding,
      ),
      nextOffset: offset + 2,
    );
  }
  if (offset >= flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value ${valuePlan.path} expected a flat argument.',
    );
  }
  final value = _flatPrimitiveToComponentValue(
    primitive,
    valuePlan.path,
    flatArgs[offset],
  );
  valuePlan.memoryCodec!.validate(valuePlan.path, value);
  return (value: value, nextOffset: offset + 1);
}

List<Object?> _storeFlatValue(
  WASIComponentCanonicalAdapterValuePlan valuePlan,
  Object? value,
  wasm.Memory? memory,
  WASIComponentCanonicalRealloc? realloc,
  WASIComponentCanonicalStringEncoding stringEncoding,
) {
  valuePlan.memoryCodec!.validate(valuePlan.path, value);
  final primitive = valuePlan.memoryCodec!.primitive;
  if (primitive == null) {
    throw UnsupportedError(
      'WASI component canonical adapter value ${valuePlan.path} does not support flat values.',
    );
  }
  if (primitive == WasmComponentPrimitiveValueType.string) {
    final memoryRef = _requireMemory(memory, valuePlan.path);
    final memoryString = writeWASIComponentCanonicalString(
      memoryRef,
      _requireRealloc(realloc, valuePlan.path),
      value as String,
      stringEncoding,
    );
    return <Object?>[memoryString.pointer, memoryString.canonicalLength];
  }
  return <Object?>[
    _componentPrimitiveToFlatValue(primitive, valuePlan.path, value),
  ];
}

Object? _flatPrimitiveToComponentValue(
  WasmComponentPrimitiveValueType primitive,
  String path,
  Object? value,
) {
  return switch (primitive) {
    WasmComponentPrimitiveValueType.boolean => _expectFlatInt(path, value) != 0,
    WasmComponentPrimitiveValueType.s8 ||
    WasmComponentPrimitiveValueType.u8 ||
    WasmComponentPrimitiveValueType.s16 ||
    WasmComponentPrimitiveValueType.u16 ||
    WasmComponentPrimitiveValueType.s32 ||
    WasmComponentPrimitiveValueType.u32 ||
    WasmComponentPrimitiveValueType.s64 ||
    WasmComponentPrimitiveValueType.u64 => _expectFlatInt(path, value),
    WasmComponentPrimitiveValueType.f32 ||
    WasmComponentPrimitiveValueType.f64 => _expectFlatNum(path, value),
    WasmComponentPrimitiveValueType.char => _flatCharToString(
      path,
      _expectFlatInt(path, value),
    ),
    WasmComponentPrimitiveValueType.string => throw StateError(
      'String flat values are handled separately.',
    ),
    WasmComponentPrimitiveValueType.errorContext => throw UnsupportedError(
      'WASI component canonical adapter value $path uses error-context handles.',
    ),
  };
}

Object? _componentPrimitiveToFlatValue(
  WasmComponentPrimitiveValueType primitive,
  String path,
  Object? value,
) {
  return switch (primitive) {
    WasmComponentPrimitiveValueType.boolean => (value as bool) ? 1 : 0,
    WasmComponentPrimitiveValueType.s8 ||
    WasmComponentPrimitiveValueType.u8 ||
    WasmComponentPrimitiveValueType.s16 ||
    WasmComponentPrimitiveValueType.u16 ||
    WasmComponentPrimitiveValueType.s32 ||
    WasmComponentPrimitiveValueType.u32 ||
    WasmComponentPrimitiveValueType.s64 ||
    WasmComponentPrimitiveValueType.u64 => value as int,
    WasmComponentPrimitiveValueType.f32 ||
    WasmComponentPrimitiveValueType.f64 => value as num,
    WasmComponentPrimitiveValueType.char => _stringToFlatChar(path, value),
    WasmComponentPrimitiveValueType.string => throw StateError(
      'String flat values are handled separately.',
    ),
    WasmComponentPrimitiveValueType.errorContext => throw UnsupportedError(
      'WASI component canonical adapter value $path uses error-context handles.',
    ),
  };
}

int _expectFlatInt(String path, Object? value) {
  if (value is int) {
    return value;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected int.',
  );
}

num _expectFlatNum(String path, Object? value) {
  if (value is num) {
    return value;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected num.',
  );
}

String _flatCharToString(String path, int value) {
  if (_isUnicodeScalar(value)) {
    return String.fromCharCode(value);
  }
  throw StateError(
    'WASI component canonical adapter value $path expected a Unicode scalar.',
  );
}

int _stringToFlatChar(String path, Object? value) {
  if (value is String && value.runes.length == 1) {
    return value.runes.single;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected a character.',
  );
}

bool _isUnicodeScalar(int value) {
  return value >= 0 && value <= 0x10ffff && (value < 0xd800 || value > 0xdfff);
}

wasm.Memory _requireMemory(wasm.Memory? memory, String path) {
  if (memory != null) {
    return memory;
  }
  throw StateError(
    'WASI component canonical adapter value $path requires memory.',
  );
}

WASIComponentCanonicalRealloc _requireRealloc(
  WASIComponentCanonicalRealloc? realloc,
  String path,
) {
  if (realloc != null) {
    return realloc;
  }
  throw UnsupportedError(
    'WASI component canonical adapter value $path requires a realloc callback.',
  );
}

void _requireAdapterKind(
  WASIComponentCanonicalAdapterPlan plan,
  WasmComponentCanonicalKind expected,
) {
  if (plan.kind != expected) {
    throw StateError(
      'WASI component canonical adapter index ${plan.canonicalIndex} expected '
      '${expected.name}, got ${plan.kind.name}.',
    );
  }
}

void _checkDirectValuePlan(WASIComponentCanonicalAdapterPlan plan) {
  if (plan.isAsync) {
    throw UnsupportedError(
      'WASI component canonical adapter index ${plan.canonicalIndex} uses async.',
    );
  }
  if (plan.hasResourceHandles) {
    throw UnsupportedError(
      'WASI component canonical adapter index ${plan.canonicalIndex} uses resource handles.',
    );
  }
  for (final param in plan.params) {
    _checkDirectValue(plan, param);
  }
  final result = plan.result;
  if (result != null) {
    _checkDirectValue(plan, result);
  }
}

void _checkDirectValue(
  WASIComponentCanonicalAdapterPlan plan,
  WASIComponentCanonicalAdapterValuePlan value,
) {
  if (value.memoryCodec == null) {
    throw UnsupportedError(
      'WASI component canonical adapter index ${plan.canonicalIndex} '
      'value ${value.path} does not have a supported direct value codec.',
    );
  }
  if (value.resourceUses.isNotEmpty) {
    throw UnsupportedError(
      'WASI component canonical adapter index ${plan.canonicalIndex} '
      'value ${value.path} uses resource handles.',
    );
  }
}
