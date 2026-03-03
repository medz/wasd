import 'value.dart';
import 'backend/native/global.dart'
    if (dart.library.js_interop) 'backend/js/global.dart'
    as backend;

/// Describes a WebAssembly global variable.
class GlobalDescriptor<T extends Value<T, V>, V extends Object?> {
  /// Creates a global descriptor with value [value] and mutability.
  const GlobalDescriptor({required this.value, this.mutable = false});

  /// Value kind of this global.
  final ValueKind<T, V> value;

  /// Whether this global can be updated after initialization.
  final bool mutable;
}

/// Represents a WebAssembly global variable instance.
abstract interface class Global<T extends Value<T, V>, V extends Object?> {
  /// Creates a global from [descriptor] and initial [value].
  factory Global(GlobalDescriptor<T, V> descriptor, V value) =
      backend.Global<T, V>;

  /// Current value of this global.
  V get value;

  /// Updates the current value when the global is mutable.
  set value(V value);
}
