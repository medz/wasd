import 'value.dart';
import 'backend/native/table.dart'
    if (dart.library.js_interop) 'backend/js/table.dart'
    as backend;

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
abstract interface class Table<T extends Value<T, V>, V extends Object?> {
  /// Creates a table from [descriptor] and optional initial [value].
  factory Table(TableDescriptor<T, V> descriptor, [V? value]) =
      backend.Table<T, V>;

  /// Current table length.
  int get length;

  /// Returns the element at [index], or `null` for an empty slot.
  V? get(int index);

  /// Writes [value] into the element slot at [index].
  void set(int index, V? value);

  /// Grows table length by [delta], optionally using fill [value].
  int grow(int delta, [V? value]);
}
