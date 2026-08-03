import '../../wasm/backend/native/interpreter/component.dart';
import 'context.dart';
import 'current.dart';
import 'waitable_set.dart';

const int _maxU32 = 0xffffffff;

/// Host-side Component Model thread identity.
final class WASIComponentThread {
  const WASIComponentThread._({
    required this.index,
    required this.context,
    required String name,
  }) : _name = name;

  /// Canonical thread table index.
  final int index;

  /// Thread-local storage owned by this thread.
  final WASIComponentContext context;

  final String _name;

  /// Debug label used in diagnostics.
  String get name => _name;
}

/// Host for thread identity and thread-local context canonical operations.
final class WASIComponentThreadHost {
  /// Creates a thread host with one implicit current thread.
  WASIComponentThreadHost({
    WASIComponentContextHost? contextHost,
    WASIComponentWaitableHost? waitableHost,
    int availableParallelism = 1,
  }) : contextHost = contextHost ?? WASIComponentContextHost(),
       _waitableHost = waitableHost {
    RangeError.checkValueInInterval(
      availableParallelism,
      1,
      _maxU32,
      'availableParallelism',
    );
    _availableParallelism = availableParallelism;
    final thread = _registerThread(
      name: 'implicit-thread',
      context: this.contextHost.currentContext,
    );
    _currentThread = WASIComponentCurrent<WASIComponentThread>(thread);
  }

  /// Context host used by current-thread execution.
  final WASIComponentContextHost contextHost;
  final WASIComponentWaitableHost? _waitableHost;

  final Map<int, WASIComponentThread> _threads = <int, WASIComponentThread>{};
  late final WASIComponentCurrent<WASIComponentThread> _currentThread;
  late final int _availableParallelism;
  int _nextThreadIndex = 0;

  /// Current thread.
  WASIComponentThread get currentThread => _currentThread.current!;

  /// Number of registered threads.
  int get threadCount => _threads.length;

  /// Creates a host-managed thread identity for future scheduling.
  WASIComponentThread createThread({
    String name = 'thread',
    WASIComponentContext? context,
  }) {
    return _registerThread(
      name: name,
      context: context ?? WASIComponentContext(name: '$name-context'),
    );
  }

  /// Runs [callback] with [thread] as the current thread and context.
  T runWithThread<T>(WASIComponentThread thread, T Function() callback) {
    _requireRegistered(thread);
    return _currentThread.run(
      thread,
      () => contextHost.runWithContext(thread.context, callback),
    );
  }

  /// Runs [callback] with [thread] as the current thread until it completes.
  Future<T> runWithThreadAsync<T>(
    WASIComponentThread thread,
    Future<T> Function() callback,
  ) async {
    _requireRegistered(thread);
    return await _currentThread.runAsync(
      thread,
      () => contextHost.runWithContextAsync(thread.context, callback),
    );
  }

  /// Executes `thread.index`.
  int threadIndex() {
    return currentThread.index;
  }

  /// Executes `thread.available-parallelism`.
  int threadAvailableParallelism() {
    return _availableParallelism;
  }

  /// Executes `thread.yield`.
  ///
  /// Returns the Canonical ABI `Cancelled` value for the yield.
  Future<int> threadYield({bool cancellable = false}) async {
    if (cancellable && (_waitableHost?.deliverTaskCancellation() ?? false)) {
      return 1;
    }
    await Future<void>.delayed(Duration.zero);
    if (cancellable && (_waitableHost?.deliverTaskCancellation() ?? false)) {
      return 1;
    }
    return 0;
  }

  /// Binds a decoded canonical thread definition.
  WASIComponentCanonicalThreadOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    if (!_isSupportedThreadCanonicalKind(definition.kind)) {
      throw UnsupportedError(
        'Wasm component canonical ${definition.kind.name} is not a supported thread operation.',
      );
    }
    return WASIComponentCanonicalThreadOperation._(
      host: this,
      kind: definition.kind,
      shared: definition.isShared,
      cancellable: definition.isCancellable,
    );
  }

  /// Binds all decoded supported thread canonical definitions in [component].
  WASIComponentCanonicalThreadProgram bindCanonicalDefinitions(
    WasmComponent component,
  ) {
    return WASIComponentCanonicalThreadProgram(
      operations: List<WASIComponentCanonicalThreadOperation>.unmodifiable([
        for (final definition in component.canonicalDefinitions)
          bindCanonicalDefinition(definition),
      ]),
    );
  }

  WASIComponentThread _registerThread({
    required String name,
    required WASIComponentContext context,
  }) {
    if (_nextThreadIndex > _maxU32) {
      throw StateError('WASI component thread index overflow.');
    }
    final index = _nextThreadIndex++;
    final thread = WASIComponentThread._(
      index: index,
      context: context,
      name: name,
    );
    _threads[index] = thread;
    return thread;
  }

  void _requireRegistered(WASIComponentThread thread) {
    if (!identical(_threads[thread.index], thread)) {
      throw StateError('Unknown WASI component thread: ${thread.index}.');
    }
  }
}

