import 'value.dart';

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
class Global<T extends Value<T, V>, V extends Object?> {
  /// Creates a global from [descriptor] and initial [value].
  Global(this._descriptor, this._value);

  final GlobalDescriptor<T, V> _descriptor;
  V _value;

  /// Current value of this global.
  V get value => _value;

  /// Updates the current value when the global is mutable.
  set value(V value) {
    if (!_descriptor.mutable) {
      throw StateError('Cannot set value of immutable global');
    }

    _value = value;
  }
}
