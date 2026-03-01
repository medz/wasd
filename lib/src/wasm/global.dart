import 'value.dart';

class GlobalDescriptor<T extends Value<T, V>, V extends Object?> {
  const GlobalDescriptor({required this.value, this.mutable = false});

  final ValueKind<T, V> value;
  final bool mutable;
}

class Global<T extends Value<T, V>, V extends Object?> {
  Global(this._descriptor, this._value);

  final GlobalDescriptor<T, V> _descriptor;
  V _value;

  V get value => _value;
  set value(V value) {
    if (!_descriptor.mutable) {
      throw StateError('Cannot set value of immutable global');
    }

    _value = value;
  }
}
