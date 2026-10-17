/// Diagnostic execution wrapper that preserves its original failure.
abstract interface class WasmExecutionErrorContext implements Exception {
  /// Failure wrapped with the current Core execution location.
  Object get cause;
}

/// A Core `unreachable` instruction, distinct from an ordinary host failure.
final class WasmUnreachableTrap extends StateError {
  /// Preserves the existing StateError message and type compatibility.
  WasmUnreachableTrap() : super('unreachable trap');
}
