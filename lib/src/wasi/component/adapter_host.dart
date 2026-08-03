import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'adapter_plan.dart';
import 'async_host.dart';
import 'async_values.dart';
import 'string_memory.dart';
import 'unicode_scalar.dart';
import 'value_memory.dart';

const int _canonicalMaxFlatParams = 16;
const int _canonicalMaxFlatAsyncParams = 4;
const int _canonicalMaxFlatResults = 1;

/// Function callback used by direct canonical adapter operations.
typedef WASIComponentCanonicalAdapterCallback =
    FutureOr<Object?> Function(List<Object?> args);

/// Host for executable canonical `lift`/`lower` adapter operations.
///
/// This is the first executable adapter boundary. It intentionally supports
/// only synchronous value signatures backed by the shared Canonical ABI value
/// codec or canonical `u32` handle layouts. Direct invocations can pass
/// `own`/`borrow` resource handles and `error-context` handles as canonical
/// `u32` scalars; memory-backed invocations use the same canonical `u32`
/// handle representation. Async adapters reuse the same codecs through the
/// explicit asynchronous invocation entrypoints. Resource table ownership,
/// borrow, and drop behavior remains a higher-level host concern.
final class WASIComponentCanonicalAdapterHost {
  /// Creates a canonical adapter host.
  const WASIComponentCanonicalAdapterHost({this.asyncHost});

  /// Async endpoint registry used by flat stream and future values.
  final WASIComponentAsyncHost? asyncHost;

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
      postReturnCallback: null,
      callState: _WASIComponentCanonicalCallState(),
      asyncHost: asyncHost,
      directValueSupported: true,
      memoryValueSupported: _supportsMemoryValuePlan(plan),
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
      postReturnCallback: null,
      callState: _WASIComponentCanonicalCallState(),
      asyncHost: asyncHost,
      directValueSupported: true,
      memoryValueSupported: _supportsMemoryValuePlan(plan),
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
    final callState = _WASIComponentCanonicalCallState();
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
          operations.add(
            WASIComponentCanonicalAdapterOperation._(
              plan: plan,
              callback: callback,
              postReturnCallback: _postReturnCallback(plan, coreFunctions),
              callState: callState,
              asyncHost: asyncHost,
              directValueSupported: _supportsDirectValuePlan(plan),
              memoryValueSupported: _supportsMemoryValuePlan(plan),
            ),
          );
        case WasmComponentCanonicalKind.lower:
          final index = plan.definition.functionIndex;
          final callback = index == null ? null : componentFunctions[index];
          if (callback == null) {
            throw StateError(
              'Missing component function callback for canonical adapter index '
              '${plan.canonicalIndex}: $index.',
            );
          }
          operations.add(
            WASIComponentCanonicalAdapterOperation._(
              plan: plan,
              callback: callback,
              postReturnCallback: null,
              callState: callState,
              asyncHost: asyncHost,
              directValueSupported: _supportsDirectValuePlan(plan),
              memoryValueSupported: _supportsMemoryValuePlan(plan),
            ),
          );
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

WASIComponentCanonicalAdapterCallback? _postReturnCallback(
  WASIComponentCanonicalAdapterPlan plan,
  Map<int, WASIComponentCanonicalAdapterCallback> coreFunctions,
) {
  final index = plan.postReturnIndex;
  if (index == null) {
    return null;
  }
  final callback = coreFunctions[index];
  if (callback == null) {
    throw StateError(
      'Missing post-return core function callback for canonical adapter index '
      '${plan.canonicalIndex}: $index.',
    );
  }
  return callback;
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

  /// Invokes the adapter operation at [canonicalIndex] asynchronously.
  Future<Object?> invokeAsync(int canonicalIndex, List<Object?> args) async {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.invokeAsync(args);
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

  /// Invokes an adapter operation asynchronously through flat Canonical ABI
  /// scalar values.
  Future<List<Object?>> invokeFlatAsync(
    int canonicalIndex,
    List<Object?> flatArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) async {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.invokeFlatAsync(
      flatArgs,
      memory: memory,
      realloc: realloc,
    );
  }

  /// Invokes a lowered component function through its canonical core ABI.
  ///
  /// Unlike [invokeFlat], this applies the Canonical ABI indirect parameter and
  /// result rules used by an actual core Wasm caller.
  List<Object?> invokeLoweredCore(
    int canonicalIndex,
    List<Object?> coreArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.invokeLoweredCore(
      coreArgs,
      memory: memory,
      realloc: realloc,
    );
  }

  /// Invokes a lowered component function through its canonical core ABI and
  /// waits for an asynchronous host callback when necessary.
  Future<List<Object?>> invokeLoweredCoreAsync(
    int canonicalIndex,
    List<Object?> coreArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) async {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.invokeLoweredCoreAsync(
      coreArgs,
      memory: memory,
      realloc: realloc,
    );
  }

  /// Starts an async canonical lower without waiting for its component
  /// callback to resolve.
  WASIComponentCanonicalAsyncLowerCall startAsyncLowerCore(
    int canonicalIndex,
    List<Object?> coreArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.startAsyncLowerCore(
      coreArgs,
      memory: memory,
      realloc: realloc,
    );
  }

  /// Invokes a lifted core function from direct component values.
  Object? invokeLiftedCore(
    int canonicalIndex,
    List<Object?> args, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.invokeLiftedCore(args, memory: memory, realloc: realloc);
  }

  /// Invokes a lifted core function from direct component values and waits for
  /// an asynchronous core callback when necessary.
  Future<Object?> invokeLiftedCoreAsync(
    int canonicalIndex,
    List<Object?> args, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) async {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.invokeLiftedCoreAsync(
      args,
      memory: memory,
      realloc: realloc,
    );
  }

  /// Lowers component [args] into the core parameters of an async lift.
  List<Object?> prepareAsyncLiftCoreArgs(
    int canonicalIndex,
    List<Object?> args, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.prepareAsyncLiftCoreArgs(
      args,
      memory: memory,
      realloc: realloc,
    );
  }

  /// Lifts the flat value captured by `task.return` for an async lift.
  Object? finishAsyncLiftResult(
    int canonicalIndex,
    Object? taskResult, {
    wasm.Memory? memory,
  }) {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.finishAsyncLiftResult(taskResult, memory: memory);
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

  /// Invokes an adapter operation asynchronously by loading parameters from
  /// canonical memory.
  Future<Object?> invokeWithMemoryAsync(
    int canonicalIndex,
    wasm.Memory memory,
    List<int> paramPointers, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) async {
    final operation = _operationsByCanonicalIndex[canonicalIndex];
    if (operation == null) {
      throw StateError(
        'Unknown WASI component canonical adapter index: $canonicalIndex.',
      );
    }
    return operation.invokeWithMemoryAsync(
      memory,
      paramPointers,
      resultPointer: resultPointer,
      realloc: realloc,
    );
  }
}

/// One in-flight async canonical lower call.
final class WASIComponentCanonicalAsyncLowerCall {
  const WASIComponentCanonicalAsyncLowerCall._({
    required WASIComponentCanonicalAdapterOperation operation,
    required this.result,
    required int? resultPointer,
    required wasm.Memory? memory,
    required WASIComponentCanonicalRealloc? realloc,
  }) : _operation = operation,
       _resultPointer = resultPointer,
       _memory = memory,
       _realloc = realloc;

  final WASIComponentCanonicalAdapterOperation _operation;
  final int? _resultPointer;
  final wasm.Memory? _memory;
  final WASIComponentCanonicalRealloc? _realloc;

  /// Immediate value or future returned by the component callback.
  final FutureOr<Object?> result;

  /// Lowers [value] into the caller-provided result storage.
  void complete(Object? value) {
    final flat = _operation._storeLoweredCoreResult(
      value,
      _resultPointer,
      _memory,
      _realloc,
    );
    if (flat.isNotEmpty) {
      throw StateError(
        'Async canonical lower unexpectedly produced direct core results.',
      );
    }
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
    required WASIComponentCanonicalAdapterCallback? postReturnCallback,
    required _WASIComponentCanonicalCallState callState,
    required WASIComponentAsyncHost? asyncHost,
    required bool directValueSupported,
    required bool memoryValueSupported,
  }) : _callback = callback,
       _postReturnCallback = postReturnCallback,
       _callState = callState,
       _asyncHost = asyncHost,
       _directValueSupported = directValueSupported,
       _memoryValueSupported = memoryValueSupported;

  /// Adapter generation plan this operation executes.
  final WASIComponentCanonicalAdapterPlan plan;

  final WASIComponentCanonicalAdapterCallback _callback;
  final WASIComponentCanonicalAdapterCallback? _postReturnCallback;
  final _WASIComponentCanonicalCallState _callState;
  final WASIComponentAsyncHost? _asyncHost;
  final bool _directValueSupported;
  final bool _memoryValueSupported;

  /// Canonical adapter kind.
  WasmComponentCanonicalKind get kind => plan.kind;

  /// Canonical definition index.
  int get canonicalIndex => plan.canonicalIndex;

  /// Invokes the adapter with direct component values.
  Object? invoke(List<Object?> args) {
    _requireMayLeaveForLower();
    _checkSyncInvokeSupported('direct value invocation', 'invokeAsync');
    _checkDirectInvokeSupported();
    final directArgs = _validateDirectArgs(args);

    final result = _callback(List<Object?>.unmodifiable(directArgs));
    return _validateDirectResult(result);
  }

  /// Invokes the adapter asynchronously with direct component values.
  Future<Object?> invokeAsync(List<Object?> args) async {
    _requireMayLeaveForLower();
    _checkDirectInvokeSupported();
    final directArgs = _validateDirectArgs(args);

    final result = await _callback(List<Object?>.unmodifiable(directArgs));
    return _validateDirectResult(result);
  }

  List<Object?> _validateDirectArgs(List<Object?> args) {
    if (args.length != plan.params.length) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex expected '
        '${plan.params.length} arguments, got ${args.length}.',
      );
    }
    return List<Object?>.generate(
      plan.params.length,
      (index) => _validateDirectValue(plan.params[index], args[index]),
      growable: false,
    );
  }

