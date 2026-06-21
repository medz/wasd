import '../../wasm/backend/native/interpreter/component.dart';

/// Current Canonical ABI limit for `context.get/set` indexes.
const int wasiComponentContextSlotCount = 2;

const int _maxU32 = 0xffffffff;

/// Thread-local storage for Component Model `context.get/set`.
final class WASIComponentContext {
  /// Creates a context with zero-initialized i32 storage.
  WASIComponentContext({
    String name = 'context',
    Iterable<int> initialSlots = const [],
  }) : _name = name,
       _slots = List<int>.filled(wasiComponentContextSlotCount, 0) {
    var index = 0;
    for (final value in initialSlots) {
      if (index >= wasiComponentContextSlotCount) {
        throw StateError(
          'WASI component context $name has too many initial slots.',
        );
      }
      set(index, value);
      index++;
    }
  }

  final String _name;
  final List<int> _slots;

  /// Debug label used in diagnostics.
  String get name => _name;

  /// Returns the i32 bit pattern stored in [index].
  int get(int index) {
    _checkIndex(index);
    return _slots[index];
  }

  /// Stores the i32 bit pattern [value] in [index].
  void set(int index, int value) {
    _checkIndex(index);
    RangeError.checkValueInInterval(value, 0, _maxU32, 'value');
    _slots[index] = value;
  }

  void _checkIndex(int index) {
    RangeError.checkValueInInterval(
      index,
      0,
      wasiComponentContextSlotCount - 1,
      'contextIndex',
    );
  }
}

/// Host for canonical `context.get` and `context.set` operations.
final class WASIComponentContextHost {
  /// Creates a context host with a default current context.
  WASIComponentContextHost({WASIComponentContext? context})
    : _currentContext = context ?? WASIComponentContext();

  WASIComponentContext _currentContext;

  /// Current thread-local context.
  WASIComponentContext get currentContext => _currentContext;

  /// Runs [callback] with [context] as the current thread-local context.
  T runWithContext<T>(WASIComponentContext context, T Function() callback) {
    final previous = _currentContext;
    _currentContext = context;
    try {
      return callback();
    } finally {
      _currentContext = previous;
    }
  }

  /// Runs [callback] with [context] as the current context until it completes.
  Future<T> runWithContextAsync<T>(
    WASIComponentContext context,
    Future<T> Function() callback,
  ) async {
    final previous = _currentContext;
    _currentContext = context;
    try {
      return await callback();
    } finally {
      _currentContext = previous;
    }
  }

  /// Executes `context.get`.
  int contextGet(int index) {
    return _currentContext.get(index);
  }

  /// Executes `context.set`.
  void contextSet(int index, int value) {
    _currentContext.set(index, value);
  }

  /// Binds a decoded canonical context definition.
  WASIComponentCanonicalContextOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    if (!_isContextCanonicalKind(definition.kind)) {
      throw UnsupportedError(
        'Wasm component canonical ${definition.kind.name} is not a context operation.',
      );
    }
    final index = definition.contextIndex;
    if (index == null || index >= wasiComponentContextSlotCount) {
      throw StateError('Unknown WASI component context index: $index.');
    }
    return WASIComponentCanonicalContextOperation._(
      host: this,
      kind: definition.kind,
      index: index,
    );
  }

  /// Binds all decoded canonical context definitions in [component].
  WASIComponentCanonicalContextProgram bindCanonicalDefinitions(
    WasmComponent component,
  ) {
    return WASIComponentCanonicalContextProgram(
      operations: List<WASIComponentCanonicalContextOperation>.unmodifiable([
        for (final definition in component.canonicalDefinitions)
          bindCanonicalDefinition(definition),
      ]),
    );
  }
}

/// Executable context-only canonical program for a decoded component.
final class WASIComponentCanonicalContextProgram {
  /// Creates a canonical context program from ordered [operations].
  const WASIComponentCanonicalContextProgram({required this.operations});

  /// Context operations in component canonical definition order.
  final List<WASIComponentCanonicalContextOperation> operations;

  /// Invokes the canonical context operation at [canonicalIndex].
  Object? invoke(int canonicalIndex, List<Object?> args) {
    final operation = _operationAt(canonicalIndex);
    switch (operation.kind) {
      case WasmComponentCanonicalKind.contextGet:
        _expectArity(canonicalIndex, args, 0);
        return operation.contextGet();
      case WasmComponentCanonicalKind.contextSet:
        _expectArity(canonicalIndex, args, 1);
        operation.contextSet(_expectI32(canonicalIndex, args.single));
        return null;
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the context program.',
        );
    }
  }

  WASIComponentCanonicalContextOperation _operationAt(int canonicalIndex) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical context index: $canonicalIndex.',
      );
    }
    return operations[canonicalIndex];
  }
}

/// Executable form of a canonical context operation.
final class WASIComponentCanonicalContextOperation {
  const WASIComponentCanonicalContextOperation._({
    required WASIComponentContextHost host,
    required this.kind,
    required this.index,
  }) : _host = host;

  final WASIComponentContextHost _host;

  /// Canonical context operation kind.
  final WasmComponentCanonicalKind kind;

  /// Context slot index targeted by this operation.
  final int index;

  /// Executes `context.get`.
  int contextGet() {
    _requireKind(WasmComponentCanonicalKind.contextGet);
    return _host.contextGet(index);
  }

  /// Executes `context.set`.
  void contextSet(int value) {
    _requireKind(WasmComponentCanonicalKind.contextSet);
    _host.contextSet(index, value);
  }

  void _requireKind(WasmComponentCanonicalKind expected) {
    if (kind != expected) {
      throw StateError(
        'WASI component canonical ${kind.name} cannot execute ${expected.name}.',
      );
    }
  }
}

bool _isContextCanonicalKind(WasmComponentCanonicalKind kind) =>
    kind == WasmComponentCanonicalKind.contextGet ||
    kind == WasmComponentCanonicalKind.contextSet;

void _expectArity(int canonicalIndex, List<Object?> args, int expected) {
  if (args.length != expected) {
    throw StateError(
      'WASI component canonical context index $canonicalIndex expected '
      '$expected arguments, got ${args.length}.',
    );
  }
}

int _expectI32(int canonicalIndex, Object? value) {
  if (value is int && value >= 0 && value <= _maxU32) {
    return value;
  }
  throw StateError(
    'WASI component canonical context index $canonicalIndex expected i32.',
  );
}
