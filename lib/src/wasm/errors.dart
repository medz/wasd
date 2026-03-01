/// Base class for all WebAssembly-related errors.
abstract class WasmError extends Error {
  /// Creates a [WasmError] with a [message] and optional [cause].
  WasmError(this.message, {this.cause});

  /// Human-readable error message.
  final String message;

  /// Optional underlying cause of the error.
  final Object? cause;
}

/// Thrown when compilation fails.
class CompileError extends WasmError {
  /// Creates a [CompileError] with a [message] and optional [cause].
  CompileError(super.message, {super.cause});
}

/// Thrown when linking fails.
class LinkError extends WasmError {
  /// Creates a [LinkError] with a [message] and optional [cause].
  LinkError(super.message, {super.cause});
}

/// Thrown when execution fails at runtime.
class RuntimeError extends WasmError {
  /// Creates a [RuntimeError] with a [message] and optional [cause].
  RuntimeError(super.message, {super.cause});
}