/// Executable supported-thread canonical program for a decoded component.
final class WASIComponentCanonicalThreadProgram {
  /// Creates a canonical thread program from ordered [operations].
  const WASIComponentCanonicalThreadProgram({required this.operations});

  /// Thread operations in component canonical definition order.
  final List<WASIComponentCanonicalThreadOperation> operations;

  /// Invokes the canonical thread operation at [canonicalIndex].
  Object? invoke(int canonicalIndex, List<Object?> args) {
    final operation = _operationAt(canonicalIndex);
    switch (operation.kind) {
      case WasmComponentCanonicalKind.threadIndex:
        _expectArity(canonicalIndex, args, 0);
        return operation.threadIndex();
      case WasmComponentCanonicalKind.threadAvailableParallelism:
        _expectArity(canonicalIndex, args, 0);
        return operation.threadAvailableParallelism();
      case WasmComponentCanonicalKind.threadYield:
        throw UnsupportedError(
          'Wasm component canonical thread.yield is asynchronous; use invokeAsync.',
        );
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the thread program.',
        );
    }
  }

  /// Invokes the asynchronous canonical thread operation at [canonicalIndex].
  Future<Object?> invokeAsync(int canonicalIndex, List<Object?> args) async {
    final operation = _operationAt(canonicalIndex);
    switch (operation.kind) {
      case WasmComponentCanonicalKind.threadYield:
        _expectArity(canonicalIndex, args, 0);
        return await operation.threadYield();
      default:
        return invoke(canonicalIndex, args);
    }
  }

  WASIComponentCanonicalThreadOperation _operationAt(int canonicalIndex) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical thread index: $canonicalIndex.',
      );
    }
    return operations[canonicalIndex];
  }
}

/// Executable form of a supported canonical thread operation.
final class WASIComponentCanonicalThreadOperation {
  const WASIComponentCanonicalThreadOperation._({
    required WASIComponentThreadHost host,
    required this.kind,
    required this.shared,
    required this.cancellable,
  }) : _host = host;

  final WASIComponentThreadHost _host;

  /// Canonical thread operation kind.
  final WasmComponentCanonicalKind kind;

  /// Whether the decoded definition used the shared flag.
  final bool shared;

  /// Whether the operation may deliver cooperative task cancellation.
  final bool cancellable;

  /// Executes `thread.index`.
  int threadIndex() {
    _requireKind(WasmComponentCanonicalKind.threadIndex);
    return _host.threadIndex();
  }

  /// Executes `thread.available-parallelism`.
  int threadAvailableParallelism() {
    _requireKind(WasmComponentCanonicalKind.threadAvailableParallelism);
    return _host.threadAvailableParallelism();
  }

  /// Executes `thread.yield`.
  Future<int> threadYield() {
    _requireKind(WasmComponentCanonicalKind.threadYield);
    return _host.threadYield(cancellable: cancellable);
  }

  void _requireKind(WasmComponentCanonicalKind expected) {
    if (kind != expected) {
      throw StateError(
        'WASI component canonical ${kind.name} cannot execute ${expected.name}.',
      );
    }
  }
}

bool _isSupportedThreadCanonicalKind(WasmComponentCanonicalKind kind) {
  return kind == WasmComponentCanonicalKind.threadYield ||
      kind == WasmComponentCanonicalKind.threadIndex ||
      kind == WasmComponentCanonicalKind.threadAvailableParallelism;
}

void _expectArity(int canonicalIndex, List<Object?> args, int expected) {
  if (args.length != expected) {
    throw StateError(
      'WASI component canonical thread index $canonicalIndex expected '
      '$expected arguments, got ${args.length}.',
    );
  }
}