  Object? _validateDirectResult(Object? result) {
    final resultPlan = plan.result;
    if (resultPlan == null) {
      if (result != null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex expected no result.',
        );
      }
      return null;
    }
    return _validateDirectValue(resultPlan, result);
  }

  /// Invokes the adapter through flat Canonical ABI scalar values.
  List<Object?> invokeFlat(
    List<Object?> flatArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    _requireMayLeaveForLower();
    _checkSyncInvokeSupported('flat value invocation', 'invokeFlatAsync');
    final args = _loadFlatArgs(flatArgs, memory);

    final result = _invokeFlatCallback(args);
    return _storeFlatResult(result, memory, _guardRealloc(realloc));
  }

  /// Invokes the adapter asynchronously through flat Canonical ABI scalar
  /// values.
  Future<List<Object?>> invokeFlatAsync(
    List<Object?> flatArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) async {
    _requireMayLeaveForLower();
    final args = _loadFlatArgs(flatArgs, memory);

    final result = await _invokeFlatCallbackAsync(args);
    return _storeFlatResult(result, memory, _guardRealloc(realloc));
  }

  /// Invokes this lowered function using the core signature produced by the
  /// Canonical ABI flattening algorithm.
  List<Object?> invokeLoweredCore(
    List<Object?> coreArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    _requireLoweredCoreOperation();
    _requireMayLeaveForLower();
    _checkSyncInvokeSupported(
      'lowered core invocation',
      'invokeLoweredCoreAsync',
    );
    final invocation = _loadLoweredCoreArgs(coreArgs, memory);
    final result = _invokeFlatCallback(invocation.args);
    return _storeLoweredCoreResult(
      result,
      invocation.resultPointer,
      memory,
      _guardRealloc(realloc),
    );
  }

  /// Invokes this lowered function using the core signature produced by the
  /// Canonical ABI flattening algorithm and waits for the host callback.
  Future<List<Object?>> invokeLoweredCoreAsync(
    List<Object?> coreArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) async {
    _requireLoweredCoreOperation();
    _requireMayLeaveForLower();
    final invocation = _loadLoweredCoreArgs(coreArgs, memory);
    final result = await _invokeFlatCallbackAsync(invocation.args);
    return _storeLoweredCoreResult(
      result,
      invocation.resultPointer,
      memory,
      _guardRealloc(realloc),
    );
  }

  /// Starts this async lowered function and returns before a future callback
  /// resolves.
  WASIComponentCanonicalAsyncLowerCall startAsyncLowerCore(
    List<Object?> coreArgs, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    _requireLoweredCoreOperation();
    if (!plan.isAsync) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex is not async.',
      );
    }
    _requireMayLeaveForLower();
    final invocation = _loadLoweredCoreArgs(coreArgs, memory);
    final result = _callback(List<Object?>.unmodifiable(invocation.args));
    return WASIComponentCanonicalAsyncLowerCall._(
      operation: this,
      result: result,
      resultPointer: invocation.resultPointer,
      memory: memory,
      realloc: _guardRealloc(realloc),
    );
  }

  /// Invokes this lifted function through the core signature produced by the
  /// Canonical ABI flattening algorithm.
  Object? invokeLiftedCore(
    List<Object?> args, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    _requireLiftedCoreOperation();
    _checkSyncInvokeSupported(
      'lifted core invocation',
      'invokeLiftedCoreAsync',
    );
    final coreArgs = _storeLiftedCoreArgs(args, memory, _guardRealloc(realloc));
    final result = _callback(List<Object?>.unmodifiable(coreArgs));
    final lifted = _loadLiftedCoreResult(result, memory);
    _invokePostReturn(result);
    return lifted;
  }

  /// Invokes this lifted function through its canonical core signature and
  /// waits for an asynchronous core callback when necessary.
  Future<Object?> invokeLiftedCoreAsync(
    List<Object?> args, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) async {
    _requireLiftedCoreOperation();
    final coreArgs = _storeLiftedCoreArgs(args, memory, _guardRealloc(realloc));
    final result = await _callback(List<Object?>.unmodifiable(coreArgs));
    final lifted = _loadLiftedCoreResult(result, memory);
    await _invokePostReturnAsync(result);
    return lifted;
  }

  /// Lowers component arguments for a stackless async canonical lift.
  List<Object?> prepareAsyncLiftCoreArgs(
    List<Object?> args, {
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    _requireLiftedCoreOperation();
    if (!plan.isAsync) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex is not async.',
      );
    }
    return _storeLiftedCoreArgs(args, memory, _guardRealloc(realloc));
  }

  /// Lifts an async canonical lift result captured by `task.return`.
  Object? finishAsyncLiftResult(Object? taskResult, {wasm.Memory? memory}) {
    _requireLiftedCoreOperation();
    if (!plan.isAsync) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex is not async.',
      );
    }
    final resultPlan = plan.result;
    if (resultPlan == null) {
      if (taskResult != null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex expected no async result.',
        );
      }
      return null;
    }
    final flatLength = resultPlan.flatLength;
    if (flatLength == null) {
      throw UnsupportedError(
        'WASI component canonical adapter value ${resultPlan.path} does not '
        'support a flat async result.',
      );
    }
    if (flatLength > _canonicalMaxFlatParams) {
      final memoryRef = memory;
      if (memoryRef == null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex requires '
          'memory for its indirect task.return result.',
        );
      }
      return _loadIndirectValue(
        resultPlan,
        memoryRef,
        _requireCorePointer(taskResult, 'task.return result'),
        'task.return result',
      );
    }
    final flatArgs = taskResult is List<Object?>
        ? taskResult
        : <Object?>[taskResult];
    final loaded = _loadFlatValue(
      resultPlan,
      flatArgs,
      0,
      memory,
      plan.stringEncoding,
      _asyncHost,
    );
    if (loaded.nextOffset != flatArgs.length) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex returned '
        '${flatArgs.length} async scalars; consumed ${loaded.nextOffset}.',
      );
    }
    return loaded.value;
  }

  /// Invokes the adapter with parameter/result values stored in memory.
  Object? invokeWithMemory(
    wasm.Memory memory,
    List<int> paramPointers, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) {
    _requireMayLeaveForLower();
    _checkSyncInvokeSupported(
      'memory-backed invocation',
      'invokeWithMemoryAsync',
    );
    _checkMemoryInvokeSupported();
    final args = _loadMemoryArgs(memory, paramPointers);
    final result = _callback(List<Object?>.unmodifiable(args));
    return _storeMemoryResult(
      memory,
      result,
      resultPointer: resultPointer,
      realloc: _guardRealloc(realloc),
    );
  }

  /// Invokes the adapter asynchronously with parameter/result values stored in
  /// memory.
  Future<Object?> invokeWithMemoryAsync(
    wasm.Memory memory,
    List<int> paramPointers, {
    int? resultPointer,
    WASIComponentCanonicalRealloc? realloc,
  }) async {
    _requireMayLeaveForLower();
    _checkMemoryInvokeSupported();
    final args = _loadMemoryArgs(memory, paramPointers);
    final result = await _callback(List<Object?>.unmodifiable(args));
    return _storeMemoryResult(
      memory,
      result,
      resultPointer: resultPointer,
      realloc: _guardRealloc(realloc),
    );
  }

  List<Object?> _loadFlatArgs(List<Object?> flatArgs, wasm.Memory? memory) {
    var offset = 0;
    final args = <Object?>[];
    for (final param in plan.params) {
      final next = _loadFlatValue(
        param,
        flatArgs,
        offset,
        memory,
        plan.stringEncoding,
        _asyncHost,
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
    return args;
  }

  List<Object?> _storeLiftedCoreArgs(
    List<Object?> args,
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  ) {
    final directArgs = _validateDirectArgs(args);
    if (_flatParamCount() > _canonicalMaxFlatParams) {
      final memoryRef = memory;
      final reallocRef = realloc;
      if (memoryRef == null || reallocRef == null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex requires '
          'memory and realloc for indirect lifted core parameters.',
        );
      }
      var alignment = 1;
      var byteLength = 0;
      for (final param in plan.params) {
        final layout = _requireIndirectMemoryLayout(param, 'parameter');
        alignment = alignment < layout.alignment ? layout.alignment : alignment;
        byteLength = _alignCanonicalOffset(byteLength, layout.alignment);
        byteLength += layout.byteLength;
      }
      byteLength = _alignCanonicalOffset(byteLength, alignment);
      final pointer = reallocRef(0, 0, alignment, byteLength);
      _checkAllocatedMemoryRange(
        memoryRef,
        pointer,
        byteLength,
        alignment,
        'canonical[$canonicalIndex] indirect parameters',
      );
      var offset = 0;
      for (var index = 0; index < plan.params.length; index++) {
        final param = plan.params[index];
        final layout = _requireIndirectMemoryLayout(param, 'parameter');
        offset = _alignCanonicalOffset(offset, layout.alignment);
        _storeIndirectValue(
          param,
          directArgs[index],
          memoryRef,
          pointer + offset,
          reallocRef,
        );
        offset += layout.byteLength;
      }
      return <Object?>[pointer];
    }
    final flatArgs = <Object?>[];
    for (var index = 0; index < plan.params.length; index++) {
      flatArgs.addAll(
        _storeFlatValue(
          plan.params[index],
          directArgs[index],
          memory,
          realloc,
          plan.stringEncoding,
          _asyncHost,
        ),
      );
    }
    return flatArgs;
  }

  Object? _loadLiftedCoreResult(Object? coreResult, wasm.Memory? memory) {
    final resultPlan = plan.result;
    if (resultPlan == null) {
      if (coreResult != null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex expected no '
          'core result.',
        );
      }
      return null;
    }
    final flatLength = resultPlan.flatLength;
    if (flatLength == null) {
      throw UnsupportedError(
        'WASI component canonical adapter value ${resultPlan.path} does not '
        'support a flat core result.',
      );
    }
    if (flatLength > _canonicalMaxFlatResults) {
      final memoryRef = memory;
      if (memoryRef == null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex requires '
          'memory for its indirect lifted core result.',
        );
      }
      return _loadIndirectValue(
        resultPlan,
        memoryRef,
        _requireCorePointer(coreResult, 'result'),
        'result',
      );
    }
    final flatResults = flatLength == 0
        ? const <Object?>[]
        : <Object?>[coreResult];
    final loaded = _loadFlatValue(
      resultPlan,
      flatResults,
      0,
      memory,
      plan.stringEncoding,
      _asyncHost,
    );
    if (loaded.nextOffset != flatResults.length) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex consumed '
        '${loaded.nextOffset} core results, got ${flatResults.length}.',
      );
    }
    return loaded.value;
  }

  ({int alignment, int byteLength}) _requireIndirectMemoryLayout(
    WASIComponentCanonicalAdapterValuePlan valuePlan,
    String role,
  ) {
    final codec = valuePlan.memoryCodec;
    if (codec != null) {
      return (alignment: codec.alignment, byteLength: codec.byteLength);
    }
    final flatLayout = valuePlan.flatLayout;
    final memoryLayout = flatLayout == null
        ? null
        : _flatHandleMemoryLayout(flatLayout);
    if (memoryLayout == null) {
      throw UnsupportedError(
        'WASI component canonical adapter value ${valuePlan.path} does not '
        'support an indirect $role.',
      );
    }
    return memoryLayout;
  }

  Object? _loadIndirectValue(
    WASIComponentCanonicalAdapterValuePlan valuePlan,
    wasm.Memory memory,
    int pointer,
    String role,
  ) {
    final codec = valuePlan.memoryCodec;
    if (codec != null) {
      final value = codec.load(
        memory,
        pointer,
        stringEncoding: plan.stringEncoding,
      );
      final flatLayout = valuePlan.flatLayout;
      return flatLayout != null && _flatLayoutContainsAsyncHandle(flatLayout)
          ? _liftAsyncHandlesFromMemory(
              flatLayout,
              valuePlan.path,
              value,
              _asyncHost,
            )
          : value;
    }
    final flatLayout = valuePlan.flatLayout;
    final memoryLayout = flatLayout == null
        ? null
        : _flatHandleMemoryLayout(flatLayout);
    if (flatLayout == null || memoryLayout == null) {
      throw UnsupportedError(
        'WASI component canonical adapter value ${valuePlan.path} does not '
        'support an indirect $role.',
      );
    }
    return _loadFlatHandleMemory(
      flatLayout,
      valuePlan.path,
      memory,
      pointer,
      memoryLayout,
      plan.stringEncoding,
      _asyncHost,
    );
  }

  void _storeIndirectValue(
    WASIComponentCanonicalAdapterValuePlan valuePlan,
    Object? value,
    wasm.Memory memory,
    int pointer,
    WASIComponentCanonicalRealloc? realloc,
  ) {
    final codec = valuePlan.memoryCodec;
    if (codec != null) {
      final flatLayout = valuePlan.flatLayout;
      final hasAsyncHandles =
          flatLayout != null && _flatLayoutContainsAsyncHandle(flatLayout);
      if (hasAsyncHandles) {
        _checkAllocatedMemoryRange(
          memory,
          pointer,
          codec.byteLength,
          codec.alignment,
          valuePlan.path,
        );
        _validateFlatDirectValue(flatLayout, valuePlan.path, value);
      }
      final memoryValue = hasAsyncHandles
          ? _lowerAsyncHandlesForMemory(
              flatLayout,
              valuePlan.path,
              value,
              _asyncHost,
            )
          : value;
      codec.store(
        memory,
        pointer,
        memoryValue,
        realloc: realloc,
        stringEncoding: plan.stringEncoding,
      );
      return;
    }
    final flatLayout = valuePlan.flatLayout;
    final memoryLayout = flatLayout == null
        ? null
        : _flatHandleMemoryLayout(flatLayout);
    if (flatLayout == null || memoryLayout == null) {
      throw UnsupportedError(
        'WASI component canonical adapter value ${valuePlan.path} does not '
        'support an indirect value.',
      );
    }
    _storeFlatHandleMemory(
      flatLayout,
      valuePlan.path,
      value,
      memory,
      pointer,
      memoryLayout,
      _asyncHost,
    );
  }

  void _invokePostReturn(Object? coreResult) {
    final callback = _postReturnCallback;
    if (callback == null) {
      return;
    }
    final result = _callState.withLeavingBlocked(
      () => callback(
        List<Object?>.unmodifiable(_liftedCoreResultArgs(coreResult)),
      ),
    );
    if (result is Future) {
      throw UnsupportedError(
        'WASI component canonical adapter index $canonicalIndex has an '
        'async post-return callback; use invokeLiftedCoreAsync.',
      );
    }
    if (result != null) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex post-return '
        'returned an unexpected value.',
      );
    }
  }

  Future<void> _invokePostReturnAsync(Object? coreResult) async {
    final callback = _postReturnCallback;
    if (callback == null) {
      return;
    }
    final result = await _callState.withLeavingBlockedAsync(
      () => callback(
        List<Object?>.unmodifiable(_liftedCoreResultArgs(coreResult)),
      ),
    );
    if (result != null) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex post-return '
        'returned an unexpected value.',
      );
    }
  }

  List<Object?> _liftedCoreResultArgs(Object? coreResult) {
    final flatLength = plan.result?.flatLength ?? 0;
    return flatLength == 0 ? const <Object?>[] : <Object?>[coreResult];
  }

  ({List<Object?> args, int? resultPointer}) _loadLoweredCoreArgs(
    List<Object?> coreArgs,
    wasm.Memory? memory,
  ) {
    final flatParamCount = _flatParamCount();
    final maxFlatParams = plan.isAsync
        ? _canonicalMaxFlatAsyncParams
        : _canonicalMaxFlatParams;
    final paramsIndirect = flatParamCount > maxFlatParams;
    final resultIndirect = _resultIsIndirect();
    final expectedCoreArgCount =
        (paramsIndirect ? 1 : flatParamCount) + (resultIndirect ? 1 : 0);
    if (coreArgs.length != expectedCoreArgCount) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex expected '
        '$expectedCoreArgCount lowered core arguments, got ${coreArgs.length}.',
      );
    }

    final resultPointer = resultIndirect
        ? _requireCorePointer(coreArgs.last, 'result')
        : null;
    final args = paramsIndirect
        ? _loadIndirectParams(
            _requireCorePointer(coreArgs.first, 'parameter'),
            memory,
          )
        : _loadFlatArgs(coreArgs.sublist(0, flatParamCount), memory);
    return (args: args, resultPointer: resultPointer);
  }

  List<Object?> _loadIndirectParams(int pointer, wasm.Memory? memory) {
    if (memory == null) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex requires memory '
        'for indirect parameters.',
      );
    }
    var offset = 0;
    final args = <Object?>[];
    for (final param in plan.params) {
      final layout = _requireIndirectMemoryLayout(param, 'parameter');
      offset = _alignCanonicalOffset(offset, layout.alignment);
      args.add(
        _loadIndirectValue(param, memory, pointer + offset, 'parameter'),
      );
      offset += layout.byteLength;
    }
    return args;
  }

  List<Object?> _storeLoweredCoreResult(
    Object? result,
    int? resultPointer,
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  ) {
    if (!_resultIsIndirect()) {
      return _storeFlatResult(result, memory, realloc);
    }
    final resultPlan = plan.result!;
    if (memory == null || resultPointer == null) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex requires memory '
        'and a result pointer for its indirect result.',
      );
    }
    _storeIndirectValue(resultPlan, result, memory, resultPointer, realloc);
    return const <Object?>[];
  }

  int _flatParamCount() {
    var count = 0;
    for (final param in plan.params) {
      final length = param.flatLength;
      if (length == null) {
        throw UnsupportedError(
          'WASI component canonical adapter value ${param.path} does not '
          'support flat core parameters.',
        );
      }
      count += length;
    }
    return count;
  }

  bool _resultIsIndirect() {
    final result = plan.result;
    if (result == null) {
      return false;
    }
    final length = result.flatLength;
    if (length == null) {
      throw UnsupportedError(
        'WASI component canonical adapter value ${result.path} does not '
        'support a flat core result.',
      );
    }
    final maxFlatResults =
        plan.isAsync && kind == WasmComponentCanonicalKind.lower
        ? 0
        : _canonicalMaxFlatResults;
    return length > maxFlatResults;
  }

  int _requireCorePointer(Object? value, String role) {
    if (value is! int) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex expected a '
        'canonical u32 $role pointer, got $value.',
      );
    }
    return value.toUnsigned(32);
  }

  void _requireLoweredCoreOperation() {
    if (kind != WasmComponentCanonicalKind.lower) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex is not a '
        'canonical lower operation.',
      );
    }
  }

  void _requireLiftedCoreOperation() {
    if (kind != WasmComponentCanonicalKind.lift) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex is not a '
        'canonical lift operation.',
      );
    }
  }

  void _requireMayLeaveForLower() {
    if (kind == WasmComponentCanonicalKind.lower) {
      _callState.requireMayLeave(canonicalIndex);
    }
  }

  WASIComponentCanonicalRealloc? _guardRealloc(
    WASIComponentCanonicalRealloc? realloc,
  ) {
    if (realloc == null) {
      return null;
    }
    return (oldPointer, oldSize, alignment, newSize) =>
        _callState.withLeavingBlocked(
          () => realloc(oldPointer, oldSize, alignment, newSize),
        );
  }

  List<Object?> _storeFlatResult(
    Object? result,
    wasm.Memory? memory,
    WASIComponentCanonicalRealloc? realloc,
  ) {
    final resultPlan = plan.result;
    if (resultPlan == null) {
      if (result != null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex expected no result.',
        );
      }
      return const <Object?>[];
    }
    return _storeFlatValue(
      resultPlan,
      result,
      memory,
      realloc,
      plan.stringEncoding,
      _asyncHost,
    );
  }

  List<Object?> _loadMemoryArgs(wasm.Memory memory, List<int> paramPointers) {
    if (paramPointers.length != plan.params.length) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex expected '
        '${plan.params.length} memory parameter pointers, got '
        '${paramPointers.length}.',
      );
    }
    return List<Object?>.generate(
      plan.params.length,
      (index) => plan.params[index].memoryCodec!.load(
        memory,
        paramPointers[index],
        stringEncoding: plan.stringEncoding,
      ),
      growable: false,
    );
  }

  Object? _storeMemoryResult(
    wasm.Memory memory,
    Object? result, {
    required int? resultPointer,
    required WASIComponentCanonicalRealloc? realloc,
  }) {
    final resultPlan = plan.result;
    if (resultPlan == null) {
      if (result != null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex expected no result.',
        );
      }
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

  void _checkSyncInvokeSupported(String mode, String asyncMethod) {
    if (!plan.isAsync) {
      return;
    }
    throw UnsupportedError(
      'WASI component canonical adapter index $canonicalIndex uses async; '
      'use $asyncMethod for $mode.',
    );
  }

  void _checkDirectInvokeSupported() {
    if (_directValueSupported) {
      return;
    }
    throw UnsupportedError(
      'WASI component canonical adapter index $canonicalIndex does not support direct value invocation.',
    );
  }

  void _checkMemoryInvokeSupported() {
    if (_memoryValueSupported) {
      return;
    }
    throw UnsupportedError(
      'WASI component canonical adapter index $canonicalIndex does not support memory-backed invocation.',
    );
  }

  Object? _invokeFlatCallback(List<Object?> args) {
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
    return result;
  }

  Future<Object?> _invokeFlatCallbackAsync(List<Object?> args) async {
    final result = await _callback(List<Object?>.unmodifiable(args));
    final resultPlan = plan.result;
    if (resultPlan == null) {
      if (result != null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex expected no result.',
        );
      }
      return null;
    }
    return result;
  }
}

