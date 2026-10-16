import 'backend/native/tag.dart'
    if (dart.library.js_interop) 'backend/js/tag.dart'
    as backend;
import 'value.dart';

/// Describes the payload signature of a WebAssembly exception tag.
class TagDescriptor {
  /// Creates a tag descriptor with required payload [parameters].
  const TagDescriptor({required this.parameters});

  /// Ordered value kinds of payload fields associated with this tag.
  final List<ValueKind> parameters;
}

/// Represents a WebAssembly exception tag.
abstract interface class Tag {
  /// Creates a tag from [descriptor].
  ///
  /// The tag snapshots the ordered parameters. Native module bindings currently
  /// support empty and numeric (`i32`, `i64`, `f32`, `f64`) payloads.
  factory Tag(TagDescriptor descriptor) = backend.Tag;

  /// Returns the tag type information.
  ///
  /// The returned parameters are an independent snapshot.
  TagDescriptor type();
}
