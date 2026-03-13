@JS()
library;

import 'dart:js_interop';

import '../../errors.dart';

/// Translates a caught JS [e] into the matching Dart [WasmError] subtype.
///
/// [WebAssembly.CompileError] → [CompileError]
/// [WebAssembly.LinkError]    → [LinkError]
/// anything else              → [RuntimeError]
///
/// Re-throws non-JS errors with their original stack trace.
Never translateJsError(Object e, StackTrace st) {
  // ignore: invalid_runtime_check_with_js_interop_types
  if (e is JSObject) {
    final err = e as _JSError;
    throw switch (err.name) {
      'CompileError' => CompileError(err.message, cause: e),
      'LinkError' => LinkError(err.message, cause: e),
      _ => RuntimeError(err.message, cause: e),
    };
  }
  Error.throwWithStackTrace(e, st);
}

extension type _JSError._(JSObject _) implements JSObject {
  external String get name;
  external String get message;
}
