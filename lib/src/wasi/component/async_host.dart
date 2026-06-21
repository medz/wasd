import '../../wasm/backend/native/interpreter/component.dart';
import 'async_values.dart';

/// Binds decoded canonical stream/future definitions to executable primitives.
///
/// This is an internal host layer for Component Model async work. It does not
/// implement the full canonical ABI memory lowering/lifting path yet; it binds
/// validated `stream.*` and `future.*` definitions to typed Dart endpoint
/// primitives so later P3 host adapters can reuse one execution model.
final class WASIComponentAsyncHost {
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
    _expectDecodedAsyncType(
      component,
      componentTypeIndex,
      WasmComponentDefinedValueTypeKind.stream,
    );
    defineStreamType<T>(componentTypeIndex, name, onDrop: onDrop);
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
    _expectDecodedAsyncType(
      component,
      componentTypeIndex,
      WasmComponentDefinedValueTypeKind.future,
    );
    defineFutureType<T>(componentTypeIndex, name, onDrop: onDrop);
  }

  void _defineType<T extends Object>(
    int componentTypeIndex,
    String name, {
    required _WASIComponentAsyncValueKind kind,
    void Function()? onDrop,
  }) {
    if (_valueTypes.containsKey(componentTypeIndex)) {
      throw StateError(
        'WASI component async type index $componentTypeIndex is already bound.',
      );
    }
    _valueTypes[componentTypeIndex] = _RegisteredAsyncValueType<T>(
      name: name,
      kind: kind,
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

  /// Executes `stream.read`.
  List<Object> streamRead(Object? readable, int maxElements) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _valueType.streamRead(readable, maxElements);
  }

  /// Executes `stream.write`.
  int streamWrite(Object? writable, Object? values) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _valueType.streamWrite(writable, values);
  }

  /// Executes `stream.cancel-read`.
  void streamCancelRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelRead);
    _valueType.streamCancelRead(readable);
  }

  /// Executes `stream.cancel-write`.
  void streamCancelWrite(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    _valueType.streamCancelWrite(writable);
  }

  /// Executes `stream.drop-readable`.
  void streamDropReadable(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.streamDropReadable);
    _valueType.streamDropReadable(readable);
  }

  /// Executes `stream.drop-writable`.
  void streamDropWritable(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.streamDropWritable);
    _valueType.streamDropWritable(writable);
  }

  /// Executes `future.new`.
  Object futureNew() {
    _requireKind(WasmComponentCanonicalKind.futureNew);
    return _valueType.futureNew();
  }

  /// Executes `future.read`.
  Object futureRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _valueType.futureRead(readable);
  }

  /// Executes `future.write`.
  void futureWrite(Object? writable, Object? value) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    _valueType.futureWrite(writable, value);
  }

  /// Executes `future.cancel-read`.
  void futureCancelRead(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelRead);
    _valueType.futureCancelRead(readable);
  }

  /// Executes `future.cancel-write`.
  void futureCancelWrite(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    _valueType.futureCancelWrite(writable);
  }

  /// Executes `future.drop-readable`.
  void futureDropReadable(Object? readable) {
    _requireKind(WasmComponentCanonicalKind.futureDropReadable);
    _valueType.futureDropReadable(readable);
  }

  /// Executes `future.drop-writable`.
  void futureDropWritable(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.futureDropWritable);
    _valueType.futureDropWritable(writable);
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

final class _RegisteredAsyncValueType<T extends Object> {
  const _RegisteredAsyncValueType({
    required this.name,
    required this.kind,
    this.onDrop,
  });

  final String name;
  final _WASIComponentAsyncValueKind kind;
  final void Function()? onDrop;

  Object streamNew() {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    return WASIComponentStream<T>(name, onDrop: onDrop);
  }

  List<Object> streamRead(Object? readable, int maxElements) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectReadableStream(readable);
    return stream.read(maxElements);
  }

  int streamWrite(Object? writable, Object? values) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    final stream = _expectWritableStream(writable);
    final typedValues = _expectIterableValues(values);
    stream.writeAll(typedValues);
    return typedValues.length;
  }

  void streamCancelRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectReadableStream(readable).cancel();
  }

  void streamCancelWrite(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectWritableStream(writable).cancel();
  }

  void streamDropReadable(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectReadableStream(readable).drop();
  }

  void streamDropWritable(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectWritableStream(writable).drop();
  }

  Object futureNew() {
    _requireKind(_WASIComponentAsyncValueKind.future);
    return WASIComponentFuture<T>(name, onDrop: onDrop);
  }

  Object futureRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    return _expectReadableFuture(readable).read();
  }

  void futureWrite(Object? writable, Object? value) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    if (value is! T) {
      throw StateError('WASI component async type $name expected $T value.');
    }
    _expectWritableFuture(writable).complete(value);
  }

  void futureCancelRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectReadableFuture(readable).cancel();
  }

  void futureCancelWrite(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectWritableFuture(writable).cancel();
  }

  void futureDropReadable(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectReadableFuture(readable).drop();
  }

  void futureDropWritable(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectWritableFuture(writable).drop();
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

void _expectDecodedAsyncType(
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