final class _WASIComponentCanonicalCallState {
  var _leavingBlockedDepth = 0;

  void requireMayLeave(int canonicalIndex) {
    if (_leavingBlockedDepth == 0) {
      return;
    }
    throw StateError(
      'WASI component canonical adapter index $canonicalIndex cannot leave '
      'the component instance during post-return or realloc.',
    );
  }

  T withLeavingBlocked<T>(T Function() callback) {
    _leavingBlockedDepth++;
    try {
      return callback();
    } finally {
      _leavingBlockedDepth--;
    }
  }

  Future<T> withLeavingBlockedAsync<T>(FutureOr<T> Function() callback) async {
    _leavingBlockedDepth++;
    try {
      return await callback();
    } finally {
      _leavingBlockedDepth--;
    }
  }
}

int _alignCanonicalOffset(int value, int alignment) {
  return ((value + alignment - 1) ~/ alignment) * alignment;
}

Object? _validateDirectValue(
  WASIComponentCanonicalAdapterValuePlan valuePlan,
  Object? value,
) {
  final memoryCodec = valuePlan.memoryCodec;
  final flatLayout = valuePlan.flatLayout;
  if (memoryCodec != null &&
      (flatLayout == null || !_flatLayoutContainsAsyncHandle(flatLayout))) {
    memoryCodec.validate(valuePlan.path, value);
    return value;
  }
  if (flatLayout?.kind == WASIComponentCanonicalAdapterFlatValueKind.resource) {
    return _flatResourceHandleToInt(flatLayout!, valuePlan.path, value);
  }
  if (flatLayout?.kind ==
      WASIComponentCanonicalAdapterFlatValueKind.errorContext) {
    return _flatErrorContextHandleToInt(valuePlan.path, value);
  }
  if (flatLayout != null) {
    _validateFlatDirectValue(flatLayout, valuePlan.path, value);
    return value;
  }
  throw UnsupportedError(
    'WASI component canonical adapter value ${valuePlan.path} does not support direct values.',
  );
}

void _validateFlatDirectValue(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
) {
  final primitive = layout.primitive;
  if (primitive != null) {
    _componentPrimitiveToFlatValue(primitive, path, value);
    return;
  }
  switch (layout.kind) {
    case WASIComponentCanonicalAdapterFlatValueKind.stream:
      if (value is WASIComponentStream ||
          value is WASIComponentReadableStream) {
        return;
      }
      break;
    case WASIComponentCanonicalAdapterFlatValueKind.future:
      if (value is WASIComponentFuture ||
          value is WASIComponentReadableFuture) {
        return;
      }
      break;
    case WASIComponentCanonicalAdapterFlatValueKind.record:
    case WASIComponentCanonicalAdapterFlatValueKind.fixedList:
    case WASIComponentCanonicalAdapterFlatValueKind.tuple:
      final items = switch (value) {
        WasmComponentValueData()
            when value.kind == _flatCompositeValueDataKind(layout.kind) =>
          value.itemValues,
        List<Object?>()
            when layout.kind ==
                WASIComponentCanonicalAdapterFlatValueKind.tuple =>
          value,
        _ => null,
      };
      if (items == null || items.length != layout.fields.length) {
        break;
      }
      for (var index = 0; index < items.length; index++) {
        final field = layout.fields[index];
        _validateFlatDirectValue(
          field.value,
          '$path.${field.label}',
          items[index],
        );
      }
      return;
    case WASIComponentCanonicalAdapterFlatValueKind.option:
      if (value is! WasmComponentValueData ||
          value.kind != WasmComponentValueDataKind.option) {
        break;
      }
      if (!_flatOptionIsSome(layout, path, value)) {
        if (value.payload == null) {
          return;
        }
        break;
      }
      final optionPayload = value.payload;
      if (optionPayload == null) {
        break;
      }
      _validateFlatDirectValue(layout.element!, '$path.some', optionPayload);
      return;
    case WASIComponentCanonicalAdapterFlatValueKind.result:
      if (value is! WasmComponentValueData ||
          value.kind != WasmComponentValueDataKind.result) {
        break;
      }
      final isOk = _flatResultIsOk(layout, path, value);
      final payloadLayout = isOk ? layout.ok : layout.error;
      final resultPayload = value.payload;
      if (payloadLayout == null) {
        if (resultPayload == null) {
          return;
        }
        break;
      }
      if (resultPayload == null) {
        break;
      }
      _validateFlatDirectValue(
        payloadLayout,
        '$path.${isOk ? 'ok' : 'error'}',
        resultPayload,
      );
      return;
    case WASIComponentCanonicalAdapterFlatValueKind.variant:
      if (value is! WasmComponentValueData ||
          value.kind != WasmComponentValueDataKind.variant) {
        break;
      }
      final index = _flatVariantCaseIndex(layout, path, value);
      final case_ = layout.cases[index];
      final variantPayload = value.payload;
      if (case_.value == null) {
        if (variantPayload == null) {
          return;
        }
        break;
      }
      if (variantPayload == null) {
        break;
      }
      _validateFlatDirectValue(
        case_.value!,
        '$path.${case_.label}',
        variantPayload,
      );
      return;
    case WASIComponentCanonicalAdapterFlatValueKind.list:
      final codec = layout.memoryCodec;
      if (_flatLayoutContainsAsyncHandle(layout)) {
        if (value is! WasmComponentValueData ||
            value.kind != WasmComponentValueDataKind.list) {
          break;
        }
        final items = value.itemValues;
        for (var index = 0; index < items.length; index++) {
          _validateFlatDirectValue(
            layout.element!,
            '$path[$index]',
            items[index],
          );
        }
        return;
      }
      if (codec != null) {
        codec.validate(path, value);
        return;
      }
      break;
    case WASIComponentCanonicalAdapterFlatValueKind.flags:
      _flatFlagsToBits(layout, path, value);
      return;
    case WASIComponentCanonicalAdapterFlatValueKind.enumeration:
      _flatEnumerationToIndex(layout, path, value);
      return;
    case WASIComponentCanonicalAdapterFlatValueKind.resource:
      _flatResourceHandleToInt(layout, path, value);
      return;
    case WASIComponentCanonicalAdapterFlatValueKind.errorContext:
      _flatErrorContextHandleToInt(path, value);
      return;
    case WASIComponentCanonicalAdapterFlatValueKind.primitive:
      break;
  }
  throw StateError(
    'WASI component canonical adapter value $path does not match '
    '${layout.kind.name}.',
  );
}

