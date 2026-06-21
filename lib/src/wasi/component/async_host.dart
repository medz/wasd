import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'async_values.dart';
import 'backpressure.dart';
import 'resource_table.dart';

/// Binds decoded canonical stream/future definitions to executable primitives.
///
/// This is an internal host layer for Component Model async work. It binds
/// validated `stream.*` and `future.*` definitions to typed Dart endpoint
/// primitives, including fixed-width primitive stream memory copies, so later
/// P3 host adapters can reuse one execution model.
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

  final Map<int, _RegisteredAsyncValueType> _valueTypes =
      <int, _RegisteredAsyncValueType>{};

  /// Defines a component `stream<T>` type for [componentTypeIndex].
  void defineStreamType<T>(
    int componentTypeIndex,
    String name, {
    int? maxBufferedElements,
    void Function()? onDrop,
  }) {
    _defineType<T>(
      componentTypeIndex,
      name,
      kind: _WASIComponentAsyncValueKind.stream,
      valueValidator: _WASIComponentAsyncValueValidator.unconstrained,
      maxBufferedElements: maxBufferedElements,
      onDrop: onDrop,
    );
  }

  /// Defines a component `stream<T>` type from a decoded component type.
  void defineStreamTypeFromComponent<T>(
    WasmComponent component,
    int componentTypeIndex,
    String name, {
    int? maxBufferedElements,
    void Function()? onDrop,
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
    );
  }

  /// Defines a component `future<T>` type for [componentTypeIndex].
  void defineFutureType<T>(
    int componentTypeIndex,
    String name, {
    void Function()? onDrop,
  }) {
    _defineType<T>(
      componentTypeIndex,
      name,
      kind: _WASIComponentAsyncValueKind.future,
      valueValidator: _WASIComponentAsyncValueValidator.unconstrained,
      maxBufferedElements: null,
      onDrop: onDrop,
    );
  }

  /// Defines a component `future<T>` type from a decoded component type.
  void defineFutureTypeFromComponent<T>(
    WasmComponent component,
    int componentTypeIndex,
    String name, {
    void Function()? onDrop,
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
    );
  }

  void _defineType<T>(
    int componentTypeIndex,
    String name, {
    required _WASIComponentAsyncValueKind kind,
    required _WASIComponentAsyncValueValidator valueValidator,
    int? maxBufferedElements,
    void Function()? onDrop,
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
        operation.futureWrite(args[0], args[1]);
        return null;
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
      case WasmComponentCanonicalKind.backpressureSet:
        _expectArity(canonicalIndex, args, 1);
        return operation.backpressureSet(
          _expectBoolean(canonicalIndex, args.single, 'active'),
        );
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
  const WASIComponentAsyncEndpointHandles({
    required this.readable,
    required this.writable,
  });

  /// Readable endpoint handle.
  final int readable;

  /// Writable endpoint handle.
  final int writable;
}

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

  /// Copy status.
  final WASIComponentAsyncCopyStatus status;

  /// Number of elements copied before [status] was observed.
  final int copiedElements;

  /// Canonical packed result: status in low bits, element count above bit 4.
  int get packedResult => (copiedElements << 4) | status.code;
}

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
        return operation.streamNewHandles();
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
        operation.streamCancelReadHandle(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
        return null;
      case WasmComponentCanonicalKind.streamCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        operation.streamCancelWriteHandle(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
        return null;
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
        return operation.futureNewHandles();
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureReadHandle(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.futureWrite:
        _expectArity(canonicalIndex, args, 2);
        operation.futureWriteHandle(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          args[1],
        );
        return null;
      case WasmComponentCanonicalKind.futureCancelRead:
        _expectArity(canonicalIndex, args, 1);
        operation.futureCancelReadHandle(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
        return null;
      case WasmComponentCanonicalKind.futureCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        operation.futureCancelWriteHandle(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
        return null;
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
      case WasmComponentCanonicalKind.backpressureSet:
        _expectArity(canonicalIndex, args, 1);
        return operation.backpressureSet(
          _expectBoolean(canonicalIndex, args.single, 'active'),
        );
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
      default:
        return invoke(canonicalIndex, args);
    }
  }
}

/// Executable form of a canonical stream/future operation.
final class WASIComponentCanonicalAsyncOperation {
  const WASIComponentCanonicalAsyncOperation._({
    required this.kind,
    required this.componentTypeIndex,
    required _RegisteredAsyncValueType valueType,
  }) : _valueType = valueType,
       _backpressure = null;

  const WASIComponentCanonicalAsyncOperation._backpressure({
    required this.kind,
    required WASIComponentBackpressure backpressure,
  }) : componentTypeIndex = null,
       _valueType = null,
       _backpressure = backpressure;

  /// Canonical async operation kind.
  final WasmComponentCanonicalKind kind;

  /// Component type index the operation targets.
  final int? componentTypeIndex;

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

  /// Executes `stream.write` by reading fixed-width elements from [memory].
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

  /// Executes handle-backed `stream.write` from fixed-width memory elements.
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
    );
  }

  /// Executes `stream.read` and writes fixed-width elements to [memory].
  WASIComponentAsyncCopyResult streamReadToMemory(
    Object? readable,
    wasm.Memory memory,
    int pointer,
    int maxElements,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadToMemory(
      readable,
      memory,
      pointer,
      maxElements,
    );
  }

  /// Executes handle-backed `stream.read` into fixed-width memory elements.
  WASIComponentAsyncCopyResult streamReadHandleToMemory(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadHandleToMemory(
      readable,
      memory,
      pointer,
      maxElements,
    );
  }

  /// Executes `stream.cancel-read`.
  void streamCancelRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelRead);
    _requireValueType().streamCancelRead(readable);
  }

  /// Executes `stream.cancel-read` with a readable endpoint handle.
  void streamCancelReadHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelRead);
    _requireValueType().streamCancelReadHandle(readable);
  }

  /// Executes `stream.cancel-write`.
  void streamCancelWrite(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    _requireValueType().streamCancelWrite(writable);
  }

  /// Executes `stream.cancel-write` with a writable endpoint handle.
  void streamCancelWriteHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    _requireValueType().streamCancelWriteHandle(writable);
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

  /// Executes `future.read` and writes a fixed-width value to [memory].
  WASIComponentAsyncCopyResult futureReadToMemory(
    Object? readable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadToMemory(readable, memory, pointer);
  }

  /// Executes handle-backed `future.read` into fixed-width memory.
  WASIComponentAsyncCopyResult futureReadHandleToMemory(
    int readable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadHandleToMemory(
      readable,
      memory,
      pointer,
    );
  }

  /// Executes `future.write`.
  void futureWrite(Object? writable, Object? value) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    _requireValueType().futureWrite(writable, value);
  }

  /// Executes `future.write` by reading a fixed-width value from [memory].
  WASIComponentAsyncCopyResult futureWriteFromMemory(
    Object? writable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    return _requireValueType().futureWriteFromMemory(writable, memory, pointer);
  }

  /// Executes `future.write` with a writable endpoint handle.
  void futureWriteHandle(int writable, Object? value) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    _requireValueType().futureWriteHandle(writable, value);
  }

  /// Executes handle-backed `future.write` from fixed-width memory.
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
    );
  }

  /// Executes `future.cancel-read`.
  void futureCancelRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelRead);
    _requireValueType().futureCancelRead(readable);
  }

  /// Executes `future.cancel-read` with a readable endpoint handle.
  void futureCancelReadHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelRead);
    _requireValueType().futureCancelReadHandle(readable);
  }

  /// Executes `future.cancel-write`.
  void futureCancelWrite(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    _requireValueType().futureCancelWrite(writable);
  }

  /// Executes `future.cancel-write` with a writable endpoint handle.
  void futureCancelWriteHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    _requireValueType().futureCancelWriteHandle(writable);
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

  /// Executes `backpressure.set`.
  int backpressureSet(bool active) {
    _requireKind(WasmComponentCanonicalKind.backpressureSet);
    return _requireBackpressure().setActive(active);
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
  });

  static const unconstrained = _WASIComponentAsyncValueValidator._(
    kind: _WASIComponentAsyncValueShape.unconstrained,
  );

  static const unit = _WASIComponentAsyncValueValidator._(
    kind: _WASIComponentAsyncValueShape.unit,
  );

  final _WASIComponentAsyncValueShape kind;
  final WasmComponentPrimitiveValueType? primitive;

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
    }
  }
}

