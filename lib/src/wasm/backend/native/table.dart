import '../../table.dart' as wasm;
import '../../value.dart';

class Table<T extends Value<T, V>, V extends Object?>
    implements wasm.Table<T, V> {
  Table(this.descriptor, [V? value])
    : _values = List<V?>.filled(descriptor.initial, value, growable: true);

  final wasm.TableDescriptor<T, V> descriptor;
  final List<V?> _values;

  @override
  int get length => _values.length;

  @override
  V? get(int index) => _values[index];

  @override
  void set(int index, V? value) {
    _values[index] = value;
  }

  @override
  int grow(int delta, [V? value]) {
    if (delta < 0) {
      throw ArgumentError.value(delta, 'delta', 'must be >= 0');
    }

    final oldLength = _values.length;
    final nextLength = oldLength + delta;
    final maximum = descriptor.maximum;
    if (maximum != null && nextLength > maximum) {
      throw RangeError('Table maximum exceeded: $nextLength > $maximum');
    }

    _values.length = nextLength;
    if (delta > 0) {
      _values.fillRange(oldLength, nextLength, value);
    }
    return oldLength;
  }
}