({Object? value, int nextOffset}) _loadFlatValue(
  WASIComponentCanonicalAdapterValuePlan valuePlan,
  List<Object?> flatArgs,
  int offset,
  wasm.Memory? memory,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  final layout = valuePlan.flatLayout;
  if (layout == null) {
    throw UnsupportedError(
      'WASI component canonical adapter value ${valuePlan.path} does not support flat values.',
    );
  }
  return _loadFlatLayout(
    layout,
    valuePlan.path,
    flatArgs,
    offset,
    memory,
    stringEncoding,
    asyncHost,
  );
}

({Object? value, int nextOffset}) _loadFlatLayout(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  List<Object?> flatArgs,
  int offset,
  wasm.Memory? memory,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  final primitive = layout.primitive;
  if (primitive == null) {
    return switch (layout.kind) {
      WASIComponentCanonicalAdapterFlatValueKind.record ||
      WASIComponentCanonicalAdapterFlatValueKind.tuple ||
      WASIComponentCanonicalAdapterFlatValueKind.fixedList =>
        _loadFlatComposite(
          layout,
          path,
          flatArgs,
          offset,
          memory,
          stringEncoding,
          asyncHost,
        ),
      WASIComponentCanonicalAdapterFlatValueKind.flags => _loadFlatFlags(
        layout,
        path,
        flatArgs,
        offset,
      ),
      WASIComponentCanonicalAdapterFlatValueKind.enumeration =>
        _loadFlatEnumeration(layout, path, flatArgs, offset),
      WASIComponentCanonicalAdapterFlatValueKind.list => _loadFlatList(
        layout,
        path,
        flatArgs,
        offset,
        memory,
        stringEncoding,
        asyncHost,
      ),
      WASIComponentCanonicalAdapterFlatValueKind.option => _loadFlatOption(
        layout,
        path,
        flatArgs,
        offset,
        memory,
        stringEncoding,
        asyncHost,
      ),
      WASIComponentCanonicalAdapterFlatValueKind.result => _loadFlatResult(
        layout,
        path,
        flatArgs,
        offset,
        memory,
        stringEncoding,
        asyncHost,
      ),
      WASIComponentCanonicalAdapterFlatValueKind.variant => _loadFlatVariant(
        layout,
        path,
        flatArgs,
        offset,
        memory,
        stringEncoding,
        asyncHost,
      ),
      WASIComponentCanonicalAdapterFlatValueKind.resource => _loadFlatResource(
        layout,
        path,
        flatArgs,
        offset,
      ),
      WASIComponentCanonicalAdapterFlatValueKind.errorContext =>
        _loadFlatErrorContext(path, flatArgs, offset),
      WASIComponentCanonicalAdapterFlatValueKind.stream ||
      WASIComponentCanonicalAdapterFlatValueKind.future =>
        _loadFlatAsyncEndpoint(layout, path, flatArgs, offset, asyncHost),
      WASIComponentCanonicalAdapterFlatValueKind.primitive => throw StateError(
        'Primitive flat layout without a primitive type.',
      ),
    };
  }
  if (primitive == WasmComponentPrimitiveValueType.string) {
    if (offset + 2 > flatArgs.length) {
      throw StateError(
        'WASI component canonical adapter value $path expected 2 flat string arguments.',
      );
    }
    final memoryRef = _requireMemory(memory, path);
    final pointer = _expectFlatU32(path, flatArgs[offset]);
    final length = _expectFlatU32(path, flatArgs[offset + 1]);
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
      'WASI component canonical adapter value $path expected a flat argument.',
    );
  }
  final value = _flatPrimitiveToComponentValue(
    primitive,
    path,
    flatArgs[offset],
  );
  return (value: value, nextOffset: offset + 1);
}

({Object? value, int nextOffset}) _loadFlatFlags(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  List<Object?> flatArgs,
  int offset,
) {
  if (offset >= flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected a flat flags argument.',
    );
  }
  final bits = _expectFlatU32(path, flatArgs[offset]);
  _checkFlatFlagsBits(path, layout.labels, bits);
  return (
    value: WasmComponentValueData(
      kind: WasmComponentValueDataKind.flags,
      rawBytes: Uint8List(0),
      labels: _activeFlatFlagLabels(layout, bits),
    ),
    nextOffset: offset + 1,
  );
}

({Object? value, int nextOffset}) _loadFlatEnumeration(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  List<Object?> flatArgs,
  int offset,
) {
  if (offset >= flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected a flat enum argument.',
    );
  }
  final index = _expectFlatU32(path, flatArgs[offset]);
  _checkFlatEnumIndex(path, layout.labels, index);
  return (
    value: WasmComponentValueData(
      kind: WasmComponentValueDataKind.enumeration,
      rawBytes: Uint8List(0),
      index: index,
      label: layout.labels[index],
    ),
    nextOffset: offset + 1,
  );
}

({Object? value, int nextOffset}) _loadFlatOption(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  List<Object?> flatArgs,
  int offset,
  wasm.Memory? memory,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  if (offset + layout.flatLength > flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected ${layout.flatLength} flat option arguments.',
    );
  }
  final tag = _expectFlatU32(path, flatArgs[offset]);
  final element = layout.element!;
  if (tag == 0) {
    return (
      value: WasmComponentValueData(
        kind: WasmComponentValueDataKind.option,
        rawBytes: Uint8List(0),
        index: 0,
        label: 'none',
        isSome: false,
      ),
      nextOffset: offset + layout.flatLength,
    );
  }
  if (tag == 1) {
    final loaded = _loadFlatLayout(
      element,
      '$path.some',
      flatArgs,
      offset + 1,
      memory,
      stringEncoding,
      asyncHost,
    );
    final associated = _componentPayloadFromFlatValue(
      element,
      '$path.some',
      loaded.value,
    );
    return (
      value: WasmComponentValueData(
        kind: WasmComponentValueDataKind.option,
        rawBytes: Uint8List(0),
        index: 1,
        label: 'some',
        associatedValue: associated is WasmComponentValueData
            ? associated
            : null,
        associatedPayload: associated is WasmComponentValueData
            ? null
            : associated,
        isSome: true,
      ),
      nextOffset: offset + layout.flatLength,
    );
  }
  throw StateError(
    'WASI component canonical adapter value $path has invalid option tag $tag.',
  );
}

({Object? value, int nextOffset}) _loadFlatResult(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  List<Object?> flatArgs,
  int offset,
  wasm.Memory? memory,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  final flatLength = layout.flatLength;
  if (offset + flatLength > flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected $flatLength flat result arguments.',
    );
  }
  final tag = _expectFlatU32(path, flatArgs[offset]);
  if (tag == 0 || tag == 1) {
    final isOk = tag == 0;
    final label = isOk ? 'ok' : 'error';
    final payloadLayout = isOk ? layout.ok : layout.error;
    Object? associated;
    if (payloadLayout != null) {
      final payloadTypes = payloadLayout.flatTypes;
      final joinedTypes = layout.flatTypes.sublist(1);
      final coerced = <Object?>[
        for (var index = 0; index < payloadTypes.length; index++)
          _coerceFlatValue(
            flatArgs[offset + 1 + index],
            joinedTypes[index],
            payloadTypes[index],
            '$path.$label[$index]',
          ),
      ];
      final loaded = _loadFlatLayout(
        payloadLayout,
        '$path.$label',
        coerced,
        0,
        memory,
        stringEncoding,
        asyncHost,
      );
      associated = _componentPayloadFromFlatValue(
        payloadLayout,
        '$path.$label',
        loaded.value,
      );
    }
    return (
      value: WasmComponentValueData(
        kind: WasmComponentValueDataKind.result,
        rawBytes: Uint8List(0),
        index: tag,
        label: label,
        associatedValue: associated is WasmComponentValueData
            ? associated
            : null,
        associatedPayload: associated is WasmComponentValueData
            ? null
            : associated,
        isOk: isOk,
      ),
      nextOffset: offset + flatLength,
    );
  }
  throw StateError(
    'WASI component canonical adapter value $path has invalid result tag $tag.',
  );
}

({Object? value, int nextOffset}) _loadFlatVariant(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  List<Object?> flatArgs,
  int offset,
  wasm.Memory? memory,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  final flatLength = layout.flatLength;
  if (offset + flatLength > flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected $flatLength flat variant arguments.',
    );
  }
  final tag = _expectFlatU32(path, flatArgs[offset]);
  if (tag < 0 || tag >= layout.cases.length) {
    throw StateError(
      'WASI component canonical adapter value $path has invalid variant tag $tag.',
    );
  }
  final case_ = layout.cases[tag];
  final payloadLayout = case_.value;
  Object? associated;
  if (payloadLayout != null) {
    final payloadTypes = payloadLayout.flatTypes;
    final joinedTypes = layout.flatTypes.sublist(1);
    final coerced = <Object?>[
      for (var index = 0; index < payloadTypes.length; index++)
        _coerceFlatValue(
          flatArgs[offset + 1 + index],
          joinedTypes[index],
          payloadTypes[index],
          '$path.${case_.label}[$index]',
        ),
    ];
    final loaded = _loadFlatLayout(
      payloadLayout,
      '$path.${case_.label}',
      coerced,
      0,
      memory,
      stringEncoding,
      asyncHost,
    );
    associated = _componentPayloadFromFlatValue(
      payloadLayout,
      '$path.${case_.label}',
      loaded.value,
    );
  }
  return (
    value: WasmComponentValueData(
      kind: WasmComponentValueDataKind.variant,
      rawBytes: Uint8List(0),
      index: tag,
      label: case_.label,
      associatedValue: associated is WasmComponentValueData ? associated : null,
      associatedPayload: associated is WasmComponentValueData
          ? null
          : associated,
    ),
    nextOffset: offset + flatLength,
  );
}

({Object? value, int nextOffset}) _loadFlatResource(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  List<Object?> flatArgs,
  int offset,
) {
  if (offset >= flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected a flat resource handle.',
    );
  }
  return (
    value: _expectFlatResourceHandle(path, flatArgs[offset]),
    nextOffset: offset + layout.flatLength,
  );
}

({Object? value, int nextOffset}) _loadFlatErrorContext(
  String path,
  List<Object?> flatArgs,
  int offset,
) {
  if (offset >= flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected a flat error-context handle.',
    );
  }
  return (
    value: _expectFlatErrorContextHandle(path, flatArgs[offset]),
    nextOffset: offset + 1,
  );
}

({Object? value, int nextOffset}) _loadFlatAsyncEndpoint(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  List<Object?> flatArgs,
  int offset,
  WASIComponentAsyncHost? asyncHost,
) {
  if (offset >= flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected an async endpoint handle.',
    );
  }
  final host = asyncHost;
  final typeIndex = layout.asyncTypeIndex;
  if (host == null || typeIndex == null) {
    throw StateError(
      'WASI component canonical adapter value $path has no async endpoint host.',
    );
  }
  return (
    value: host.liftReadableEndpoint(
      typeIndex,
      _expectFlatU32(path, flatArgs[offset]),
    ),
    nextOffset: offset + 1,
  );
}

({Object? value, int nextOffset}) _loadFlatList(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  List<Object?> flatArgs,
  int offset,
  wasm.Memory? memory,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  if (offset + 2 > flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected 2 flat list arguments.',
    );
  }
  final memoryRef = _requireMemory(memory, path);
  final pointer = _expectFlatU32(path, flatArgs[offset]);
  final length = _expectFlatU32(path, flatArgs[offset + 1]);
  final value = _requireListMemoryCodec(
    layout,
    path,
  ).loadFlatList(memoryRef, pointer, length, stringEncoding: stringEncoding);
  return (
    value: _flatLayoutContainsAsyncHandle(layout)
        ? _liftAsyncHandlesFromMemory(layout, path, value, asyncHost)
        : value,
    nextOffset: offset + 2,
  );
}