enum _WASIComponentAsyncValueShape { unconstrained, unit, primitive }

final class _RegisteredAsyncValueType<T> {
  _RegisteredAsyncValueType({
    required this.table,
    required this.name,
    required this.kind,
    required this.valueValidator,
    this.maxBufferedElements,
    this.onDrop,
  }) : readableStreamType = kind == _WASIComponentAsyncValueKind.stream
           ? table.defineType<WASIComponentReadableStream<T>>(
               '$name.readable',
               onDrop: (endpoint) {
                 endpoint.drop();
               },
             )
           : null,
       writableStreamType = kind == _WASIComponentAsyncValueKind.stream
           ? table.defineType<WASIComponentWritableStream<T>>(
               '$name.writable',
               onDrop: (endpoint) {
                 endpoint.drop();
               },
             )
           : null,
       readableFutureType = kind == _WASIComponentAsyncValueKind.future
           ? table.defineType<WASIComponentReadableFuture<T>>(
               '$name.readable',
               onDrop: (endpoint) {
                 endpoint.drop();
               },
             )
           : null,
       writableFutureType = kind == _WASIComponentAsyncValueKind.future
           ? table.defineType<WASIComponentWritableFuture<T>>(
               '$name.writable',
               onDrop: (endpoint) {
                 endpoint.drop();
               },
             )
           : null;

