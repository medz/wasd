import 'dart:async';

import '../../wasm/backend/native/interpreter/component.dart';
import 'context.dart';

const int _maxU32 = 0xffffffff;
final Object _currentThreadZoneKey = Object();

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
    int availableParallelism = 1,
  }) : contextHost = contextHost ?? WASIComponentContextHost() {
    RangeError.checkValueInInterval(
      availableParallelism,
      1,
      _maxU32,
      'availableParallelism',
    );
    _availableParallelism = availableParallelism;
    _currentThread = _registerThread(
      name: 'implicit-thread',
      context: this.contextHost.currentContext,
    );
  }

  /// Context host used by current-thread execution.
  final WASIComponentContextHost contextHost;

  final Map<int, WASIComponentThread> _threads = <int, WASIComponentThread>{};
  late WASIComponentThread _currentThread;
  late final int _availableParallelism;
  int _nextThreadIndex = 0;
  int _syncThreadDepth = 0;

  /// Current thread.
  WASIComponentThread get currentThread {
    if (_syncThreadDepth > 0) {
      return _currentThread;
    }
    if (!identical(Zone.current, Zone.root)) {
      final thread = Zone.current[_currentThreadZoneKey];
      if (thread is WASIComponentThread) {
        return thread;
      }
    }
    return _currentThread;
  }

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
    final previous = _currentThread;
    _currentThread = thread;
    _syncThreadDepth++;
    try {
      return contextHost.runWithContext(thread.context, callback);
    } finally {
      _currentThread = previous;
      _syncThreadDepth--;
    }
  }

  /// Runs [callback] with [thread] as the current thread until it completes.
  Future<T> runWithThreadAsync<T>(
    WASIComponentThread thread,
    Future<T> Function() callback,
  ) async {
    _requireRegistered(thread);
    return await runZoned<Future<T>>(
      () => contextHost.runWithContextAsync(thread.context, callback),
      zoneValues: <Object?, Object?>{_currentThreadZoneKey: thread},
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
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the thread program.',
        );
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
  }) : _host = host;

  final WASIComponentThreadHost _host;

  /// Canonical thread operation kind.
  final WasmComponentCanonicalKind kind;

  /// Whether the decoded definition used the shared flag.
  final bool shared;

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

  void _requireKind(WasmComponentCanonicalKind expected) {
    if (kind != expected) {
      throw StateError(
        'WASI component canonical ${kind.name} cannot execute ${expected.name}.',
      );
    }
  }
}

bool _isSupportedThreadCanonicalKind(WasmComponentCanonicalKind kind) {
  return kind == WasmComponentCanonicalKind.threadIndex ||
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
