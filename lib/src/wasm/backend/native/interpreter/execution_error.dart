/// Diagnostic execution wrapper that preserves its original failure.
abstract interface class WasmExecutionErrorContext implements Exception {
  /// Failure wrapped with the current Core execution location.
  Object get cause;
}
