import 'backend/native/exception.dart'
    if (dart.library.js_interop) 'backend/js/exception.dart'
    as backend;
import 'tag.dart';

/// Options used when creating a WebAssembly [Exception].
class ExceptionOptions {
  /// Creates exception creation options.
  const ExceptionOptions({this.traceStack = false});

  /// Whether runtime should capture stack trace information when available.
  final bool traceStack;
}

/// Represents a WebAssembly exception instance.
abstract interface class Exception {
  /// Creates an exception with [tag], ordered payload [values], and [options].
  factory Exception(
    Tag tag,
    List<Object?> payload, [
    ExceptionOptions? options,
  ]) = backend.Exception;

  /// Returns whether this exception matches [tag] (maps to JS `is(tag)`).
  bool isTag(Tag tag);

  /// Returns payload value at [index] interpreted for [tag].
  Object? getArg(Tag tag, int index);
}
