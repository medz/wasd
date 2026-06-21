import '../../wasm/backend/native/interpreter/component.dart';
import 'async_values.dart';
import 'resource_table.dart';

/// Binds decoded canonical stream/future definitions to executable primitives.
///
/// This is an internal host layer for Component Model async work. It does not
/// implement the full canonical ABI memory lowering/lifting path yet; it binds
/// validated `stream.*` and `future.*` definitions to typed Dart endpoint
/// primitives so later P3 host adapters can reuse one execution model.
final class WASIComponentAsyncHost {
  /// Creates an async host backed by [table] or a new resource table.
  WASIComponentAsyncHost({WASIComponentResourceTable? table})
    : table = table ?? WASIComponentResourceTable();

  /// Resource table used for handle-backed stream/future endpoints.
  final WASIComponentResourceTable table;

  final Map<int, _RegisteredAsyncValueType> _valueTypes =
      <int, _RegisteredAsyncValueType>{};

  /// Defines a component `stream<T>` type for [componentTypeIndex].
  void defineStreamType<T extends Object>(
    int componentTypeIndex,
    String name, {
    void Function()? onDrop,
  }) {
    _defineType<T>(
      componentTypeIndex,
      name,
      kind: _WASIComponentAsyncValueKind.stream,
      valueValidator: _WASIComponentAsyncValueValidator.unconstrained,
      onDrop: onDrop,
    );
  }

  /// Defines a component `stream<T>` type from a decoded component type.
  void defineStreamTypeFromComponent<T extends Object>(
    WasmComponent component,
    int componentTypeIndex,
    String name, {
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
      onDrop: onDrop,
    );
  }

  /// Defines a component `future<T>` type for [componentTypeIndex].
  void defineFutureType<T extends Object>(
    int componentTypeIndex,
    String name, {
    void Function()? onDrop,
  }) {
    _defineType<T>(
      componentTypeIndex,
      name,
      kind: _WASIComponentAsyncValueKind.future,
      valueValidator: _WASIComponentAsyncValueValidator.unconstrained,
      onDrop: onDrop,
    );
  }

  /// Defines a component `future<T>` type from a decoded component type.
  void defineFutureTypeFromComponent<T extends Object>(
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
      onDrop: onDrop,
    );
  }

  void _defineType<T extends Object>(
    int componentTypeIndex,
    String name, {
    required _WASIComponentAsyncValueKind kind,
    required _WASIComponentAsyncValueValidator valueValidator,
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
      onDrop: onDrop,
    );
  }

  /// Binds a decoded canonical stream/future definition.
  WASIComponentCanonicalAsyncOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    final expectedKind = _asyncValueKindForCanonicalKind(definition.kind);
    if (expectedKind == null) {
      throw UnsupportedError(
        'Wasm component canonical ${definition.kind.name} is not a stream or future operation.',
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
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the async program.',
        );
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
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the async handle program.',
        );
    }
  }
}

/// Executable form of a canonical stream/future operation.
final class WASIComponentCanonicalAsyncOperation {
  const WASIComponentCanonicalAsyncOperation._({
    required this.kind,
    required this.componentTypeIndex,
    required _RegisteredAsyncValueType valueType,
  }) : _valueType = valueType;

  /// Canonical stream/future operation kind.
  final WasmComponentCanonicalKind kind;

  /// Component type index the operation targets.
  final int componentTypeIndex;

  final _RegisteredAsyncValueType _valueType;

  /// Executes `stream.new`.
  Object streamNew() {
    _requireKind(WasmComponentCanonicalKind.streamNew);
    return _valueType.streamNew();
  }

  /// Executes `stream.new` and returns endpoint handles.
  WASIComponentAsyncEndpointHandles streamNewHandles() {
    _requireKind(WasmComponentCanonicalKind.streamNew);
    return _valueType.streamNewHandles();
  }