  final WASIComponentResourceTable table;
  final String name;
  final _WASIComponentAsyncValueKind kind;
  final _WASIComponentAsyncValueValidator valueValidator;
  final int? maxBufferedElements;
  final void Function()? onDrop;
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
    );
  }

  WASIComponentAsyncEndpointHandles streamNewHandles() {
    final stream = streamNew() as WASIComponentStream<T>;
    return WASIComponentAsyncEndpointHandles(
      readable: table.insert<WASIComponentReadableStream<T>>(
        readableStreamType!,
        stream.readable,
      ),
      writable: table.insert<WASIComponentWritableStream<T>>(
        writableStreamType!,
        stream.writable,
      ),
    );
  }

  List<Object?> streamRead(Object? readable, int maxElements) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectReadableStream(readable);
    return stream.read(maxElements);
  }

  Future<List<Object?>> streamReadWhenAvailable(
    Object? readable,
    int maxElements,
  ) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    return _expectReadableStream(
      readable,
    ).readWhenAvailable(maxElements).then<List<Object?>>((values) => values);
  }

  List<Object?> streamReadHandle(int readable, int maxElements) {
    return table.borrow<WASIComponentReadableStream<T>, List<Object?>>(
      readableStreamType!,
      readable,
      (stream) => stream.read(maxElements),
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
          .readWhenAvailable(maxElements)
          .then<List<Object?>>((values) => values),
    );
  }

  int streamWrite(Object? writable, Object? values) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectWritableStream(writable);
    final typedValues = _expectIterableValues(values);
    stream.writeAll(typedValues);
    return typedValues.length;
  }

  Future<int> streamWriteWhenAvailable(Object? writable, Object? values) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectWritableStream(writable);
    final typedValues = _expectIterableValues(values);
    return stream.writeWhenAvailable(typedValues);
  }

  WASIComponentAsyncCopyResult streamWriteFromMemory(
    Object? writable,
    wasm.Memory memory,
    int pointer,
    int elementCount,
  ) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectWritableStream(writable);
    final values = _readFixedWidthValuesFromMemory<T>(
      valueValidator,
      name,
      memory,
      pointer,
      elementCount,
    );
    stream.writeAll(values);
    return WASIComponentAsyncCopyResult.completed(values.length);
  }

  int streamWriteHandle(int writable, Object? values) {
    return table.borrow<WASIComponentWritableStream<T>, int>(
      writableStreamType!,
      writable,
      (stream) {
        final typedValues = _expectIterableValues(values);
        stream.writeAll(typedValues);
        return typedValues.length;
      },
    );
  }

  WASIComponentAsyncCopyResult streamWriteHandleFromMemory(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount,
  ) {
    return table
        .borrow<WASIComponentWritableStream<T>, WASIComponentAsyncCopyResult>(
          writableStreamType!,
          writable,
          (stream) {
            final values = _readFixedWidthValuesFromMemory<T>(
              valueValidator,
              name,
              memory,
              pointer,
              elementCount,
            );
            stream.writeAll(values);
            return WASIComponentAsyncCopyResult.completed(values.length);
          },
        );
  }

  Future<int> streamWriteHandleWhenAvailable(int writable, Object? values) {
    final typedValues = _expectIterableValues(values);
    return table.borrowAsync<WASIComponentWritableStream<T>, int>(
      writableStreamType!,
      writable,
      (stream) => stream.writeWhenAvailable(typedValues),
    );
  }

  WASIComponentAsyncCopyResult streamReadToMemory(
    Object? readable,
    wasm.Memory memory,
    int pointer,
    int maxElements,
  ) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final values = _expectReadableStream(readable).read(maxElements);
    _writeFixedWidthValuesToMemory(
      valueValidator,
      name,
      memory,
      pointer,
      values,
    );
    return WASIComponentAsyncCopyResult.completed(values.length);
  }

  WASIComponentAsyncCopyResult streamReadHandleToMemory(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements,
  ) {
    return table
        .borrow<WASIComponentReadableStream<T>, WASIComponentAsyncCopyResult>(
          readableStreamType!,
          readable,
          (stream) {
            final values = stream.read(maxElements);
            _writeFixedWidthValuesToMemory(
              valueValidator,
              name,
              memory,
              pointer,
              values,
            );
            return WASIComponentAsyncCopyResult.completed(values.length);
          },
        );
  }

  void streamCancelRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectReadableStream(readable).cancel();
  }

  void streamCancelReadHandle(int readable) {
    table.borrow<WASIComponentReadableStream<T>, void>(
      readableStreamType!,
      readable,
      (stream) {
        stream.cancel();
      },
    );
  }

  void streamCancelWrite(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectWritableStream(writable).cancel();
  }

  void streamCancelWriteHandle(int writable) {
    table.borrow<WASIComponentWritableStream<T>, void>(
      writableStreamType!,
      writable,
      (stream) {
        stream.cancel();
      },
    );
  }

  void streamDropReadable(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectReadableStream(readable).drop();
  }

  void streamDropReadableHandle(int readable) {
    table.drop<WASIComponentReadableStream<T>>(readableStreamType!, readable);
  }

  void streamDropWritable(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectWritableStream(writable).drop();
  }

  void streamDropWritableHandle(int writable) {
    table.drop<WASIComponentWritableStream<T>>(writableStreamType!, writable);
  }

  Object futureNew() {
    _requireKind(_WASIComponentAsyncValueKind.future);
    return WASIComponentFuture<T>(name, onDrop: onDrop);
  }

  WASIComponentAsyncEndpointHandles futureNewHandles() {
    final future = futureNew() as WASIComponentFuture<T>;
    return WASIComponentAsyncEndpointHandles(
      readable: table.insert<WASIComponentReadableFuture<T>>(
        readableFutureType!,
        future.readable,
      ),
      writable: table.insert<WASIComponentWritableFuture<T>>(
        writableFutureType!,
        future.writable,
      ),
    );
  }

  Object? futureRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    return _expectReadableFuture(readable).read();
  }

  Future<Object?> futureReadWhenReady(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    return _expectReadableFuture(readable).readWhenReady();
  }

  Object? futureReadHandle(int readable) {
    return table.borrow<WASIComponentReadableFuture<T>, Object?>(
      readableFutureType!,
      readable,
      (future) => future.read(),
    );
  }

  Future<Object?> futureReadHandleWhenReady(int readable) {
    return table.borrowAsync<WASIComponentReadableFuture<T>, Object?>(
      readableFutureType!,
      readable,
      (future) => future.readWhenReady(),
    );
  }

  WASIComponentAsyncCopyResult futureReadToMemory(
    Object? readable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    final value = _expectReadableFuture(readable).read();
    _writeFixedWidthValueToMemory(valueValidator, name, memory, pointer, value);
    return WASIComponentAsyncCopyResult.completed(0);
  }

  WASIComponentAsyncCopyResult futureReadHandleToMemory(
    int readable,
    wasm.Memory memory,
    int pointer,
  ) {
    return table
        .borrow<WASIComponentReadableFuture<T>, WASIComponentAsyncCopyResult>(
          readableFutureType!,
          readable,
          (future) {
            _writeFixedWidthValueToMemory(
              valueValidator,
              name,
              memory,
              pointer,
              future.read(),
            );
            return WASIComponentAsyncCopyResult.completed(0);
          },
        );
  }

  void futureWrite(Object? writable, Object? value) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    if (value is! T) {
      throw StateError('WASI component async type $name expected $T value.');
    }
    valueValidator.validate(name, value);
    _expectWritableFuture(writable).complete(value);
  }

  WASIComponentAsyncCopyResult futureWriteFromMemory(
    Object? writable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    final value = _readFixedWidthValueFromMemory<T>(
      valueValidator,
      name,
      memory,
      pointer,
    );
    _expectWritableFuture(writable).complete(value);
    return WASIComponentAsyncCopyResult.completed(0);
  }

  void futureWriteHandle(int writable, Object? value) {
    table.borrow<WASIComponentWritableFuture<T>, void>(
      writableFutureType!,
      writable,
      (future) {
        if (value is! T) {
          throw StateError(
            'WASI component async type $name expected $T value.',
          );
        }
        valueValidator.validate(name, value);
        future.complete(value);
      },
    );
  }

  WASIComponentAsyncCopyResult futureWriteHandleFromMemory(
    int writable,
    wasm.Memory memory,
    int pointer,
  ) {
    return table
        .borrow<WASIComponentWritableFuture<T>, WASIComponentAsyncCopyResult>(
          writableFutureType!,
          writable,
          (future) {
            final value = _readFixedWidthValueFromMemory<T>(
              valueValidator,
              name,
              memory,
              pointer,
            );
            future.complete(value);
            return WASIComponentAsyncCopyResult.completed(0);
          },
        );
  }

  void futureCancelRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectReadableFuture(readable).cancel();
  }

  void futureCancelReadHandle(int readable) {
    table.borrow<WASIComponentReadableFuture<T>, void>(
      readableFutureType!,
      readable,
      (future) {
        future.cancel();
      },
    );
  }

  void futureCancelWrite(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectWritableFuture(writable).cancel();
  }

  void futureCancelWriteHandle(int writable) {
    table.borrow<WASIComponentWritableFuture<T>, void>(
      writableFutureType!,
      writable,
      (future) {
        future.cancel();
      },
    );
  }

  void futureDropReadable(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectReadableFuture(readable).drop();
  }

  void futureDropReadableHandle(int readable) {
    table.drop<WASIComponentReadableFuture<T>>(readableFutureType!, readable);
  }

  void futureDropWritable(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectWritableFuture(writable).drop();
  }

  void futureDropWritableHandle(int writable) {
    table.drop<WASIComponentWritableFuture<T>>(writableFutureType!, writable);
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
  return kind == WasmComponentCanonicalKind.backpressureSet ||
      kind == WasmComponentCanonicalKind.backpressureInc ||
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
  if (primitive == null) {
    throw UnsupportedError(
      'WASI component async host currently supports only primitive stream/future element types.',
    );
  }
  if (primitive == WasmComponentPrimitiveValueType.errorContext) {
    throw UnsupportedError(
      'WASI component async host does not support error-context stream/future element values yet.',
    );
  }
  return _WASIComponentAsyncValueValidator._(
    kind: _WASIComponentAsyncValueShape.primitive,
    primitive: primitive,
  );
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
    WasmComponentPrimitiveValueType.s64 =>
      value is int &&
          value >= -0x8000000000000000 &&
          value <= 0x7fffffffffffffff,
    WasmComponentPrimitiveValueType.u64 =>
      value is int && value >= 0 && value <= 0xffffffffffffffff,
    WasmComponentPrimitiveValueType.f32 ||
    WasmComponentPrimitiveValueType.f64 => value is num,
    WasmComponentPrimitiveValueType.char =>
      value is String && value.runes.length == 1,
    WasmComponentPrimitiveValueType.string => value is String,
    WasmComponentPrimitiveValueType.errorContext => false,
  };
}

