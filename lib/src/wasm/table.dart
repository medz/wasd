import 'value.dart';

/// Element kind marker for WebAssembly tables.
enum TableKind<T extends Value<T, V>, V extends Object?> {
  /// Function reference table.
  funcref(.funcref, 'anyfunc'),

  /// External reference table.
  externref(.externref);

  /// Creates a table kind from a value kind and optional alias.
  const TableKind(this.value, [this.alias]);

  /// Alternative textual alias accepted for this kind.
  final String? alias;

  /// Value kind used by table elements.
  final ValueKind<T, V> value;
}

/// Describes the limits and element kind of a WebAssembly table.
class TableDescriptor<T extends Value<T, V>, V extends Object?> {
  /// Creates a table descriptor.
  const TableDescriptor(this.element, this.initial, [this.maximum]);

  /// Element kind of the table.
  final TableKind<T, V> element;

  /// Initial element count.
  final int initial;

  /// Optional maximum element count.
  final int? maximum;
}

/// Minimal table interface.
abstract interface class Table<T extends Value<T, V>, V extends Object?>
    implements Iterable<V> {
  /// Descriptor of this table.
  TableDescriptor<T, V> get descriptor;

  /// Default fill value used by grow operations.
  V get fill;

  /// Grows table length by [delta], optionally overriding fill [value].
  int grow(int delta, [V? value]);
}
