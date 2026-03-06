import '../../global.dart' as wasm;
import '../../value.dart';

/// A simple mutable/immutable value box implementing [wasm.Global].
class Global<T extends Value<T, V>, V extends Object?>
    implements wasm.Global<T, V> {
  Global(wasm.GlobalDescriptor<T, V> descriptor, V initialValue)
    : _mutable = descriptor.mutable,
      _value = initialValue;

  final bool _mutable;
  V _value;

  @override
  V get value => _value;

  @override
  set value(V v) {
    if (!_mutable) throw StateError('Cannot set value of immutable global');
    _value = v;
  }
}