List<T> _readFixedWidthValuesFromMemory<T>(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  int elementCount,
) {
  _checkCopyElementCount(elementCount);
  if (validator.kind == _WASIComponentAsyncValueShape.unit) {
    if (null is! T) {
      throw StateError('WASI component async type $name expected $T value.');
    }
    return List<T>.filled(elementCount, null as T);
  }
  final primitive = validator.primitive;
  if (validator.kind != _WASIComponentAsyncValueShape.primitive ||
      primitive == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a fixed-width memory element type.',
    );
  }
  final layout = _fixedWidthLayout(name, primitive);
  final bytes = Uint8List.view(memory.buffer);
  _checkMemoryElementRange(bytes, pointer, elementCount, layout);
  final data = ByteData.view(memory.buffer);
  final values = <T>[];
  for (var i = 0; i < elementCount; i++) {
    final value = _readFixedWidthValue(
      data,
      pointer + i * layout.byteLength,
      primitive,
    );
    validator.validate(name, value);
    if (value is! T) {
      throw StateError('WASI component async type $name expected $T value.');
    }
    values.add(value as T);
  }
  return values;
}

T _readFixedWidthValueFromMemory<T>(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
) {
  if (validator.kind == _WASIComponentAsyncValueShape.unit) {
    if (null is! T) {
      throw StateError('WASI component async type $name expected $T value.');
    }
    return null as T;
  }
  final primitive = validator.primitive;
  if (validator.kind != _WASIComponentAsyncValueShape.primitive ||
      primitive == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a fixed-width memory element type.',
    );
  }
  final layout = _fixedWidthLayout(name, primitive);
  final bytes = Uint8List.view(memory.buffer);
  _checkMemoryElementRange(bytes, pointer, 1, layout);
  final value = _readFixedWidthValue(
    ByteData.view(memory.buffer),
    pointer,
    primitive,
  );
  validator.validate(name, value);
  if (value is! T) {
    throw StateError('WASI component async type $name expected $T value.');
  }
  return value as T;
}

