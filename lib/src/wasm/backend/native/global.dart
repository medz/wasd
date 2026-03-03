import '../../global.dart' as wasm;
import '../../value.dart';

class Global<T extends Value<T, V>, V extends Object?>
    implements wasm.Global<T, V> {
  Global(this.descriptor, this._value);

  final wasm.GlobalDescriptor<T, V> descriptor;
  V _value;

  @override
  V get value => _value;

  @override
  set value(V value) {
    if (!descriptor.mutable) {
      throw StateError('Cannot set value of immutable global');
    }
    _value = value;
  }
}
