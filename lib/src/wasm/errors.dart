abstract class WasmError extends Error {
  WasmError(this.message, {this.cause});

  final String message;
  final Object? cause;
}

class CompileError extends WasmError {
  CompileError(super.message, {super.cause});
}

class LinkError extends WasmError {
  LinkError(super.message, {super.cause});
}

class RuntimeError extends WasmError {
  RuntimeError(super.message, {super.cause});
}