void _writeFixedWidthValuesToMemory(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  List<Object?> values,
) {
  _checkCopyElementCount(values.length);
  validator.validateAll(name, values);
  if (validator.kind == _WASIComponentAsyncValueShape.unit) {
    return;
  }
  final primitive = validator.primitive;
  if (validator.kind != _WASIComponentAsyncValueShape.primitive ||
      primitive == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a fixed-width memory element type.',
    );
  }
  final layout = _fixedWidthLayout(name, primitive);
  final bytes = Uint8List.view(memory.buffer);
  _checkMemoryElementRange(bytes, pointer, values.length, layout);
  final data = ByteData.view(memory.buffer);
  for (var i = 0; i < values.length; i++) {
    _writeFixedWidthValue(
      data,
      pointer + i * layout.byteLength,
      primitive,
      values[i],
    );
  }
}

void _writeFixedWidthValueToMemory(
  _WASIComponentAsyncValueValidator validator,
  String name,
  wasm.Memory memory,
  int pointer,
  Object? value,
) {
  validator.validate(name, value);
  if (validator.kind == _WASIComponentAsyncValueShape.unit) {
    return;
  }
  final primitive = validator.primitive;
  if (validator.kind != _WASIComponentAsyncValueShape.primitive ||
      primitive == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a fixed-width memory element type.',
    );
  }
  final layout = _fixedWidthLayout(name, primitive);
  final bytes = Uint8List.view(memory.buffer);
  _checkMemoryElementRange(bytes, pointer, 1, layout);
  _writeFixedWidthValue(
    ByteData.view(memory.buffer),
    pointer,
    primitive,
    value,
  );
}