({Object? value, int nextOffset}) _loadFlatComposite(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  List<Object?> flatArgs,
  int offset,
  wasm.Memory? memory,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  final items = <Object?>[];
  var nextOffset = offset;
  for (final field in layout.fields) {
    final fieldPath = '$path.${field.label}';
    final loaded = _loadFlatLayout(
      field.value,
      fieldPath,
      flatArgs,
      nextOffset,
      memory,
      stringEncoding,
      asyncHost,
    );
    items.add(
      _componentPayloadFromFlatValue(field.value, fieldPath, loaded.value),
    );
    nextOffset = loaded.nextOffset;
  }
  if (items.every((item) => item is WasmComponentValueData)) {
    return (
      value: WasmComponentValueData(
        kind: _flatCompositeValueDataKind(layout.kind),
        rawBytes: Uint8List(0),
        items: List<WasmComponentValueData>.unmodifiable(
          items.cast<WasmComponentValueData>(),
        ),
      ),
      nextOffset: nextOffset,
    );
  }
  return (
    value: WasmComponentValueData(
      kind: _flatCompositeValueDataKind(layout.kind),
      rawBytes: Uint8List(0),
      runtimeItems: List<Object?>.unmodifiable(items),
    ),
    nextOffset: nextOffset,
  );
}

List<Object?> _storeFlatValue(
  WASIComponentCanonicalAdapterValuePlan valuePlan,
  Object? value,
  wasm.Memory? memory,
  WASIComponentCanonicalRealloc? realloc,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  final layout = valuePlan.flatLayout;
  if (layout == null) {
    throw UnsupportedError(
      'WASI component canonical adapter value ${valuePlan.path} does not support flat values.',
    );
  }
  if (!_flatLayoutContainsAsyncHandle(layout)) {
    valuePlan.memoryCodec?.validate(valuePlan.path, value);
  }
  return _storeFlatLayout(
    layout,
    valuePlan.path,
    value,
    memory,
    realloc,
    stringEncoding,
    asyncHost,
  );
}

({int alignment, int byteLength})? _flatHandleMemoryLayout(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
) {
  if (layout.kind == WASIComponentCanonicalAdapterFlatValueKind.resource ||
      layout.kind == WASIComponentCanonicalAdapterFlatValueKind.errorContext ||
      layout.kind == WASIComponentCanonicalAdapterFlatValueKind.stream ||
      layout.kind == WASIComponentCanonicalAdapterFlatValueKind.future) {
    return (alignment: 4, byteLength: 4);
  }
  if (layout.kind != WASIComponentCanonicalAdapterFlatValueKind.record &&
      layout.kind != WASIComponentCanonicalAdapterFlatValueKind.tuple &&
      layout.kind != WASIComponentCanonicalAdapterFlatValueKind.fixedList) {
    return null;
  }
  var alignment = 1;
  var byteLength = 0;
  for (final field in layout.fields) {
    final fieldLayout = _flatHandleMemoryLayout(field.value);
    if (fieldLayout == null) {
      return null;
    }
    alignment = alignment < fieldLayout.alignment
        ? fieldLayout.alignment
        : alignment;
    byteLength = _alignCanonicalOffset(byteLength, fieldLayout.alignment);
    byteLength += fieldLayout.byteLength;
  }
  return (
    alignment: alignment,
    byteLength: _alignCanonicalOffset(byteLength, alignment),
  );
}

bool _flatLayoutContainsAsyncHandle(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
) {
  switch (layout.kind) {
    case WASIComponentCanonicalAdapterFlatValueKind.stream:
    case WASIComponentCanonicalAdapterFlatValueKind.future:
      return true;
    case WASIComponentCanonicalAdapterFlatValueKind.record:
    case WASIComponentCanonicalAdapterFlatValueKind.tuple:
    case WASIComponentCanonicalAdapterFlatValueKind.fixedList:
      return layout.fields.any(
        (field) => _flatLayoutContainsAsyncHandle(field.value),
      );
    case WASIComponentCanonicalAdapterFlatValueKind.list:
    case WASIComponentCanonicalAdapterFlatValueKind.option:
      return _flatLayoutContainsAsyncHandle(layout.element!);
    case WASIComponentCanonicalAdapterFlatValueKind.result:
      return (layout.ok != null &&
              _flatLayoutContainsAsyncHandle(layout.ok!)) ||
          (layout.error != null &&
              _flatLayoutContainsAsyncHandle(layout.error!));
    case WASIComponentCanonicalAdapterFlatValueKind.variant:
      return layout.cases.any(
        (case_) =>
            case_.value != null && _flatLayoutContainsAsyncHandle(case_.value!),
      );
    case WASIComponentCanonicalAdapterFlatValueKind.primitive:
    case WASIComponentCanonicalAdapterFlatValueKind.flags:
    case WASIComponentCanonicalAdapterFlatValueKind.enumeration:
    case WASIComponentCanonicalAdapterFlatValueKind.resource:
    case WASIComponentCanonicalAdapterFlatValueKind.errorContext:
      return false;
  }
}

Object? _liftAsyncHandlesFromMemory(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  WASIComponentAsyncHost? asyncHost,
) {
  switch (layout.kind) {
    case WASIComponentCanonicalAdapterFlatValueKind.stream:
    case WASIComponentCanonicalAdapterFlatValueKind.future:
      final rawHandle = value is WasmComponentValueData ? value.integer : value;
      return _loadFlatAsyncEndpoint(
        layout,
        path,
        <Object?>[rawHandle],
        0,
        asyncHost,
      ).value;
    case WASIComponentCanonicalAdapterFlatValueKind.record:
    case WASIComponentCanonicalAdapterFlatValueKind.tuple:
    case WASIComponentCanonicalAdapterFlatValueKind.fixedList:
    case WASIComponentCanonicalAdapterFlatValueKind.list:
      return _liftAsyncCompositeFromMemory(layout, path, value, asyncHost);
    case WASIComponentCanonicalAdapterFlatValueKind.option:
    case WASIComponentCanonicalAdapterFlatValueKind.result:
    case WASIComponentCanonicalAdapterFlatValueKind.variant:
      return _liftAsyncVariantFromMemory(layout, path, value, asyncHost);
    case WASIComponentCanonicalAdapterFlatValueKind.primitive:
    case WASIComponentCanonicalAdapterFlatValueKind.flags:
    case WASIComponentCanonicalAdapterFlatValueKind.enumeration:
    case WASIComponentCanonicalAdapterFlatValueKind.resource:
    case WASIComponentCanonicalAdapterFlatValueKind.errorContext:
      return value;
  }
}

Object? _liftAsyncCompositeFromMemory(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  WASIComponentAsyncHost? asyncHost,
) {
  if (value is! WasmComponentValueData ||
      value.kind != _flatValueDataKind(layout.kind)) {
    throw StateError(
      'WASI component canonical adapter value $path expected '
      '${layout.kind.name} memory data.',
    );
  }
  final sourceItems = value.items;
  final fieldLayouts =
      layout.kind == WASIComponentCanonicalAdapterFlatValueKind.list
      ? List<WASIComponentCanonicalAdapterFlatValuePlan>.filled(
          sourceItems.length,
          layout.element!,
        )
      : <WASIComponentCanonicalAdapterFlatValuePlan>[
          for (final field in layout.fields) field.value,
        ];
  if (sourceItems.length != fieldLayouts.length) {
    throw StateError(
      'WASI component canonical adapter value $path has '
      '${sourceItems.length} memory items; expected ${fieldLayouts.length}.',
    );
  }
  final items = <Object?>[
    for (var index = 0; index < sourceItems.length; index++)
      _liftAsyncHandlesFromMemory(
        fieldLayouts[index],
        '$path[$index]',
        sourceItems[index],
        asyncHost,
      ),
  ];
  if (items.every((item) => item is WasmComponentValueData)) {
    return WasmComponentValueData(
      kind: value.kind,
      rawBytes: value.rawBytes,
      items: List<WasmComponentValueData>.unmodifiable(
        items.cast<WasmComponentValueData>(),
      ),
    );
  }
  return WasmComponentValueData(
    kind: value.kind,
    rawBytes: value.rawBytes,
    runtimeItems: List<Object?>.unmodifiable(items),
  );
}

Object? _liftAsyncVariantFromMemory(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  WASIComponentAsyncHost? asyncHost,
) {
  if (value is! WasmComponentValueData ||
      value.kind != _flatValueDataKind(layout.kind)) {
    throw StateError(
      'WASI component canonical adapter value $path expected '
      '${layout.kind.name} memory data.',
    );
  }
  final payloadLayout = _selectedVariantPayloadLayout(layout, path, value);
  final payload = value.payload;
  final liftedPayload = payloadLayout == null
      ? null
      : _liftAsyncHandlesFromMemory(
          payloadLayout,
          '$path.${value.label ?? value.index}',
          payload,
          asyncHost,
        );
  return _copyVariantValue(value, liftedPayload);
}

Object? _lowerAsyncHandlesForMemory(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  WASIComponentAsyncHost? asyncHost,
) {
  switch (layout.kind) {
    case WASIComponentCanonicalAdapterFlatValueKind.stream:
    case WASIComponentCanonicalAdapterFlatValueKind.future:
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.integer,
        rawBytes: Uint8List(0),
        integer: _storeFlatAsyncEndpoint(layout, path, value, asyncHost),
      );
    case WASIComponentCanonicalAdapterFlatValueKind.record:
    case WASIComponentCanonicalAdapterFlatValueKind.tuple:
    case WASIComponentCanonicalAdapterFlatValueKind.fixedList:
    case WASIComponentCanonicalAdapterFlatValueKind.list:
      return _lowerAsyncCompositeForMemory(layout, path, value, asyncHost);
    case WASIComponentCanonicalAdapterFlatValueKind.option:
    case WASIComponentCanonicalAdapterFlatValueKind.result:
    case WASIComponentCanonicalAdapterFlatValueKind.variant:
      return _lowerAsyncVariantForMemory(layout, path, value, asyncHost);
    case WASIComponentCanonicalAdapterFlatValueKind.primitive:
    case WASIComponentCanonicalAdapterFlatValueKind.flags:
    case WASIComponentCanonicalAdapterFlatValueKind.enumeration:
    case WASIComponentCanonicalAdapterFlatValueKind.resource:
    case WASIComponentCanonicalAdapterFlatValueKind.errorContext:
      return value is WasmComponentValueData
          ? value
          : _componentValueDataFromFlatValue(layout, path, value);
  }
}

WasmComponentValueData _lowerAsyncCompositeForMemory(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  WASIComponentAsyncHost? asyncHost,
) {
  final expectedKind = _flatValueDataKind(layout.kind);
  final sourceItems = switch (value) {
    WasmComponentValueData() when value.kind == expectedKind =>
      value.itemValues,
    List<Object?>()
        when layout.kind == WASIComponentCanonicalAdapterFlatValueKind.tuple =>
      value,
    _ => null,
  };
  if (sourceItems == null) {
    throw StateError(
      'WASI component canonical adapter value $path expected '
      '${layout.kind.name} runtime data.',
    );
  }
  final fieldLayouts =
      layout.kind == WASIComponentCanonicalAdapterFlatValueKind.list
      ? List<WASIComponentCanonicalAdapterFlatValuePlan>.filled(
          sourceItems.length,
          layout.element!,
        )
      : <WASIComponentCanonicalAdapterFlatValuePlan>[
          for (final field in layout.fields) field.value,
        ];
  if (sourceItems.length != fieldLayouts.length) {
    throw StateError(
      'WASI component canonical adapter value $path has '
      '${sourceItems.length} runtime items; expected ${fieldLayouts.length}.',
    );
  }
  final items = <WasmComponentValueData>[];
  for (var index = 0; index < sourceItems.length; index++) {
    final item = _lowerAsyncHandlesForMemory(
      fieldLayouts[index],
      '$path[$index]',
      sourceItems[index],
      asyncHost,
    );
    if (item is! WasmComponentValueData) {
      throw StateError(
        'WASI component canonical adapter value $path[$index] did not lower '
        'to canonical memory data.',
      );
    }
    items.add(item);
  }
  return WasmComponentValueData(
    kind: expectedKind,
    rawBytes: Uint8List(0),
    items: List<WasmComponentValueData>.unmodifiable(items),
  );
}

WasmComponentValueData _lowerAsyncVariantForMemory(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  WASIComponentAsyncHost? asyncHost,
) {
  if (value is! WasmComponentValueData ||
      value.kind != _flatValueDataKind(layout.kind)) {
    throw StateError(
      'WASI component canonical adapter value $path expected '
      '${layout.kind.name} runtime data.',
    );
  }
  final payloadLayout = _selectedVariantPayloadLayout(layout, path, value);
  final payload = value.payload;
  final memoryPayload = payloadLayout == null
      ? null
      : _lowerAsyncHandlesForMemory(
          payloadLayout,
          '$path.${value.label ?? value.index}',
          payload,
          asyncHost,
        );
  if (memoryPayload != null && memoryPayload is! WasmComponentValueData) {
    throw StateError(
      'WASI component canonical adapter value $path payload did not lower '
      'to canonical memory data.',
    );
  }
  return _copyVariantValue(value, memoryPayload);
}

