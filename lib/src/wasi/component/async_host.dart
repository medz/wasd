import 'dart:async';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'async_values.dart';
import 'backpressure.dart';
import 'resource_table.dart';
import 'value_memory.dart';
import 'waitable_set.dart';

/// Binds decoded canonical stream/future definitions to executable primitives.
///
/// This is an internal host layer for Component Model async work. It binds
/// validated `stream.*` and `future.*` definitions to typed Dart endpoint
/// primitives, including fixed-size stream/future memory copies, so later P3
/// host adapters can reuse one execution model.
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
  final Map<int, WASIComponentWaitable> _endpointWaitables =
      <int, WASIComponentWaitable>{};

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

  /// Resolves a handle-backed async endpoint to its waitable state.
  WASIComponentWaitable? waitableForHandle(int handle) {
    for (final valueType in _valueTypes.values) {
      final waitable = valueType.waitableForHandle(handle);
      if (waitable != null) {
        return waitable;
      }
    }
    return null;
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

  /// Returns supported component stream/future bindings in type-index order.
  List<WASIComponentAsyncValueBinding> componentAsyncValueBindings(
    WasmComponent component,
  ) {
    final bindings = <WASIComponentAsyncValueBinding>[];
    final definitions = component.componentTypeIndexDefinitions;
    for (
      var componentTypeIndex = 0;
      componentTypeIndex < definitions.length;
      componentTypeIndex++
    ) {
      final definition = definitions[componentTypeIndex];
      final definedValue = definition.definedValue;
      if (definition.kind != WasmComponentTypeKind.definedValue ||
          definedValue == null) {
        continue;
      }
      final kind = switch (definedValue.kind) {
        WasmComponentDefinedValueTypeKind.stream =>
          WASIComponentAsyncValueBindingKind.stream,
        WasmComponentDefinedValueTypeKind.future =>
          WASIComponentAsyncValueBindingKind.future,
        _ => null,
      };
      if (kind == null) {
        continue;
      }
      final validator = _supportedAsyncValueValidatorForElementType(
        definedValue.elementType,
        definitions,
      );
      if (validator == null) {
        continue;
      }
      bindings.add(
        WASIComponentAsyncValueBinding._(
          componentTypeIndex: componentTypeIndex,
          name: '${kind.name}[$componentTypeIndex]',
          kind: kind,
          valueValidator: validator,
        ),
      );
    }
    return List<WASIComponentAsyncValueBinding>.unmodifiable(bindings);
  }

  /// Defines async value types from a prepared component async binding list.
  void defineAsyncValueBindings<T>(
    Iterable<WASIComponentAsyncValueBinding> bindings, {
    String Function(WASIComponentAsyncValueBinding binding)? nameForBinding,
    int? Function(WASIComponentAsyncValueBinding binding)?
    maxBufferedElementsForStream,
    void Function(WASIComponentAsyncValueBinding binding)? onDrop,
  }) {
    final bindingList = bindings is List<WASIComponentAsyncValueBinding>
        ? bindings
        : bindings.toList(growable: false);
    checkAsyncValueBindingsAvailable(bindingList);
    for (final binding in bindingList) {
      _defineType<T>(
        binding.componentTypeIndex,
        nameForBinding?.call(binding) ?? binding.name,
        kind: switch (binding.kind) {
          WASIComponentAsyncValueBindingKind.stream =>
            _WASIComponentAsyncValueKind.stream,
          WASIComponentAsyncValueBindingKind.future =>
            _WASIComponentAsyncValueKind.future,
        },
        valueValidator: binding._valueValidator,
        maxBufferedElements:
            binding.kind == WASIComponentAsyncValueBindingKind.stream
            ? maxBufferedElementsForStream?.call(binding)
            : null,
        onDrop: onDrop == null ? null : () => onDrop(binding),
      );
    }
  }

  /// Throws if [bindings] cannot be defined without mutating this host.
  void checkAsyncValueBindingsAvailable(
    Iterable<WASIComponentAsyncValueBinding> bindings,
  ) {
    final seen = <int>{};
    for (final binding in bindings) {
      final componentTypeIndex = binding.componentTypeIndex;
      if (componentTypeIndex < 0) {
        throw StateError(
          'WASI component async type index $componentTypeIndex is invalid.',
        );
      }
      if (!seen.add(componentTypeIndex)) {
        throw StateError(
          'WASI component async type index $componentTypeIndex is bound more than once.',
        );
      }
      if (_valueTypes.containsKey(componentTypeIndex)) {
        throw StateError(
          'WASI component async type index $componentTypeIndex is already bound.',
        );
      }
    }
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
      endpointWaitables: _endpointWaitables,
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
      isAsync: definition.isAsync,
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

/// Supported async value binding kind.
enum WASIComponentAsyncValueBindingKind {
  /// Component `stream<T>`.
  stream,

  /// Component `future<T>`.
  future,
}

/// A decoded component stream/future type that can be bound to the async host.
final class WASIComponentAsyncValueBinding {
  WASIComponentAsyncValueBinding._({
    required this.componentTypeIndex,
    required this.name,
    required this.kind,
    required _WASIComponentAsyncValueValidator valueValidator,
  }) : _valueValidator = valueValidator,
       fixedWidthMemoryLayout = _fixedWidthMemoryLayoutFor(valueValidator);

  final _WASIComponentAsyncValueValidator _valueValidator;

  /// Component type index of the stream/future value.
  final int componentTypeIndex;

  /// Stable debug name for this async value type.
  final String name;

  /// Stream/future binding kind.
  final WASIComponentAsyncValueBindingKind kind;

  /// Whether this stream/future carries unit values.
  bool get isUnit => _valueValidator.kind == _WASIComponentAsyncValueShape.unit;

  /// Primitive element type when this binding carries primitive values.
  WasmComponentPrimitiveValueType? get primitive =>
      _valueValidator.primitive ?? _valueValidator.memoryCodec?.primitive;

  /// Fixed-size Canonical ABI memory-copy layout for this payload.
  ///
  /// Returns `null` for unit payloads and values such as `string` that need
  /// realloc-backed stream/future memory representation.
  final WASIComponentAsyncValueMemoryLayout? fixedWidthMemoryLayout;
}

/// Canonical ABI fixed-size memory-copy layout for an async value payload.
final class WASIComponentAsyncValueMemoryLayout {
  const WASIComponentAsyncValueMemoryLayout._({
    required this.byteLength,
    required this.alignment,
  });

  /// Number of guest-memory bytes per stream/future element.
  final int byteLength;

  /// Required guest-memory alignment for the element pointer.
  final int alignment;
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
  WASIComponentAsyncEndpointHandles({
    required this.readable,
    required this.writable,
  }) {
    _checkU32Handle(readable, 'readable');
    _checkU32Handle(writable, 'writable');
  }

  /// Unpacks the canonical `i64` handle pair used by stream/future.new.
  factory WASIComponentAsyncEndpointHandles.unpack(int packed) {
    final bits = _normalizeI64Bits(packed, 'packed');
    return WASIComponentAsyncEndpointHandles(
      readable: bits & _u32Mask,
      writable: (bits >> 32) & _u32Mask,
    );
  }

  /// Readable endpoint handle.
  final int readable;

  /// Writable endpoint handle.
  final int writable;

  /// Canonical signed `i64` with readable in low bits and writable in high bits.
  int get packed => (readable | (writable << 32)).toSigned(64);
}

const int _u32Mask = 0xffffffff;
const int _i64Min = -0x8000000000000000;

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

/// Canonical return value used when an async copy has not produced an event yet.
const int wasiComponentAsyncBlocked = 0xffffffff;

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

  /// Dropped copy result for [copiedElements].
  factory WASIComponentAsyncCopyResult.dropped([int copiedElements = 0]) {
    _checkCopyElementCount(copiedElements);
    return WASIComponentAsyncCopyResult._(
      status: WASIComponentAsyncCopyStatus.dropped,
      copiedElements: copiedElements,
    );
  }

  /// Cancelled copy result for [copiedElements].
  factory WASIComponentAsyncCopyResult.cancelled([int copiedElements = 0]) {
    _checkCopyElementCount(copiedElements);
    return WASIComponentAsyncCopyResult._(
      status: WASIComponentAsyncCopyStatus.cancelled,
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
        return operation.streamNewPackedHandles();
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
        return operation.streamCancelReadHandle(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.streamCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        return operation.streamCancelWriteHandle(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
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
        return operation.futureNewPackedHandles();
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
        return operation.futureCancelReadHandle(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.futureCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureCancelWriteHandle(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
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
      case WasmComponentCanonicalKind.streamCancelRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.streamCancelReadHandleWhenReady(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.streamCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        return operation.streamCancelWriteHandleWhenReady(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
      case WasmComponentCanonicalKind.futureCancelRead:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureCancelReadHandleWhenReady(
          _expectHandle(canonicalIndex, args.single, 'readable'),
        );
      case WasmComponentCanonicalKind.futureCancelWrite:
        _expectArity(canonicalIndex, args, 1);
        return operation.futureCancelWriteHandleWhenReady(
          _expectHandle(canonicalIndex, args.single, 'writable'),
        );
      default:
        return invoke(canonicalIndex, args);
    }
  }

  /// Invokes a handle-backed canonical async memory-copy operation.
  ///
  /// This uses the core Canonical ABI argument shape for fixed-size
  /// stream/future copies: `stream.{read,write}` receive `(handle, ptr, n)`,
  /// and `future.{read,write}` receive `(handle, ptr)`. Completed copy results
  /// are returned in their canonical packed integer representation.
  Object? invokeWithMemory(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args,
  ) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 3);
        return operation
            .streamReadHandleToMemory(
              _expectHandle(canonicalIndex, args[0], 'readable'),
              memory,
              _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
              _expectNonNegativeInt(canonicalIndex, args[2], 'maxElements'),
            )
            .packedResult;
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 3);
        return operation
            .streamWriteHandleFromMemory(
              _expectHandle(canonicalIndex, args[0], 'writable'),
              memory,
              _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
              _expectNonNegativeInt(canonicalIndex, args[2], 'elementCount'),
            )
            .packedResult;
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 2);
        return operation
            .futureReadHandleToMemory(
              _expectHandle(canonicalIndex, args[0], 'readable'),
              memory,
              _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
            )
            .packedResult;
      case WasmComponentCanonicalKind.futureWrite:
        _expectArity(canonicalIndex, args, 2);
        return operation
            .futureWriteHandleFromMemory(
              _expectHandle(canonicalIndex, args[0], 'writable'),
              memory,
              _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
            )
            .packedResult;
      default:
        return invoke(canonicalIndex, args);
    }
  }

  /// Starts a handle-backed canonical async memory-copy operation.
  ///
  /// When the copy can complete immediately, the canonical packed copy payload
  /// is returned. When it must wait for stream/future progress, this returns
  /// [wasiComponentAsyncBlocked] and later publishes a waitable event on the
  /// endpoint handle.
  Object? invokeWithMemoryEvent(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args,
  ) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 3);
        return operation.streamReadHandleToMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
          _expectNonNegativeInt(canonicalIndex, args[2], 'maxElements'),
        );
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 3);
        return operation.streamWriteHandleFromMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
          _expectNonNegativeInt(canonicalIndex, args[2], 'elementCount'),
        );
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 2);
        return operation.futureReadHandleToMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
        );
      case WasmComponentCanonicalKind.futureWrite:
        _expectArity(canonicalIndex, args, 2);
        return operation.futureWriteHandleFromMemoryEvent(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
        );
      default:
        return invoke(canonicalIndex, args);
    }
  }

  /// Invokes a handle-backed canonical async memory-copy operation and waits
  /// when the endpoint cannot complete immediately.
  Future<Object?> invokeWithMemoryAsync(
    int canonicalIndex,
    wasm.Memory memory,
    List<Object?> args,
  ) async {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical async index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.streamRead:
        _expectArity(canonicalIndex, args, 3);
        final result = await operation.streamReadHandleToMemoryWhenAvailable(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
          _expectNonNegativeInt(canonicalIndex, args[2], 'maxElements'),
        );
        return result.packedResult;
      case WasmComponentCanonicalKind.streamWrite:
        _expectArity(canonicalIndex, args, 3);
        final result = await operation.streamWriteHandleFromMemoryWhenAvailable(
          _expectHandle(canonicalIndex, args[0], 'writable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
          _expectNonNegativeInt(canonicalIndex, args[2], 'elementCount'),
        );
        return result.packedResult;
      case WasmComponentCanonicalKind.futureRead:
        _expectArity(canonicalIndex, args, 2);
        final result = await operation.futureReadHandleToMemoryWhenReady(
          _expectHandle(canonicalIndex, args[0], 'readable'),
          memory,
          _expectNonNegativeInt(canonicalIndex, args[1], 'pointer'),
        );
        return result.packedResult;
      default:
        return invokeWithMemory(canonicalIndex, memory, args);
    }
  }
}