_FixedWidthLayout _fixedWidthLayout(
  String name,
  WasmComponentPrimitiveValueType primitive,
) {
  return switch (primitive) {
    WasmComponentPrimitiveValueType.boolean ||
    WasmComponentPrimitiveValueType.s8 ||
    WasmComponentPrimitiveValueType.u8 => const _FixedWidthLayout(
      byteLength: 1,
      alignment: 1,
    ),
    WasmComponentPrimitiveValueType.s16 ||
    WasmComponentPrimitiveValueType.u16 => const _FixedWidthLayout(
      byteLength: 2,
      alignment: 2,
    ),
    WasmComponentPrimitiveValueType.s32 ||
    WasmComponentPrimitiveValueType.u32 ||
    WasmComponentPrimitiveValueType.f32 ||
    WasmComponentPrimitiveValueType.char => const _FixedWidthLayout(
      byteLength: 4,
      alignment: 4,
    ),
    WasmComponentPrimitiveValueType.s64 ||
    WasmComponentPrimitiveValueType.u64 ||
    WasmComponentPrimitiveValueType.f64 => const _FixedWidthLayout(
      byteLength: 8,
      alignment: 8,
    ),
    WasmComponentPrimitiveValueType.string ||
    WasmComponentPrimitiveValueType.errorContext => throw UnsupportedError(
      'WASI component async type $name does not support fixed-width ${primitive.name} memory copies.',
    ),
  };
}