WASIComponentCanonicalAdapterFlatValuePlan? _selectedVariantPayloadLayout(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  WasmComponentValueData value,
) {
  return switch (layout.kind) {
    WASIComponentCanonicalAdapterFlatValueKind.option =>
      _flatOptionIsSome(layout, path, value) ? layout.element : null,
    WASIComponentCanonicalAdapterFlatValueKind.result =>
      _flatResultIsOk(layout, path, value) ? layout.ok : layout.error,
    WASIComponentCanonicalAdapterFlatValueKind.variant =>
      layout.cases[_flatVariantCaseIndex(layout, path, value)].value,
    _ => throw StateError(
      'WASI component canonical adapter value $path is not a variant.',
    ),
  };
}

WasmComponentValueData _copyVariantValue(
  WasmComponentValueData value,
  Object? payload,
) {
  return WasmComponentValueData(
    kind: value.kind,
    rawBytes: value.rawBytes,
    index: value.index,
    label: value.label,
    associatedValue: payload is WasmComponentValueData ? payload : null,
    associatedPayload: payload is WasmComponentValueData ? null : payload,
    isSome: value.isSome,
    isOk: value.isOk,
  );
}

void _checkAllocatedMemoryRange(
  wasm.Memory memory,
  int pointer,
  int byteLength,
  int alignment,
  String name,
) {
  RangeError.checkValueInInterval(pointer, 0, 0xffffffff, '$name pointer');
  if (pointer % alignment != 0) {
    throw StateError('$name pointer must be $alignment-byte aligned.');
  }
  final memoryLength = memory.buffer.lengthInBytes;
  if (pointer > memoryLength || byteLength > memoryLength - pointer) {
    throw RangeError.range(
      pointer + byteLength,
      0,
      memoryLength,
      '$name pointer + byte length',
    );
  }
}

Object? _loadFlatHandleMemory(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  wasm.Memory memory,
  int pointer,
  ({int alignment, int byteLength}) memoryLayout,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  _checkAllocatedMemoryRange(
    memory,
    pointer,
    memoryLayout.byteLength,
    memoryLayout.alignment,
    path,
  );
  final flatArgs = <Object?>[];
  _collectFlatHandleMemoryValues(
    layout,
    ByteData.view(memory.buffer),
    pointer,
    flatArgs,
  );
  final loaded = _loadFlatLayout(
    layout,
    path,
    flatArgs,
    0,
    memory,
    stringEncoding,
    asyncHost,
  );
  if (loaded.nextOffset != flatArgs.length) {
    throw StateError(
      'WASI component canonical adapter value $path consumed '
      '${loaded.nextOffset} indirect handle values, got ${flatArgs.length}.',
    );
  }
  return loaded.value;
}

void _collectFlatHandleMemoryValues(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  ByteData data,
  int pointer,
  List<Object?> flatArgs,
) {
  if (layout.kind == WASIComponentCanonicalAdapterFlatValueKind.resource ||
      layout.kind == WASIComponentCanonicalAdapterFlatValueKind.errorContext ||
      layout.kind == WASIComponentCanonicalAdapterFlatValueKind.stream ||
      layout.kind == WASIComponentCanonicalAdapterFlatValueKind.future) {
    flatArgs.add(data.getUint32(pointer, Endian.little));
    return;
  }
  var offset = 0;
  for (final field in layout.fields) {
    final fieldLayout = _flatHandleMemoryLayout(field.value)!;
    offset = _alignCanonicalOffset(offset, fieldLayout.alignment);
    _collectFlatHandleMemoryValues(
      field.value,
      data,
      pointer + offset,
      flatArgs,
    );
    offset += fieldLayout.byteLength;
  }
}

void _storeFlatHandleMemory(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  wasm.Memory memory,
  int pointer,
  ({int alignment, int byteLength}) memoryLayout,
  WASIComponentAsyncHost? asyncHost,
) {
  if (pointer % memoryLayout.alignment != 0) {
    throw StateError(
      'WASI component canonical adapter value $path pointer must be '
      '${memoryLayout.alignment}-byte aligned.',
    );
  }
  final data = ByteData.view(memory.buffer);
  if (pointer > data.lengthInBytes ||
      memoryLayout.byteLength > data.lengthInBytes - pointer) {
    throw RangeError.range(
      pointer + memoryLayout.byteLength,
      0,
      data.lengthInBytes,
      '$path pointer + byte length',
    );
  }
  _storeFlatHandleMemoryLayout(layout, path, value, data, pointer, asyncHost);
}

void _storeFlatHandleMemoryLayout(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  ByteData data,
  int pointer,
  WASIComponentAsyncHost? asyncHost,
) {
  if (layout.kind == WASIComponentCanonicalAdapterFlatValueKind.stream ||
      layout.kind == WASIComponentCanonicalAdapterFlatValueKind.future) {
    data.setUint32(
      pointer,
      _storeFlatAsyncEndpoint(layout, path, value, asyncHost),
      Endian.little,
    );
    return;
  }
  if (layout.kind == WASIComponentCanonicalAdapterFlatValueKind.resource) {
    data.setUint32(
      pointer,
      _flatResourceHandleToInt(layout, path, value),
      Endian.little,
    );
    return;
  }
  if (layout.kind == WASIComponentCanonicalAdapterFlatValueKind.errorContext) {
    data.setUint32(
      pointer,
      _flatErrorContextHandleToInt(path, value),
      Endian.little,
    );
    return;
  }
  final items = switch (value) {
    WasmComponentValueData()
        when value.kind == _flatCompositeValueDataKind(layout.kind) =>
      value.itemValues,
    List<Object?>()
        when layout.kind == WASIComponentCanonicalAdapterFlatValueKind.tuple =>
      value,
    _ => null,
  };
  if (items == null || items.length != layout.fields.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected '
      '${layout.kind.name} data.',
    );
  }
  var offset = 0;
  for (var index = 0; index < layout.fields.length; index++) {
    final field = layout.fields[index];
    final fieldLayout = _flatHandleMemoryLayout(field.value)!;
    offset = _alignCanonicalOffset(offset, fieldLayout.alignment);
    _storeFlatHandleMemoryLayout(
      field.value,
      '$path.${field.label}',
      items[index],
      data,
      pointer + offset,
      asyncHost,
    );
    offset += fieldLayout.byteLength;
  }
}

List<Object?> _storeFlatLayout(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  wasm.Memory? memory,
  WASIComponentCanonicalRealloc? realloc,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  final primitive = layout.primitive;
  if (primitive == null) {
    return switch (layout.kind) {
      WASIComponentCanonicalAdapterFlatValueKind.record ||
      WASIComponentCanonicalAdapterFlatValueKind.tuple ||
      WASIComponentCanonicalAdapterFlatValueKind.fixedList =>
        _storeFlatComposite(
          layout,
          path,
          value,
          memory,
          realloc,
          stringEncoding,
          asyncHost,
        ),
      WASIComponentCanonicalAdapterFlatValueKind.flags => <Object?>[
        _flatFlagsToBits(layout, path, value),
      ],
      WASIComponentCanonicalAdapterFlatValueKind.enumeration => <Object?>[
        _flatEnumerationToIndex(layout, path, value),
      ],
      WASIComponentCanonicalAdapterFlatValueKind.list => _storeFlatList(
        layout,
        path,
        value,
        memory,
        realloc,
        stringEncoding,
        asyncHost,
      ),
      WASIComponentCanonicalAdapterFlatValueKind.option => _storeFlatOption(
        layout,
        path,
        value,
        memory,
        realloc,
        stringEncoding,
        asyncHost,
      ),
      WASIComponentCanonicalAdapterFlatValueKind.result => _storeFlatResult(
        layout,
        path,
        value,
        memory,
        realloc,
        stringEncoding,
        asyncHost,
      ),
      WASIComponentCanonicalAdapterFlatValueKind.variant => _storeFlatVariant(
        layout,
        path,
        value,
        memory,
        realloc,
        stringEncoding,
        asyncHost,
      ),
      WASIComponentCanonicalAdapterFlatValueKind.resource => <Object?>[
        _flatResourceHandleToInt(layout, path, value),
      ],
      WASIComponentCanonicalAdapterFlatValueKind.errorContext => <Object?>[
        _flatErrorContextHandleToInt(path, value),
      ],
      WASIComponentCanonicalAdapterFlatValueKind.stream ||
      WASIComponentCanonicalAdapterFlatValueKind.future => <Object?>[
        _storeFlatAsyncEndpoint(layout, path, value, asyncHost),
      ],
      WASIComponentCanonicalAdapterFlatValueKind.primitive => throw StateError(
        'Primitive flat layout without a primitive type.',
      ),
    };
  }
  if (primitive == WasmComponentPrimitiveValueType.string) {
    final memoryRef = _requireMemory(memory, path);
    final memoryString = writeWASIComponentCanonicalString(
      memoryRef,
      _requireRealloc(realloc, path),
      value as String,
      stringEncoding,
    );
    return <Object?>[memoryString.pointer, memoryString.canonicalLength];
  }
  return <Object?>[_componentPrimitiveToFlatValue(primitive, path, value)];
}

List<Object?> _storeFlatComposite(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  wasm.Memory? memory,
  WASIComponentCanonicalRealloc? realloc,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  final items = switch (value) {
    WasmComponentValueData()
        when value.kind == _flatCompositeValueDataKind(layout.kind) =>
      value.itemValues,
    List<Object?>()
        when layout.kind == WASIComponentCanonicalAdapterFlatValueKind.tuple =>
      value,
    _ => null,
  };
  if (items == null || items.length != layout.fields.length) {
    throw StateError(
      'WASI component canonical adapter value $path expected ${layout.kind.name} data.',
    );
  }
  final flat = <Object?>[];
  for (var i = 0; i < layout.fields.length; i++) {
    final field = layout.fields[i];
    flat.addAll(
      _storeFlatLayout(
        field.value,
        '$path.${field.label}',
        items[i],
        memory,
        realloc,
        stringEncoding,
        asyncHost,
      ),
    );
  }
  return flat;
}

WasmComponentValueData _componentValueDataFromFlatValue(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
) {
  final primitive = layout.primitive;
  if (layout.kind == WASIComponentCanonicalAdapterFlatValueKind.resource) {
    return _resourceHandleDataFromFlatValue(path, value);
  }
  if (layout.kind == WASIComponentCanonicalAdapterFlatValueKind.errorContext) {
    return _errorContextHandleDataFromFlatValue(path, value);
  }
  if (primitive == null) {
    return _nonPrimitiveDataFromComponentValue(layout, path, value);
  }
  return _primitiveDataFromComponentValue(primitive, path, value);
}

Object? _componentPayloadFromFlatValue(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
) {
  if (layout.kind == WASIComponentCanonicalAdapterFlatValueKind.stream ||
      layout.kind == WASIComponentCanonicalAdapterFlatValueKind.future) {
    return value;
  }
  return _componentValueDataFromFlatValue(layout, path, value);
}

int _storeFlatAsyncEndpoint(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  WASIComponentAsyncHost? asyncHost,
) {
  final host = asyncHost;
  final typeIndex = layout.asyncTypeIndex;
  if (host == null || typeIndex == null) {
    throw StateError(
      'WASI component canonical adapter value $path has no async endpoint host.',
    );
  }
  final endpoint = value;
  if (endpoint == null) {
    throw StateError(
      'WASI component canonical adapter value $path expected an async endpoint.',
    );
  }
  return host.lowerReadableEndpoint(typeIndex, endpoint);
}

WasmComponentValueData _nonPrimitiveDataFromComponentValue(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
) {
  if (value is WasmComponentValueData &&
      value.kind == _flatValueDataKind(layout.kind)) {
    return value;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected ${layout.kind.name} data.',
  );
}

WasmComponentValueData _primitiveDataFromComponentValue(
  WasmComponentPrimitiveValueType primitive,
  String path,
  Object? value,
) {
  switch (primitive) {
    case WasmComponentPrimitiveValueType.boolean:
      if (value is bool) {
        return WasmComponentValueData(
          kind: WasmComponentValueDataKind.boolean,
          rawBytes: Uint8List(0),
          boolean: value,
        );
      }
    case WasmComponentPrimitiveValueType.s8:
    case WasmComponentPrimitiveValueType.u8:
    case WasmComponentPrimitiveValueType.s16:
    case WasmComponentPrimitiveValueType.u16:
    case WasmComponentPrimitiveValueType.s32:
    case WasmComponentPrimitiveValueType.u32:
    case WasmComponentPrimitiveValueType.s64:
    case WasmComponentPrimitiveValueType.u64:
      if (value is int) {
        return WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: value,
        );
      }
    case WasmComponentPrimitiveValueType.f32:
    case WasmComponentPrimitiveValueType.f64:
      if (value is num) {
        return WasmComponentValueData(
          kind: WasmComponentValueDataKind.floatingPoint,
          rawBytes: Uint8List(0),
          floatingPoint: value.toDouble(),
        );
      }
    case WasmComponentPrimitiveValueType.char:
    case WasmComponentPrimitiveValueType.string:
      if (value is String) {
        return WasmComponentValueData(
          kind: WasmComponentValueDataKind.string,
          rawBytes: Uint8List(0),
          string: value,
        );
      }
    case WasmComponentPrimitiveValueType.errorContext:
      break;
  }
  throw StateError(
    'WASI component canonical adapter value $path does not match ${primitive.name}.',
  );
}