/// Executable form of a canonical stream/future operation.
final class WASIComponentCanonicalAsyncOperation {
  const WASIComponentCanonicalAsyncOperation._({
    required this.kind,
    required this.componentTypeIndex,
    required this.isAsync,
    required _RegisteredAsyncValueType valueType,
  }) : _valueType = valueType,
       _backpressure = null;

  const WASIComponentCanonicalAsyncOperation._backpressure({
    required this.kind,
    required WASIComponentBackpressure backpressure,
  }) : componentTypeIndex = null,
       isAsync = false,
       _valueType = null,
       _backpressure = backpressure;

  /// Canonical async operation kind.
  final WasmComponentCanonicalKind kind;

  /// Component type index the operation targets.
  final int? componentTypeIndex;

  /// Whether this canonical operation was decoded with the async flag.
  final bool isAsync;

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

  /// Executes `stream.new` and returns the canonical packed handle pair.
  int streamNewPackedHandles() {
    return streamNewHandles().packed;
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

  /// Executes `stream.write` by reading fixed-size elements from [memory].
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

  /// Executes handle-backed `stream.write` from fixed-size memory elements.
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

  /// Executes handle-backed `stream.write` from memory when capacity exists.
  Future<WASIComponentAsyncCopyResult> streamWriteHandleFromMemoryWhenAvailable(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteHandleFromMemoryWhenAvailable(
      writable,
      memory,
      pointer,
      elementCount,
    );
  }

  /// Starts handle-backed `stream.write` from memory and publishes an event.
  int streamWriteHandleFromMemoryEvent(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamWrite);
    return _requireValueType().streamWriteHandleFromMemoryEvent(
      writable,
      memory,
      pointer,
      elementCount,
    );
  }