Object _readFixedWidthValue(
  ByteData data,
  int offset,
  WasmComponentPrimitiveValueType primitive,
) {
  return switch (primitive) {
    WasmComponentPrimitiveValueType.boolean => _readCanonicalBool(data, offset),
    WasmComponentPrimitiveValueType.s8 => data.getInt8(offset),
    WasmComponentPrimitiveValueType.u8 => data.getUint8(offset),
    WasmComponentPrimitiveValueType.s16 => data.getInt16(offset, Endian.little),
    WasmComponentPrimitiveValueType.u16 => data.getUint16(
      offset,
      Endian.little,
    ),
    WasmComponentPrimitiveValueType.s32 => data.getInt32(offset, Endian.little),
    WasmComponentPrimitiveValueType.u32 => data.getUint32(
      offset,
      Endian.little,
    ),
    WasmComponentPrimitiveValueType.s64 => data.getInt64(offset, Endian.little),
    WasmComponentPrimitiveValueType.u64 => data.getUint64(
      offset,
      Endian.little,
    ),
    WasmComponentPrimitiveValueType.f32 => data.getFloat32(
      offset,
      Endian.little,
    ),
    WasmComponentPrimitiveValueType.f64 => data.getFloat64(
      offset,
      Endian.little,
    ),
    WasmComponentPrimitiveValueType.char => _readCanonicalChar(data, offset),
    WasmComponentPrimitiveValueType.string ||
    WasmComponentPrimitiveValueType.errorContext => throw StateError(
      'Unsupported fixed-width primitive read: ${primitive.name}.',
    ),
  };
}

void _writeFixedWidthValue(
  ByteData data,
  int offset,
  WasmComponentPrimitiveValueType primitive,
  Object? value,
) {
  switch (primitive) {
    case WasmComponentPrimitiveValueType.boolean:
      data.setUint8(offset, (value as bool) ? 1 : 0);
    case WasmComponentPrimitiveValueType.s8:
      data.setInt8(offset, value as int);
    case WasmComponentPrimitiveValueType.u8:
      data.setUint8(offset, value as int);
    case WasmComponentPrimitiveValueType.s16:
      data.setInt16(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.u16:
      data.setUint16(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.s32:
      data.setInt32(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.u32:
      data.setUint32(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.s64:
      data.setInt64(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.u64:
      data.setUint64(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.f32:
      data.setFloat32(offset, (value as num).toDouble(), Endian.little);
    case WasmComponentPrimitiveValueType.f64:
      data.setFloat64(offset, (value as num).toDouble(), Endian.little);
    case WasmComponentPrimitiveValueType.char:
      data.setUint32(offset, (value as String).runes.single, Endian.little);
    case WasmComponentPrimitiveValueType.string:
    case WasmComponentPrimitiveValueType.errorContext:
      throw StateError(
        'Unsupported fixed-width primitive write: ${primitive.name}.',
      );
  }
}

bool _readCanonicalBool(ByteData data, int offset) {
  final value = data.getUint8(offset);
  if (value == 0) {
    return false;
  }
  if (value == 1) {
    return true;
  }
  throw StateError('Canonical bool memory value must be 0 or 1.');
}

String _readCanonicalChar(ByteData data, int offset) {
  final value = data.getUint32(offset, Endian.little);
  if (_isUnicodeScalar(value)) {
    return String.fromCharCode(value);
  }
  throw StateError('Canonical char memory value is not a Unicode scalar.');
}

bool _isUnicodeScalar(int value) {
  return value >= 0 && value <= 0x10ffff && (value < 0xd800 || value > 0xdfff);
}

void _checkMemoryElementRange(
  Uint8List bytes,
  int pointer,
  int elementCount,
  _FixedWidthLayout layout,
) {
  RangeError.checkNotNegative(pointer, 'pointer');
  _checkCopyElementCount(elementCount);
  if (layout.alignment > 1 && pointer % layout.alignment != 0) {
    throw StateError('pointer must be ${layout.alignment}-byte aligned.');
  }
  final byteLength = elementCount * layout.byteLength;
  if (pointer > bytes.length || byteLength > bytes.length - pointer) {
    throw RangeError.range(
      pointer + byteLength,
      0,
      bytes.length,
      'pointer + byteLength',
    );
  }
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

final class _FixedWidthLayout {
  const _FixedWidthLayout({required this.byteLength, required this.alignment});

  final int byteLength;
  final int alignment;
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

bool _expectBoolean(int canonicalIndex, Object? value, String name) {
  if (value is bool) {
    return value;
  }
  throw StateError(
    'WASI component canonical async index $canonicalIndex expected boolean $name.',
  );
}
