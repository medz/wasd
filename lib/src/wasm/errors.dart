class WebAssemblyError extends Error {
  WebAssemblyError(this.message, {this.cause});

  final String message;
  final Object? cause;
}

class CompileError extends WebAssemblyError {
  CompileError(super.message, {super.cause});
}

class LinkError extends WebAssemblyError {
  LinkError(super.message, {super.cause});
}