  /// Executes `stream.read`.
  List<Object> streamRead(Object? readable, int maxElements) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _valueType.streamRead(readable, maxElements);
  }

  /// Executes `stream.read` with a readable endpoint handle.
  List<Object> streamReadHandle(int readable, int maxElements) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _valueType.streamReadHandle(readable, maxElements);
  }

  /// Executes `stream.write`.
  int streamWrite(Object? writable, Object? values) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _valueType.streamWrite(writable, values);
  }

  /// Executes `stream.write` with a writable endpoint handle.
  int streamWriteHandle(int writable, Object? values) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _valueType.streamWriteHandle(writable, values);
  }

  /// Executes `stream.cancel-read`.
  void streamCancelRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelRead);
    _valueType.streamCancelRead(readable);
  }

  /// Executes `stream.cancel-read` with a readable endpoint handle.
  void streamCancelReadHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelRead);
    _valueType.streamCancelReadHandle(readable);
  }

  /// Executes `stream.cancel-write`.
  void streamCancelWrite(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    _valueType.streamCancelWrite(writable);
  }

  /// Executes `stream.cancel-write` with a writable endpoint handle.
  void streamCancelWriteHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    _valueType.streamCancelWriteHandle(writable);
  }

  /// Executes `stream.drop-readable`.
  void streamDropReadable(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.streamDropReadable);
    _valueType.streamDropReadable(readable);
  }

  /// Executes `stream.drop-readable` with a readable endpoint handle.
  void streamDropReadableHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.streamDropReadable);
    _valueType.streamDropReadableHandle(readable);
  }

  /// Executes `stream.drop-writable`.
  void streamDropWritable(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.streamDropWritable);
    _valueType.streamDropWritable(writable);
  }

  /// Executes `stream.drop-writable` with a writable endpoint handle.
  void streamDropWritableHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.streamDropWritable);
    _valueType.streamDropWritableHandle(writable);
  }

  /// Executes `future.new`.
  Object futureNew() {
    _requireKind(WasmComponentCanonicalKind.futureNew);
    return _valueType.futureNew();
  }

  /// Executes `future.new` and returns endpoint handles.
  WASIComponentAsyncEndpointHandles futureNewHandles() {
    _requireKind(WasmComponentCanonicalKind.futureNew);
    return _valueType.futureNewHandles();
  }

  /// Executes `future.read`.
  Object futureRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _valueType.futureRead(readable);
  }

  /// Executes `future.read` with a readable endpoint handle.
  Object futureReadHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _valueType.futureReadHandle(readable);
  }

  /// Executes `future.write`.
  void futureWrite(Object? writable, Object? value) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    _valueType.futureWrite(writable, value);
  }

  /// Executes `future.write` with a writable endpoint handle.
  void futureWriteHandle(int writable, Object? value) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    _valueType.futureWriteHandle(writable, value);
  }

  /// Executes `future.cancel-read`.
  void futureCancelRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelRead);
    _valueType.futureCancelRead(readable);
  }

  /// Executes `future.cancel-read` with a readable endpoint handle.
  void futureCancelReadHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelRead);
    _valueType.futureCancelReadHandle(readable);
  }

  /// Executes `future.cancel-write`.
  void futureCancelWrite(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    _valueType.futureCancelWrite(writable);
  }

  /// Executes `future.cancel-write` with a writable endpoint handle.
  void futureCancelWriteHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    _valueType.futureCancelWriteHandle(writable);
  }

  /// Executes `future.drop-readable`.
  void futureDropReadable(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureDropReadable);
    _valueType.futureDropReadable(readable);
  }

  /// Executes `future.drop-readable` with a readable endpoint handle.
  void futureDropReadableHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureDropReadable);
    _valueType.futureDropReadableHandle(readable);
  }

  /// Executes `future.drop-writable`.
  void futureDropWritable(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.futureDropWritable);
    _valueType.futureDropWritable(writable);
  }

  /// Executes `future.drop-writable` with a writable endpoint handle.
  void futureDropWritableHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.futureDropWritable);
    _valueType.futureDropWritableHandle(writable);
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
  const _WASIComponentAsyncValueValidator._(this.primitive);

  static const unconstrained = _WASIComponentAsyncValueValidator._(null);

  final WasmComponentPrimitiveValueType? primitive;

  bool get isConstrained => primitive != null;

  void validateAll(String name, Iterable<Object> values) {
    if (!isConstrained) {
      return;
    }
    for (final value in values) {
      validate(name, value);
    }
  }

  void validate(String name, Object value) {
    final expected = primitive;
    if (expected == null || _primitiveValueMatches(expected, value)) {
      return;
    }
    throw StateError(
      'WASI component async type $name expected ${expected.name} element value.',
    );
  }
}

final class _RegisteredAsyncValueType<T extends Object> {
  _RegisteredAsyncValueType({
    required this.table,
    required this.name,
    required this.kind,
    required this.valueValidator,
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
    return WASIComponentStream<T>(name, onDrop: onDrop);
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

  List<Object> streamRead(Object? readable, int maxElements) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectReadableStream(readable);
    return stream.read(maxElements);
  }

  List<Object> streamReadHandle(int readable, int maxElements) {
    return table.borrow<WASIComponentReadableStream<T>, List<Object>>(
      readableStreamType!,
      readable,
      (stream) => stream.read(maxElements),
    );
  }

  int streamWrite(Object? writable, Object? values) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectWritableStream(writable);
    final typedValues = _expectIterableValues(values);
    stream.writeAll(typedValues);
    return typedValues.length;
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

  Object futureRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    return _expectReadableFuture(readable).read();
  }

  Object futureReadHandle(int readable) {
    return table.borrow<WASIComponentReadableFuture<T>, Object>(
      readableFutureType!,
      readable,
      (future) => future.read(),
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
    return _WASIComponentAsyncValueValidator.unconstrained;
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
  return _WASIComponentAsyncValueValidator._(primitive);
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