  /// Executes `stream.read` and writes fixed-size elements to [memory].
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

  /// Executes handle-backed `stream.read` into fixed-size memory elements.
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

  /// Executes handle-backed `stream.read` into memory when values exist.
  Future<WASIComponentAsyncCopyResult> streamReadHandleToMemoryWhenAvailable(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadHandleToMemoryWhenAvailable(
      readable,
      memory,
      pointer,
      maxElements,
    );
  }

  /// Starts handle-backed `stream.read` into memory and publishes an event.
  int streamReadHandleToMemoryEvent(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements,
  ) {
    _requireKind(WasmComponentCanonicalKind.streamRead);
    return _requireValueType().streamReadHandleToMemoryEvent(
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
  int streamCancelReadHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelRead);
    return _requireValueType().streamCancelReadHandle(
      readable,
      isAsync: isAsync,
    );
  }

  /// Executes `stream.cancel-read` with a readable endpoint handle, waiting
  /// for the copy event when the canonical operation is synchronous.
  Future<int> streamCancelReadHandleWhenReady(int readable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelRead);
    return _requireValueType().streamCancelReadHandleWhenReady(
      readable,
      isAsync: isAsync,
    );
  }

  /// Executes `stream.cancel-write`.
  void streamCancelWrite(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    _requireValueType().streamCancelWrite(writable);
  }

  /// Executes `stream.cancel-write` with a writable endpoint handle.
  int streamCancelWriteHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    return _requireValueType().streamCancelWriteHandle(
      writable,
      isAsync: isAsync,
    );
  }

  /// Executes `stream.cancel-write` with a writable endpoint handle, waiting
  /// for the copy event when the canonical operation is synchronous.
  Future<int> streamCancelWriteHandleWhenReady(int writable) {
    _requireKind(WasmComponentCanonicalKind.streamCancelWrite);
    return _requireValueType().streamCancelWriteHandleWhenReady(
      writable,
      isAsync: isAsync,
    );
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

  /// Executes `future.new` and returns the canonical packed handle pair.
  int futureNewPackedHandles() {
    return futureNewHandles().packed;
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

  /// Executes `future.read` and writes a fixed-size value to [memory].
  WASIComponentAsyncCopyResult futureReadToMemory(
    Object? readable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadToMemory(readable, memory, pointer);
  }

  /// Executes handle-backed `future.read` into fixed-size memory.
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

  /// Executes handle-backed `future.read` into memory when ready.
  Future<WASIComponentAsyncCopyResult> futureReadHandleToMemoryWhenReady(
    int readable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadHandleToMemoryWhenReady(
      readable,
      memory,
      pointer,
    );
  }

  /// Starts handle-backed `future.read` into memory and publishes an event.
  int futureReadHandleToMemoryEvent(
    int readable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureRead);
    return _requireValueType().futureReadHandleToMemoryEvent(
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

  /// Executes `future.write` by reading a fixed-size value from [memory].
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

  /// Executes handle-backed `future.write` from fixed-size memory.
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

  /// Starts handle-backed `future.write` from memory and publishes an event.
  int futureWriteHandleFromMemoryEvent(
    int writable,
    wasm.Memory memory,
    int pointer,
  ) {
    _requireKind(WasmComponentCanonicalKind.futureWrite);
    return _requireValueType().futureWriteHandleFromMemoryEvent(
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
  int futureCancelReadHandle(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelRead);
    return _requireValueType().futureCancelReadHandle(
      readable,
      isAsync: isAsync,
    );
  }

  /// Executes `future.cancel-read` with a readable endpoint handle, waiting
  /// for the copy event when the canonical operation is synchronous.
  Future<int> futureCancelReadHandleWhenReady(int readable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelRead);
    return _requireValueType().futureCancelReadHandleWhenReady(
      readable,
      isAsync: isAsync,
    );
  }

  /// Executes `future.cancel-write`.
  void futureCancelWrite(Object? writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    _requireValueType().futureCancelWrite(writable);
  }

  /// Executes `future.cancel-write` with a writable endpoint handle.
  int futureCancelWriteHandle(int writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    return _requireValueType().futureCancelWriteHandle(
      writable,
      isAsync: isAsync,
    );
  }

  /// Executes `future.cancel-write` with a writable endpoint handle, waiting
  /// for the copy event when the canonical operation is synchronous.
  Future<int> futureCancelWriteHandleWhenReady(int writable) {
    _requireKind(WasmComponentCanonicalKind.futureCancelWrite);
    return _requireValueType().futureCancelWriteHandleWhenReady(
      writable,
      isAsync: isAsync,
    );
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
    this.memoryCodec,
  });

  static const unconstrained = _WASIComponentAsyncValueValidator._(
    kind: _WASIComponentAsyncValueShape.unconstrained,
  );

  static const unit = _WASIComponentAsyncValueValidator._(
    kind: _WASIComponentAsyncValueShape.unit,
  );

  final _WASIComponentAsyncValueShape kind;
  final WasmComponentPrimitiveValueType? primitive;
  final WASIComponentCanonicalValueMemoryCodec? memoryCodec;

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
      case _WASIComponentAsyncValueShape.canonicalValue:
        final codec = memoryCodec;
        if (codec != null) {
          codec.validate(name, value);
          return;
        }
        throw StateError(
          'WASI component async type $name does not have a canonical value codec.',
        );
    }
  }
}

