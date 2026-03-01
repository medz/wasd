import 'value.dart';

enum TableKind<T extends Value<T, V>, V extends Object?> {
  funcref(.funcref, {'anyfunc'}),
  externref(.externref);

  const TableKind(this.value, [this.aliases = const {}]);

  final Set<String> aliases;
  final ValueKind<T, V> value;
}

class TableDescriptor<T extends Value<T, V>, V extends Object?> {
  final TableKind<T, V> element;
  final int initial;
  final int? maximum;

  const TableDescriptor(this.element, this.initial, [this.maximum]);
}

class Table<T extends Value<T, V>, V extends Object?> with Iterable<V> {
  Table(this._descriptor, this._fill)
    : _elements = List.filled(_descriptor.initial, _fill, growable: true) {
    final TableDescriptor(:initial, :maximum) = _descriptor;
    if (maximum != null && maximum < initial) {
      throw RangeError.range(
        maximum,
        0,
        initial,
        'maximum',
        'must be greater than or equal to initial',
      );
    }
  }

  final TableDescriptor<T, V> _descriptor;
  final List<V> _elements;
  final V _fill;

  @override
  Iterator<V> get iterator => _elements.iterator;

  @override
  int get length => _elements.length;

  int grow(int delta, [V? value]) {
    final prevLength = _elements.length;
    final TableDescriptor(:initial, :maximum) = _descriptor;
    if (maximum != null && maximum < initial + delta) {
      final maxDelta = maximum - initial;
      throw RangeError.range(maximum, 0, maxDelta, 'delta');
    }

    _elements.addAll([for (int i = 0; i < delta; i++) value ?? _fill]);
    return prevLength;
  }
}

// /** [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Table) */
// interface Table {
//   /** [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Table/length) */
//   readonly length: number;
//   /** [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Table/get) */
//   get(index: number): any;
//   /** [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Table/grow) */
//   grow(delta: number, value?: any): number;
//   /** [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Table/set) */
//   set(index: number, value?: any): void;
// }

// var Table: {
//   prototype: Table;
//   new (descriptor: TableDescriptor, value?: any): Table;
// };
