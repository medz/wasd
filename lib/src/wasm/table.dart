import 'value.dart';

/// Element kind marker for WebAssembly tables.
enum TableKind<T extends Value<T, V>, V extends Object?> {
  /// Function reference table.
  funcref(.funcref, {'anyfunc'}),

  /// External reference table.
  externref(.externref);

  /// Creates a table kind from a value kind and optional aliases.
  const TableKind(this.value, [this.aliases = const {}]);

  /// Alternative textual names accepted for this kind.
  final Set<String> aliases;

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
abstract class Table<T extends Value<T, V>, V extends Object?>
    with Iterable<V> {
  /// Creates a table interface from [descriptor] and default [fill].
  Table(this.descriptor, this.fill);

  /// Descriptor of this table.
  final TableDescriptor<T, V> descriptor;

  /// Default fill value used by grow operations.
  final V fill;

  /// Grows table length by [delta], optionally overriding fill [value].
  int grow(int delta, [V? value]);
}