enum _WASIComponentAsyncValueShape {
  unconstrained,
  unit,
  primitive,
  canonicalValue,
}

final class _RegisteredAsyncValueType<T> {
  _RegisteredAsyncValueType({
    required this.table,
    required this.name,
    required this.kind,
    required this.valueValidator,
    required this.endpointWaitables,
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
  final Map<int, WASIComponentWaitable> endpointWaitables;
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
    final readable = table.insert<WASIComponentReadableStream<T>>(
      readableStreamType!,
      stream.readable,
    );
    final writable = table.insert<WASIComponentWritableStream<T>>(
      writableStreamType!,
      stream.writable,
    );
    return WASIComponentAsyncEndpointHandles(
      readable: readable,
      writable: writable,
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

  Future<WASIComponentAsyncCopyResult> streamWriteHandleFromMemoryWhenAvailable(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount,
  ) {
    return table.borrowAsync<
      WASIComponentWritableStream<T>,
      WASIComponentAsyncCopyResult
    >(writableStreamType!, writable, (stream) {
      final values = _readFixedWidthValuesFromMemory<T>(
        valueValidator,
        name,
        memory,
        pointer,
        elementCount,
      );
      return stream
          .writeWhenAvailable(values)
          .then<WASIComponentAsyncCopyResult>(
            WASIComponentAsyncCopyResult.completed,
          );
    });
  }

  int streamWriteHandleFromMemoryEvent(
    int writable,
    wasm.Memory memory,
    int pointer,
    int elementCount,
  ) {
    final waitable = _existingEndpointWaitable(writable);
    return table.borrow<WASIComponentWritableStream<T>, int>(
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
        if (stream.canWriteImmediately(values.length)) {
          stream.writeAll(values);
          return WASIComponentAsyncCopyResult.completed(
            values.length,
          ).packedResult;
        }

        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentWritableStream<T>,
              WASIComponentAsyncCopyResult
            >(writableStreamType!, writable, (stream) {
              return stream
                  .writeWhenAvailable(values)
                  .then<WASIComponentAsyncCopyResult>(
                    WASIComponentAsyncCopyResult.completed,
                  );
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.streamWrite,
          writable,
          pending,
        );
        return wasiComponentAsyncBlocked;
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

  Future<WASIComponentAsyncCopyResult> streamReadHandleToMemoryWhenAvailable(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements,
  ) {
    return table.borrowAsync<
      WASIComponentReadableStream<T>,
      WASIComponentAsyncCopyResult
    >(readableStreamType!, readable, (stream) {
      return stream
          .readWhenAvailable(maxElements)
          .then<WASIComponentAsyncCopyResult>((values) {
            _writeFixedWidthValuesToMemory(
              valueValidator,
              name,
              memory,
              pointer,
              values,
            );
            return WASIComponentAsyncCopyResult.completed(values.length);
          });
    });
  }

  int streamReadHandleToMemoryEvent(
    int readable,
    wasm.Memory memory,
    int pointer,
    int maxElements,
  ) {
    final waitable = _existingEndpointWaitable(readable);
    return table.borrow<WASIComponentReadableStream<T>, int>(
      readableStreamType!,
      readable,
      (stream) {
        if (maxElements == 0 || stream.hasQueuedValues) {
          final values = stream.read(maxElements);
          _writeFixedWidthValuesToMemory(
            valueValidator,
            name,
            memory,
            pointer,
            values,
          );
          return WASIComponentAsyncCopyResult.completed(
            values.length,
          ).packedResult;
        }

        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentReadableStream<T>,
              WASIComponentAsyncCopyResult
            >(readableStreamType!, readable, (stream) {
              return stream
                  .readWhenAvailable(maxElements)
                  .then<WASIComponentAsyncCopyResult>((values) {
                    _writeFixedWidthValuesToMemory(
                      valueValidator,
                      name,
                      memory,
                      pointer,
                      values,
                    );
                    return WASIComponentAsyncCopyResult.completed(
                      values.length,
                    );
                  });
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.streamRead,
          readable,
          pending,
        );
        return wasiComponentAsyncBlocked;
      },
    );
  }

  void streamCancelRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectReadableStream(readable).cancel();
  }

  int streamCancelReadHandle(int readable, {required bool isAsync}) {
    return _cancelCopy(
      handle: readable,
      eventCode: WASIComponentWaitableEventCode.streamRead,
      isAsync: isAsync,
      cancel: () {
        table.borrow<WASIComponentReadableStream<T>, void>(
          readableStreamType!,
          readable,
          (stream) {
            stream.cancel();
          },
        );
      },
    );
  }

  Future<int> streamCancelReadHandleWhenReady(
    int readable, {
    required bool isAsync,
  }) {
    return _cancelCopyWhenReady(
      handle: readable,
      eventCode: WASIComponentWaitableEventCode.streamRead,
      isAsync: isAsync,
      cancel: () {
        table.borrow<WASIComponentReadableStream<T>, void>(
          readableStreamType!,
          readable,
          (stream) {
            stream.cancel();
          },
        );
      },
    );
  }

  void streamCancelWrite(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectWritableStream(writable).cancel();
  }

  int streamCancelWriteHandle(int writable, {required bool isAsync}) {
    return _cancelCopy(
      handle: writable,
      eventCode: WASIComponentWaitableEventCode.streamWrite,
      isAsync: isAsync,
      cancel: () {
        table.borrow<WASIComponentWritableStream<T>, void>(
          writableStreamType!,
          writable,
          (stream) {
            stream.cancel();
          },
        );
      },
    );
  }

  Future<int> streamCancelWriteHandleWhenReady(
    int writable, {
    required bool isAsync,
  }) {
    return _cancelCopyWhenReady(
      handle: writable,
      eventCode: WASIComponentWaitableEventCode.streamWrite,
      isAsync: isAsync,
      cancel: () {
        table.borrow<WASIComponentWritableStream<T>, void>(
          writableStreamType!,
          writable,
          (stream) {
            stream.cancel();
          },
        );
      },
    );
  }

  void streamDropReadable(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectReadableStream(readable).drop();
  }

  void streamDropReadableHandle(int readable) {
    _requireEndpointWaitableDroppable(readable);
    table.drop<WASIComponentReadableStream<T>>(readableStreamType!, readable);
    endpointWaitables.remove(readable)?.drop();
  }

  void streamDropWritable(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.stream);
    _expectWritableStream(writable).drop();
  }

  void streamDropWritableHandle(int writable) {
    _requireEndpointWaitableDroppable(writable);
    table.drop<WASIComponentWritableStream<T>>(writableStreamType!, writable);
    endpointWaitables.remove(writable)?.drop();
  }

  Object futureNew() {
    _requireKind(_WASIComponentAsyncValueKind.future);
    return WASIComponentFuture<T>(name, onDrop: onDrop);
  }

  WASIComponentAsyncEndpointHandles futureNewHandles() {
    final future = futureNew() as WASIComponentFuture<T>;
    final readable = table.insert<WASIComponentReadableFuture<T>>(
      readableFutureType!,
      future.readable,
    );
    final writable = table.insert<WASIComponentWritableFuture<T>>(
      writableFutureType!,
      future.writable,
    );
    return WASIComponentAsyncEndpointHandles(
      readable: readable,
      writable: writable,
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
    final value = _expectReadableFuture(readable).readForCopy();
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
              future.readForCopy(),
            );
            return WASIComponentAsyncCopyResult.completed(0);
          },
        );
  }

  Future<WASIComponentAsyncCopyResult> futureReadHandleToMemoryWhenReady(
    int readable,
    wasm.Memory memory,
    int pointer,
  ) {
    return table.borrowAsync<
      WASIComponentReadableFuture<T>,
      WASIComponentAsyncCopyResult
    >(readableFutureType!, readable, (future) {
      return future.readWhenReadyForCopy().then<WASIComponentAsyncCopyResult>((
        value,
      ) {
        _writeFixedWidthValueToMemory(
          valueValidator,
          name,
          memory,
          pointer,
          value,
        );
        return WASIComponentAsyncCopyResult.completed(0);
      });
    });
  }

  int futureReadHandleToMemoryEvent(
    int readable,
    wasm.Memory memory,
    int pointer,
  ) {
    final waitable = _existingEndpointWaitable(readable);
    return table.borrow<WASIComponentReadableFuture<T>, int>(
      readableFutureType!,
      readable,
      (future) {
        if (future.isReady) {
          _writeFixedWidthValueToMemory(
            valueValidator,
            name,
            memory,
            pointer,
            future.readForCopy(),
          );
          return WASIComponentAsyncCopyResult.completed(0).packedResult;
        }

        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentReadableFuture<T>,
              WASIComponentAsyncCopyResult
            >(readableFutureType!, readable, (future) {
              return future
                  .readWhenReadyForCopy()
                  .then<WASIComponentAsyncCopyResult>((value) {
                    _writeFixedWidthValueToMemory(
                      valueValidator,
                      name,
                      memory,
                      pointer,
                      value,
                    );
                    return WASIComponentAsyncCopyResult.completed(0);
                  });
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.futureRead,
          readable,
          pending,
        );
        return wasiComponentAsyncBlocked;
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
    _expectWritableFuture(writable).completeForCopy(value);
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
            future.completeForCopy(value);
            return WASIComponentAsyncCopyResult.completed(0);
          },
        );
  }

  int futureWriteHandleFromMemoryEvent(
    int writable,
    wasm.Memory memory,
    int pointer,
  ) {
    final waitable = _existingEndpointWaitable(writable);
    return table.borrow<WASIComponentWritableFuture<T>, int>(
      writableFutureType!,
      writable,
      (future) {
        final value = _readFixedWidthValueFromMemory<T>(
          valueValidator,
          name,
          memory,
          pointer,
        );
        if (!future.canComplete) {
          future.completeForCopy(value);
          return WASIComponentAsyncCopyResult.completed(0).packedResult;
        }
        if (future.hasPendingReader) {
          future.completeForCopy(value);
          return WASIComponentAsyncCopyResult.completed(0).packedResult;
        }

        waitable.beginCopy();
        final pending = table
            .borrowAsync<
              WASIComponentWritableFuture<T>,
              WASIComponentAsyncCopyResult
            >(writableFutureType!, writable, (future) {
              return future.completeWhenReadForCopy(value).then((_) {
                return WASIComponentAsyncCopyResult.completed(0);
              });
            });
        _publishCopyEvent(
          waitable,
          WASIComponentWaitableEventCode.futureWrite,
          writable,
          pending,
        );
        return wasiComponentAsyncBlocked;
      },
    );
  }

  void futureCancelRead(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectReadableFuture(readable).cancel();
  }

  int futureCancelReadHandle(int readable, {required bool isAsync}) {
    return _cancelCopy(
      handle: readable,
      eventCode: WASIComponentWaitableEventCode.futureRead,
      isAsync: isAsync,
      cancel: () {
        table.borrow<WASIComponentReadableFuture<T>, void>(
          readableFutureType!,
          readable,
          (future) {
            if (!future.isReady) {
              future.cancel();
            }
          },
        );
      },
    );
  }

  Future<int> futureCancelReadHandleWhenReady(
    int readable, {
    required bool isAsync,
  }) {
    return _cancelCopyWhenReady(
      handle: readable,
      eventCode: WASIComponentWaitableEventCode.futureRead,
      isAsync: isAsync,
      cancel: () {
        table.borrow<WASIComponentReadableFuture<T>, void>(
          readableFutureType!,
          readable,
          (future) {
            if (!future.isReady) {
              future.cancel();
            }
          },
        );
      },
    );
  }

  void futureCancelWrite(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectWritableFuture(writable).cancel();
  }

  int futureCancelWriteHandle(int writable, {required bool isAsync}) {
    return _cancelCopy(
      handle: writable,
      eventCode: WASIComponentWaitableEventCode.futureWrite,
      isAsync: isAsync,
      cancel: () {
        table.borrow<WASIComponentWritableFuture<T>, void>(
          writableFutureType!,
          writable,
          (future) {
            future.cancelWriteDelivery();
          },
        );
      },
    );
  }

  Future<int> futureCancelWriteHandleWhenReady(
    int writable, {
    required bool isAsync,
  }) {
    return _cancelCopyWhenReady(
      handle: writable,
      eventCode: WASIComponentWaitableEventCode.futureWrite,
      isAsync: isAsync,
      cancel: () {
        table.borrow<WASIComponentWritableFuture<T>, void>(
          writableFutureType!,
          writable,
          (future) {
            future.cancelWriteDelivery();
          },
        );
      },
    );
  }

  void futureDropReadable(Object? readable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectReadableFuture(readable).drop();
  }

  void futureDropReadableHandle(int readable) {
    _requireEndpointWaitableDroppable(readable);
    table.drop<WASIComponentReadableFuture<T>>(readableFutureType!, readable);
    endpointWaitables.remove(readable)?.drop();
  }

  void futureDropWritable(Object? writable) {
    _requireKind(_WASIComponentAsyncValueKind.future);
    _expectWritableFuture(writable).drop();
  }

  void futureDropWritableHandle(int writable) {
    _requireEndpointWaitableDroppable(writable);
    table.drop<WASIComponentWritableFuture<T>>(writableFutureType!, writable);
    endpointWaitables.remove(writable)?.drop();
  }

  WASIComponentWaitable? waitableForHandle(int handle) {
    if (readableStreamType != null &&
        table.containsType<WASIComponentReadableStream<T>>(
          readableStreamType!,
          handle,
        )) {
      return _endpointWaitable(handle, '$name.readable');
    }
    if (writableStreamType != null &&
        table.containsType<WASIComponentWritableStream<T>>(
          writableStreamType!,
          handle,
        )) {
      return _endpointWaitable(handle, '$name.writable');
    }
    if (readableFutureType != null &&
        table.containsType<WASIComponentReadableFuture<T>>(
          readableFutureType!,
          handle,
        )) {
      return _endpointWaitable(handle, '$name.readable');
    }
    if (writableFutureType != null &&
        table.containsType<WASIComponentWritableFuture<T>>(
          writableFutureType!,
          handle,
        )) {
      return _endpointWaitable(handle, '$name.writable');
    }
    return null;
  }

  WASIComponentWaitable _endpointWaitable(int handle, String name) {
    return endpointWaitables.putIfAbsent(
      handle,
      () => WASIComponentWaitable('$name#$handle'),
    );
  }

  WASIComponentWaitable _existingEndpointWaitable(int handle) {
    final waitable = waitableForHandle(handle);
    if (waitable != null) {
      return waitable;
    }
    throw StateError('Unknown WASI component async endpoint handle: $handle.');
  }

  void _requireEndpointWaitableDroppable(int handle) {
    endpointWaitables[handle]?.requireDroppable();
  }

  int _cancelCopy({
    required int handle,
    required WASIComponentWaitableEventCode eventCode,
    required bool isAsync,
    required void Function() cancel,
  }) {
    final waitable = _existingEndpointWaitable(handle);
    final event = waitable.cancelCopy(asynchronous: isAsync, cancel: cancel);
    if (event == null) {
      return wasiComponentAsyncBlocked;
    }
    return _expectCopyEventPayload(
      waitable: waitable,
      event: event,
      eventCode: eventCode,
      handle: handle,
    );
  }

  Future<int> _cancelCopyWhenReady({
    required int handle,
    required WASIComponentWaitableEventCode eventCode,
    required bool isAsync,
    required void Function() cancel,
  }) async {
    if (isAsync) {
      return _cancelCopy(
        handle: handle,
        eventCode: eventCode,
        isAsync: isAsync,
        cancel: cancel,
      );
    }
    final waitable = _existingEndpointWaitable(handle);
    final event = await waitable.cancelCopyWhenReady(cancel: cancel);
    return _expectCopyEventPayload(
      waitable: waitable,
      event: event,
      eventCode: eventCode,
      handle: handle,
    );
  }

  int _expectCopyEventPayload({
    required WASIComponentWaitable waitable,
    required WASIComponentWaitableEvent event,
    required WASIComponentWaitableEventCode eventCode,
    required int handle,
  }) {
    if (event.code != eventCode || event.payload1 != handle) {
      throw StateError(
        'WASI component waitable ${waitable.name} produced ${event.code.name} '
        'for handle ${event.payload1}, expected ${eventCode.name} for '
        'handle $handle.',
      );
    }
    return event.payload2;
  }

  void _publishCopyEvent(
    WASIComponentWaitable waitable,
    WASIComponentWaitableEventCode code,
    int handle,
    Future<WASIComponentAsyncCopyResult> result,
  ) {
    unawaited(
      result.then<void>(
        (copyResult) {
          waitable.setPendingEvent(
            () => WASIComponentWaitableEvent(
              code: code,
              payload1: handle,
              payload2: copyResult.packedResult,
            ),
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          final copyResult = switch (error) {
            WASIComponentAsyncEndpointStateError(
              failure: WASIComponentAsyncEndpointFailure.dropped,
            ) =>
              WASIComponentAsyncCopyResult.dropped(),
            WASIComponentAsyncEndpointStateError(
              failure: WASIComponentAsyncEndpointFailure.cancelled,
            ) =>
              WASIComponentAsyncCopyResult.cancelled(),
            _ => WASIComponentAsyncCopyResult.cancelled(),
          };
          waitable.setPendingEvent(
            () => WASIComponentWaitableEvent(
              code: code,
              payload1: handle,
              payload2: copyResult.packedResult,
            ),
          );
        },
      ),
    );
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
  if (primitive == WasmComponentPrimitiveValueType.errorContext) {
    throw UnsupportedError(
      'WASI component async host does not support error-context stream/future element values yet.',
    );
  }
  if (primitive != null) {
    return _WASIComponentAsyncValueValidator._(
      kind: _WASIComponentAsyncValueShape.primitive,
      primitive: primitive,
      memoryCodec: WASIComponentCanonicalValueMemoryCodec.fromValueType(
        elementType,
        definitions,
      ),
    );
  }
  final memoryCodec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
    elementType,
    definitions,
  );
  if (memoryCodec == null) {
    throw UnsupportedError(
      'WASI component async host currently supports only fixed-size stream/future element types.',
    );
  }
  return _WASIComponentAsyncValueValidator._(
    kind: _WASIComponentAsyncValueShape.canonicalValue,
    memoryCodec: memoryCodec,
  );
}

_WASIComponentAsyncValueValidator? _supportedAsyncValueValidatorForElementType(
  WasmComponentValueType? elementType,
  List<WasmComponentTypeDefinition> definitions,
) {
  try {
    return _asyncValueValidatorForElementType(elementType, definitions);
  } on UnsupportedError {
    return null;
  }
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
  final codec = validator.memoryCodec;
  if (codec == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a fixed-size memory element type.',
    );
  }
  final loaded = codec.loadMany(memory, pointer, elementCount);
  final values = <T>[];
  for (final value in loaded) {
    validator.validate(name, value);
    if (value is! T) {
      throw StateError('WASI component async type $name expected $T value.');
    }
    values.add(value);
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
  final codec = validator.memoryCodec;
  if (codec == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a fixed-size memory element type.',
    );
  }
  final value = codec.load(memory, pointer);
  validator.validate(name, value);
  if (value is! T) {
    throw StateError('WASI component async type $name expected $T value.');
  }
  return value;
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
  final codec = validator.memoryCodec;
  if (codec == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a fixed-size memory element type.',
    );
  }
  codec.storeMany(memory, pointer, values);
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
  final codec = validator.memoryCodec;
  if (codec == null) {
    throw UnsupportedError(
      'WASI component async type $name does not have a fixed-size memory element type.',
    );
  }
  codec.store(memory, pointer, value);
}

WASIComponentAsyncValueMemoryLayout? _fixedWidthMemoryLayoutFor(
  _WASIComponentAsyncValueValidator validator,
) {
  final codec = validator.memoryCodec;
  if (codec == null) {
    return null;
  }
  return WASIComponentAsyncValueMemoryLayout._(
    byteLength: codec.byteLength,
    alignment: codec.alignment,
  );
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

void _checkU32Handle(int handle, String name) {
  RangeError.checkNotNegative(handle, name);
  if (handle > _u32Mask) {
    throw RangeError.range(handle, 0, _u32Mask, name);
  }
}

int _normalizeI64Bits(int value, String name) {
  if (value >= 0) {
    if (value.bitLength > 64) {
      throw RangeError.value(value, name, 'does not fit in an unsigned i64');
    }
    return value.toUnsigned(64);
  }
  if (value < _i64Min) {
    throw RangeError.value(value, name, 'does not fit in a signed i64');
  }
  return value.toUnsigned(64);
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
