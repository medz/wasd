@JS()
library;

import 'dart:js_interop';

import '../../table.dart' as wasm;
import '../../value.dart';
import 'value_codec.dart' as codec;

class Table<T extends Value<T, V>, V extends Object?>
    implements wasm.Table<T, V> {
  Table(this.descriptor, [V? value])
    : _host = _createHost(
        descriptor,
        value == null ? null : codec.encodeRef(descriptor.element.value, value),
      );

  final wasm.TableDescriptor<T, V> descriptor;
  final JSTable _host;

  @override
  int get length => _host.length;

  @override
  V? get(int index) {
    final raw = _host.get(index);
    if (raw == null) {
      return null;
    }
    return codec.decodeRef(descriptor.element.value, raw);
  }

  @override
  void set(int index, V? value) {
    if (value == null) {
      _host.set(index, null);
      return;
    }
    _host.set(index, codec.encodeRef(descriptor.element.value, value));
  }

  @override
  int grow(int delta, [V? value]) {
    if (value == null) {
      return _host.grow(delta);
    }
    return _host.grow(delta, codec.encodeRef(descriptor.element.value, value));
  }
}

JSTable _createHost<T extends Value<T, V>, V extends Object?>(
  wasm.TableDescriptor<T, V> descriptor,
  JSAny? value,
) {
  final tableDescriptor = JSTableDescriptor(
    element: (descriptor.element.alias ?? descriptor.element.name).toJS,
    initial: descriptor.initial,
    maximum: descriptor.maximum,
  );
  if (value == null) {
    return JSTable(tableDescriptor);
  }
  return JSTable(tableDescriptor, value);
}

extension type JSTableDescriptor._(JSObject _) implements JSObject {
  external factory JSTableDescriptor({
    required JSString element,
    required int initial,
    int? maximum,
  });
}

@JS('WebAssembly.Table')
extension type JSTable._(JSObject _) implements JSObject {
  external factory JSTable(JSTableDescriptor descriptor, [JSAny? value]);

  external int get length;
  external JSAny? get(int index);
  external void set(int index, JSAny? value);
  external int grow(int delta, [JSAny? value]);
}