WasmComponentValueDataKind _flatCompositeValueDataKind(
  WASIComponentCanonicalAdapterFlatValueKind kind,
) {
  return switch (kind) {
    WASIComponentCanonicalAdapterFlatValueKind.record =>
      WasmComponentValueDataKind.record,
    WASIComponentCanonicalAdapterFlatValueKind.tuple =>
      WasmComponentValueDataKind.tuple,
    WASIComponentCanonicalAdapterFlatValueKind.fixedList =>
      WasmComponentValueDataKind.fixedList,
    WASIComponentCanonicalAdapterFlatValueKind.primitive ||
    WASIComponentCanonicalAdapterFlatValueKind.flags ||
    WASIComponentCanonicalAdapterFlatValueKind.enumeration ||
    WASIComponentCanonicalAdapterFlatValueKind.list ||
    WASIComponentCanonicalAdapterFlatValueKind.option ||
    WASIComponentCanonicalAdapterFlatValueKind.result ||
    WASIComponentCanonicalAdapterFlatValueKind.variant ||
    WASIComponentCanonicalAdapterFlatValueKind.resource ||
    WASIComponentCanonicalAdapterFlatValueKind.errorContext ||
    WASIComponentCanonicalAdapterFlatValueKind.stream ||
    WASIComponentCanonicalAdapterFlatValueKind.future => throw StateError(
      'Flat layout is not composite.',
    ),
  };
}

WasmComponentValueDataKind _flatValueDataKind(
  WASIComponentCanonicalAdapterFlatValueKind kind,
) {
  return switch (kind) {
    WASIComponentCanonicalAdapterFlatValueKind.record =>
      WasmComponentValueDataKind.record,
    WASIComponentCanonicalAdapterFlatValueKind.tuple =>
      WasmComponentValueDataKind.tuple,
    WASIComponentCanonicalAdapterFlatValueKind.fixedList =>
      WasmComponentValueDataKind.fixedList,
    WASIComponentCanonicalAdapterFlatValueKind.flags =>
      WasmComponentValueDataKind.flags,
    WASIComponentCanonicalAdapterFlatValueKind.enumeration =>
      WasmComponentValueDataKind.enumeration,
    WASIComponentCanonicalAdapterFlatValueKind.list =>
      WasmComponentValueDataKind.list,
    WASIComponentCanonicalAdapterFlatValueKind.option =>
      WasmComponentValueDataKind.option,
    WASIComponentCanonicalAdapterFlatValueKind.result =>
      WasmComponentValueDataKind.result,
    WASIComponentCanonicalAdapterFlatValueKind.variant =>
      WasmComponentValueDataKind.variant,
    WASIComponentCanonicalAdapterFlatValueKind.resource =>
      WasmComponentValueDataKind.integer,
    WASIComponentCanonicalAdapterFlatValueKind.errorContext =>
      WasmComponentValueDataKind.integer,
    WASIComponentCanonicalAdapterFlatValueKind.primitive ||
    WASIComponentCanonicalAdapterFlatValueKind.stream ||
    WASIComponentCanonicalAdapterFlatValueKind.future => throw StateError(
      'Primitive flat layouts use primitive value data.',
    ),
  };
}

int _flatResourceHandleToInt(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
) {
  final direct = value is WasmComponentValueData
      ? _resourceHandleFromData(layout, path, value)
      : value;
  return _expectFlatResourceHandle(path, direct);
}

WasmComponentValueData _resourceHandleDataFromFlatValue(
  String path,
  Object? value,
) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: _expectFlatResourceHandle(path, value),
  );
}

Object? _resourceHandleFromData(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  WasmComponentValueData value,
) {
  if (value.kind == WasmComponentValueDataKind.integer &&
      value.integer is int) {
    return value.integer;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected ${layout.handleKind!.name} resource handle data.',
  );
}

int _flatErrorContextHandleToInt(String path, Object? value) {
  final direct = value is WasmComponentValueData
      ? _errorContextHandleFromData(path, value)
      : value;
  return _expectFlatErrorContextHandle(path, direct);
}

WasmComponentValueData _errorContextHandleDataFromFlatValue(
  String path,
  Object? value,
) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: _expectFlatErrorContextHandle(path, value),
  );
}

Object? _errorContextHandleFromData(String path, WasmComponentValueData value) {
  if (value.kind == WasmComponentValueDataKind.integer &&
      value.integer is int) {
    return value.integer;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected error-context handle data.',
  );
}

int _flatFlagsToBits(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.flags) {
    throw StateError(
      'WASI component canonical adapter value $path expected flags data.',
    );
  }
  var bits = 0;
  for (final label in value.labels) {
    final index = layout.labels.indexOf(label);
    if (index < 0) {
      throw StateError(
        'WASI component canonical adapter value $path has unknown flag $label.',
      );
    }
    bits |= 1 << index;
  }
  return bits;
}

int _flatEnumerationToIndex(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.enumeration) {
    throw StateError(
      'WASI component canonical adapter value $path expected enum data.',
    );
  }
  final index = value.index;
  if (index != null) {
    _checkFlatEnumIndex(path, layout.labels, index);
    return index;
  }
  final label = value.label;
  if (label != null) {
    final index = layout.labels.indexOf(label);
    if (index >= 0) {
      return index;
    }
  }
  throw StateError(
    'WASI component canonical adapter value $path expected a known enum case.',
  );
}

List<String> _activeFlatFlagLabels(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  int bits,
) {
  final active = <String>[];
  for (var i = 0; i < layout.labels.length; i++) {
    if ((bits & (1 << i)) != 0) {
      active.add(layout.labels[i]);
    }
  }
  return List<String>.unmodifiable(active);
}

void _checkFlatFlagsBits(String path, List<String> labels, int bits) {
  if (bits < 0) {
    throw StateError(
      'WASI component canonical adapter value $path expected unsigned flags.',
    );
  }
  final mask = (1 << labels.length) - 1;
  if ((bits & ~mask) != 0) {
    throw StateError(
      'WASI component canonical adapter value $path has unknown flag bits.',
    );
  }
}

void _checkFlatEnumIndex(String path, List<String> labels, int index) {
  if (index < 0 || index >= labels.length) {
    throw StateError(
      'WASI component canonical adapter value $path has invalid enum index $index.',
    );
  }
}

List<Object?> _storeFlatOption(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  wasm.Memory? memory,
  WASIComponentCanonicalRealloc? realloc,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.option) {
    throw StateError(
      'WASI component canonical adapter value $path expected option data.',
    );
  }
  final element = layout.element!;
  final isSome = _flatOptionIsSome(layout, path, value);
  if (!isSome) {
    return <Object?>[0, ..._zeroFlatValues(element)];
  }
  final associated = value.payload;
  if (associated == null) {
    throw StateError(
      'WASI component canonical adapter value $path.some needs payload.',
    );
  }
  return <Object?>[
    1,
    ..._storeFlatLayout(
      element,
      '$path.some',
      associated,
      memory,
      realloc,
      stringEncoding,
      asyncHost,
    ),
  ];
}

bool _flatOptionIsSome(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  WasmComponentValueData value,
) {
  return _flatCaseIndex(layout, path, value) == 1;
}

List<Object?> _storeFlatResult(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  wasm.Memory? memory,
  WASIComponentCanonicalRealloc? realloc,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.result) {
    throw StateError(
      'WASI component canonical adapter value $path expected result data.',
    );
  }
  final isOk = _flatResultIsOk(layout, path, value);
  final tag = isOk ? 0 : 1;
  final label = isOk ? 'ok' : 'error';
  final payloadLayout = isOk ? layout.ok : layout.error;
  return _storeFlatTagPayload(
    layout,
    path,
    tag,
    label,
    payloadLayout,
    value.payload,
    memory,
    realloc,
    stringEncoding,
    asyncHost,
  );
}

bool _flatResultIsOk(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  WasmComponentValueData value,
) {
  return _flatCaseIndex(layout, path, value) == 0;
}

List<Object?> _storeFlatVariant(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  wasm.Memory? memory,
  WASIComponentCanonicalRealloc? realloc,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.variant) {
    throw StateError(
      'WASI component canonical adapter value $path expected variant data.',
    );
  }
  final index = _flatVariantCaseIndex(layout, path, value);
  final case_ = layout.cases[index];
  return _storeFlatTagPayload(
    layout,
    path,
    index,
    case_.label,
    case_.value,
    value.payload,
    memory,
    realloc,
    stringEncoding,
    asyncHost,
  );
}

List<Object?> _storeFlatTagPayload(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  int tag,
  String label,
  WASIComponentCanonicalAdapterFlatValuePlan? payloadLayout,
  Object? associated,
  wasm.Memory? memory,
  WASIComponentCanonicalRealloc? realloc,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  final flatLength = layout.flatLength;
  final flat = <Object?>[tag];
  if (payloadLayout == null) {
    if (associated != null) {
      throw StateError(
        'WASI component canonical adapter value $path.$label does not take payload.',
      );
    }
  } else {
    if (associated == null) {
      throw StateError(
        'WASI component canonical adapter value $path.$label needs payload.',
      );
    }
    final payload = _storeFlatLayout(
      payloadLayout,
      '$path.$label',
      associated,
      memory,
      realloc,
      stringEncoding,
      asyncHost,
    );
    final payloadTypes = payloadLayout.flatTypes;
    final joinedTypes = layout.flatTypes.sublist(1);
    flat.addAll([
      for (var index = 0; index < payload.length; index++)
        _coerceFlatValue(
          payload[index],
          payloadTypes[index],
          joinedTypes[index],
          '$path.$label[$index]',
        ),
    ]);
  }
  if (flat.length > flatLength) {
    throw StateError(
      'WASI component canonical adapter value $path returned too many flat payload values.',
    );
  }
  final joinedTypes = layout.flatTypes.sublist(1);
  while (flat.length < flatLength) {
    flat.add(_zeroFlatValue(joinedTypes[flat.length - 1]));
  }
  return flat;
}

int _flatVariantCaseIndex(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  WasmComponentValueData value,
) {
  return _flatCaseIndex(layout, path, value);
}

int _flatCaseIndex(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  WasmComponentValueData value,
) {
  final labels = switch (layout.kind) {
    WASIComponentCanonicalAdapterFlatValueKind.option => const <String>[
      'none',
      'some',
    ],
    WASIComponentCanonicalAdapterFlatValueKind.result => const <String>[
      'ok',
      'error',
    ],
    WASIComponentCanonicalAdapterFlatValueKind.variant => <String>[
      for (final case_ in layout.cases) case_.label,
    ],
    _ => throw StateError(
      'WASI component canonical adapter value $path is not a variant.',
    ),
  };

  int? selected;
  void select(int index) {
    if (selected != null && selected != index) {
      throw StateError(
        'WASI component canonical adapter value $path has conflicting case selectors.',
      );
    }
    selected = index;
  }

  final index = value.index;
  if (index != null) {
    if (index >= 0 && index < labels.length) {
      select(index);
    } else {
      throw StateError(
        'WASI component canonical adapter value $path has invalid case index $index.',
      );
    }
  }
  final label = value.label;
  if (label != null) {
    final labelIndex = labels.indexOf(label);
    if (labelIndex >= 0) {
      select(labelIndex);
    } else {
      throw StateError(
        'WASI component canonical adapter value $path has unknown case label $label.',
      );
    }
  }

  switch (layout.kind) {
    case WASIComponentCanonicalAdapterFlatValueKind.option:
      final isSome = value.isSome;
      if (isSome != null) {
        select(isSome ? 1 : 0);
      }
    case WASIComponentCanonicalAdapterFlatValueKind.result:
      final isOk = value.isOk;
      if (isOk != null) {
        select(isOk ? 0 : 1);
      }
    case WASIComponentCanonicalAdapterFlatValueKind.variant:
      break;
    default:
      throw StateError(
        'WASI component canonical adapter value $path is not a variant.',
      );
  }

  if (selected != null) {
    return selected!;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected a known variant case.',
  );
}

List<Object?> _zeroFlatValues(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
) {
  return List<Object?>.filled(layout.flatLength, 0, growable: false);
}

