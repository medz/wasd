import '../../global.dart' as wasm;
import '../../value.dart';

class Global<T extends Value<T, V>, V extends Object?>
    implements wasm.Global<T, V> {
  Global(this.descriptor, this.currentValue);

  final wasm.GlobalDescriptor<T, V> descriptor;
  V currentValue;

  @override
  V get value => currentValue;

  @override
  set value(V value) {
    if (!descriptor.mutable) {
      throw StateError('Cannot set value of immutable global');
    }
    currentValue = value;
  }
}