List<Object?> _storeFlatList(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
  Object? value,
  wasm.Memory? memory,
  WASIComponentCanonicalRealloc? realloc,
  WASIComponentCanonicalStringEncoding stringEncoding,
  WASIComponentAsyncHost? asyncHost,
) {
  final memoryRef = _requireMemory(memory, path);
  final memoryValue = _flatLayoutContainsAsyncHandle(layout)
      ? _lowerAsyncHandlesForMemory(layout, path, value, asyncHost)
      : value;
  final flat = _requireListMemoryCodec(layout, path).storeFlatList(
    memoryRef,
    memoryValue,
    realloc: realloc,
    stringEncoding: stringEncoding,
  );
  return <Object?>[flat.pointer, flat.length];
}

WASIComponentCanonicalValueMemoryCodec _requireListMemoryCodec(
  WASIComponentCanonicalAdapterFlatValuePlan layout,
  String path,
) {
  final codec = layout.memoryCodec;
  if (codec != null) {
    return codec;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected list memory codec.',
  );
}

Object? _flatPrimitiveToComponentValue(
  WasmComponentPrimitiveValueType primitive,
  String path,
  Object? value,
) {
  return switch (primitive) {
    WasmComponentPrimitiveValueType.boolean => _expectFlatU32(path, value) != 0,
    WasmComponentPrimitiveValueType.s8 => _expectFlatU32(
      path,
      value,
    ).toSigned(8),
    WasmComponentPrimitiveValueType.u8 => _expectFlatU32(path, value) & 0xff,
    WasmComponentPrimitiveValueType.s16 => _expectFlatU32(
      path,
      value,
    ).toSigned(16),
    WasmComponentPrimitiveValueType.u16 => _expectFlatU32(path, value) & 0xffff,
    WasmComponentPrimitiveValueType.s32 => _expectFlatU32(
      path,
      value,
    ).toSigned(32),
    WasmComponentPrimitiveValueType.u32 => _expectFlatU32(path, value),
    WasmComponentPrimitiveValueType.s64 => _canonicalSignedI64(
      _expectFlatU64Bits(path, value),
    ),
    WasmComponentPrimitiveValueType.u64 => _canonicalIntegerValue(
      _expectFlatU64Bits(path, value),
    ),
    WasmComponentPrimitiveValueType.f32 ||
    WasmComponentPrimitiveValueType.f64 => _expectFlatNum(path, value),
    WasmComponentPrimitiveValueType.char => _flatCharToString(
      path,
      _expectFlatU32(path, value),
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
  final direct = value is WasmComponentValueData
      ? _primitiveValueFromData(primitive, path, value)
      : value;
  return switch (primitive) {
    WasmComponentPrimitiveValueType.boolean => (direct as bool) ? 1 : 0,
    WasmComponentPrimitiveValueType.s8 ||
    WasmComponentPrimitiveValueType.u8 ||
    WasmComponentPrimitiveValueType.s16 ||
    WasmComponentPrimitiveValueType.u16 ||
    WasmComponentPrimitiveValueType.s32 ||
    WasmComponentPrimitiveValueType.u32 => direct as int,
    WasmComponentPrimitiveValueType.s64 ||
    WasmComponentPrimitiveValueType.u64 => _coreI64Value(direct as Object),
    WasmComponentPrimitiveValueType.f32 ||
    WasmComponentPrimitiveValueType.f64 => direct as num,
    WasmComponentPrimitiveValueType.char => _stringToFlatChar(path, direct),
    WasmComponentPrimitiveValueType.string => throw StateError(
      'String flat values are handled separately.',
    ),
    WasmComponentPrimitiveValueType.errorContext => throw UnsupportedError(
      'WASI component canonical adapter value $path uses error-context handles.',
    ),
  };
}

Object? _primitiveValueFromData(
  WasmComponentPrimitiveValueType primitive,
  String path,
  WasmComponentValueData value,
) {
  switch (primitive) {
    case WasmComponentPrimitiveValueType.boolean:
      if (value.kind == WasmComponentValueDataKind.boolean &&
          value.boolean != null) {
        return value.boolean;
      }
    case WasmComponentPrimitiveValueType.s8:
    case WasmComponentPrimitiveValueType.u8:
    case WasmComponentPrimitiveValueType.s16:
    case WasmComponentPrimitiveValueType.u16:
    case WasmComponentPrimitiveValueType.s32:
    case WasmComponentPrimitiveValueType.u32:
    case WasmComponentPrimitiveValueType.s64:
    case WasmComponentPrimitiveValueType.u64:
      if (value.kind == WasmComponentValueDataKind.integer &&
          (value.integer is int || value.integer is BigInt)) {
        return value.integer;
      }
    case WasmComponentPrimitiveValueType.f32:
    case WasmComponentPrimitiveValueType.f64:
      if (value.kind == WasmComponentValueDataKind.floatingPoint &&
          value.floatingPoint != null) {
        return value.floatingPoint;
      }
    case WasmComponentPrimitiveValueType.char:
    case WasmComponentPrimitiveValueType.string:
      if (value.kind == WasmComponentValueDataKind.string &&
          value.string != null) {
        return value.string;
      }
    case WasmComponentPrimitiveValueType.errorContext:
      break;
  }
  throw StateError(
    'WASI component canonical adapter value $path does not match ${primitive.name}.',
  );
}

int _expectFlatU32(String path, Object? value) {
  if (value is int) {
    return value.toUnsigned(32);
  }
  throw StateError(
    'WASI component canonical adapter value $path expected a core i32 value.',
  );
}

BigInt _expectFlatU64Bits(String path, Object? value) {
  if (value is int) {
    return BigInt.from(value) & _u64Mask;
  }
  if (value is BigInt) {
    return value & _u64Mask;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected a core i64 value.',
  );
}

Object _canonicalSignedI64(BigInt bits) {
  final signed = (bits & _i64SignBit) == BigInt.zero
      ? bits
      : bits - _u64Modulus;
  return _canonicalIntegerValue(signed);
}

Object _canonicalIntegerValue(BigInt value) {
  return value >= _minSafeInteger && value <= _maxSafeInteger
      ? value.toInt()
      : value;
}

Object _coreI64Value(Object value) {
  final bits = switch (value) {
    int() => BigInt.from(value) & _u64Mask,
    BigInt() => value & _u64Mask,
    _ => throw StateError('Expected a canonical 64-bit integer value.'),
  };
  return _canonicalSignedI64(bits);
}

Object? _coerceFlatValue(
  Object? value,
  WASIComponentCanonicalAdapterFlatType source,
  WASIComponentCanonicalAdapterFlatType target,
  String path,
) {
  if (source == target) {
    return value;
  }
  return switch ((source, target)) {
    (
      WASIComponentCanonicalAdapterFlatType.i32,
      WASIComponentCanonicalAdapterFlatType.f32,
    ) =>
      _f32FromBits(_expectFlatU32(path, value)),
    (
      WASIComponentCanonicalAdapterFlatType.f32,
      WASIComponentCanonicalAdapterFlatType.i32,
    ) =>
      _f32Bits(path, value),
    (
      WASIComponentCanonicalAdapterFlatType.i32,
      WASIComponentCanonicalAdapterFlatType.i64,
    ) =>
      _coreI64Value(_expectFlatU32(path, value)),
    (
      WASIComponentCanonicalAdapterFlatType.f32,
      WASIComponentCanonicalAdapterFlatType.i64,
    ) =>
      _coreI64Value(_f32Bits(path, value)),
    (
      WASIComponentCanonicalAdapterFlatType.f64,
      WASIComponentCanonicalAdapterFlatType.i64,
    ) =>
      _coreI64Value(_f64Bits(path, value)),
    (
      WASIComponentCanonicalAdapterFlatType.i64,
      WASIComponentCanonicalAdapterFlatType.i32,
    ) =>
      (_expectFlatU64Bits(path, value) & _u32BigIntMask).toInt(),
    (
      WASIComponentCanonicalAdapterFlatType.i64,
      WASIComponentCanonicalAdapterFlatType.f32,
    ) =>
      _f32FromBits((_expectFlatU64Bits(path, value) & _u32BigIntMask).toInt()),
    (
      WASIComponentCanonicalAdapterFlatType.i64,
      WASIComponentCanonicalAdapterFlatType.f64,
    ) =>
      _f64FromBits(_expectFlatU64Bits(path, value)),
    _ => throw StateError(
      'WASI component canonical adapter value $path cannot coerce '
      '${source.name} to ${target.name}.',
    ),
  };
}

Object _zeroFlatValue(WASIComponentCanonicalAdapterFlatType type) {
  return switch (type) {
    WASIComponentCanonicalAdapterFlatType.i32 ||
    WASIComponentCanonicalAdapterFlatType.i64 => 0,
    WASIComponentCanonicalAdapterFlatType.f32 ||
    WASIComponentCanonicalAdapterFlatType.f64 => 0.0,
  };
}

int _f32Bits(String path, Object? value) {
  if (value is! num) {
    throw StateError(
      'WASI component canonical adapter value $path expected a core f32 value.',
    );
  }
  final data = ByteData(4)..setFloat32(0, value.toDouble(), Endian.little);
  return data.getUint32(0, Endian.little);
}

double _f32FromBits(int bits) {
  final data = ByteData(4)..setUint32(0, bits, Endian.little);
  return data.getFloat32(0, Endian.little);
}

BigInt _f64Bits(String path, Object? value) {
  if (value is! num) {
    throw StateError(
      'WASI component canonical adapter value $path expected a core f64 value.',
    );
  }
  final data = ByteData(8)..setFloat64(0, value.toDouble(), Endian.little);
  return (BigInt.from(data.getUint32(4, Endian.little)) << 32) |
      BigInt.from(data.getUint32(0, Endian.little));
}

double _f64FromBits(BigInt bits) {
  final data = ByteData(8)
    ..setUint32(0, (bits & _u32BigIntMask).toInt(), Endian.little)
    ..setUint32(4, ((bits >> 32) & _u32BigIntMask).toInt(), Endian.little);
  return data.getFloat64(0, Endian.little);
}

final BigInt _u64Modulus = BigInt.one << 64;
final BigInt _u64Mask = _u64Modulus - BigInt.one;
final BigInt _u32BigIntMask = (BigInt.one << 32) - BigInt.one;
final BigInt _i64SignBit = BigInt.one << 63;
final BigInt _maxSafeInteger = BigInt.from(9007199254740991);
final BigInt _minSafeInteger = -_maxSafeInteger;

int _expectFlatResourceHandle(String path, Object? value) =>
    _expectFlatU32(path, value);

int _expectFlatErrorContextHandle(String path, Object? value) =>
    _expectFlatU32(path, value);

num _expectFlatNum(String path, Object? value) {
  if (value is num) {
    return value;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected num.',
  );
}

String _flatCharToString(String path, int value) {
  if (isWASIComponentUnicodeScalar(value)) {
    return String.fromCharCode(value);
  }
  throw StateError(
    'WASI component canonical adapter value $path expected a Unicode scalar.',
  );
}

int _stringToFlatChar(String path, Object? value) {
  final scalar = singleWASIComponentUnicodeScalar(value);
  if (scalar != null) {
    return scalar;
  }
  throw StateError(
    'WASI component canonical adapter value $path expected a Unicode scalar character.',
  );
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
  for (final param in plan.params) {
    _checkDirectValue(plan, param);
  }
  final result = plan.result;
  if (result != null) {
    _checkDirectValue(plan, result);
  }
}

bool _supportsDirectValuePlan(WASIComponentCanonicalAdapterPlan plan) {
  for (final param in plan.params) {
    if (!_supportsDirectValue(param)) {
      return false;
    }
  }
  final result = plan.result;
  return result == null || _supportsDirectValue(result);
}

bool _supportsDirectValue(WASIComponentCanonicalAdapterValuePlan value) {
  return (value.memoryCodec != null && value.resourceUses.isEmpty) ||
      value.flatLayout != null;
}

bool _supportsMemoryValuePlan(WASIComponentCanonicalAdapterPlan plan) {
  for (final param in plan.params) {
    if (!_supportsMemoryValue(param)) {
      return false;
    }
  }
  final result = plan.result;
  return result == null || _supportsMemoryValue(result);
}

bool _supportsMemoryValue(WASIComponentCanonicalAdapterValuePlan value) {
  return value.memoryCodec != null;
}

void _checkDirectValue(
  WASIComponentCanonicalAdapterPlan plan,
  WASIComponentCanonicalAdapterValuePlan value,
) {
  if (!_supportsDirectValue(value)) {
    throw UnsupportedError(
      'WASI component canonical adapter index ${plan.canonicalIndex} '
      'value ${value.path} does not have a supported direct value codec.',
    );
  }
}
