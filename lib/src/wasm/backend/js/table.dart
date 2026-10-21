@JS()
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../table.dart' as wasm;
import '../../value.dart';
import 'value_codec.dart' as codec;

class Table<T extends Value<T, V>, V extends Object?>
    implements wasm.Table<T, V> {
  Table(this.descriptor, [V? value])
    : host = createHost(
        descriptor,
        value == null ? null : codec.encodeRef(descriptor.element.value, value),
      );

  final wasm.TableDescriptor<T, V> descriptor;
  final JSTable host;

  @override
  int get length => host.length;

  @override
  V? get(int index) => decodeReference(host.get(index)) as V?;

  @override
  void set(int index, V? value) {
    if (value == null) {
      host.set(index, null);
      return;
    }
    host.set(index, codec.encodeRef(descriptor.element.value, value));
  }

  @override
  int grow(int delta, [V? value]) {
    if (value == null) {
      return host.grow(delta);
    }
    return host.grow(delta, codec.encodeRef(descriptor.element.value, value));
  }
}

Object? decodeReference(JSAny? value) {
  if (value == null) return null;
  if (value.typeofEquals('bigint')) {
    return BigInt.parse(codec.jsString(value).toDart);
  }
  if (value.typeofEquals('number') ||
      value.typeofEquals('boolean') ||
      value.typeofEquals('string')) {
    return value.dartify();
  }
  throw UnsupportedError(
    'JS table references support primitive externrefs only; '
    'object and function references cannot be decoded.',
  );
}

JSTable createHost<T extends Value<T, V>, V extends Object?>(
  wasm.TableDescriptor<T, V> descriptor,
  JSAny? value,
) {
  final tableDescriptor = _toHostTableDescriptor(descriptor);
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

JSTableDescriptor _toHostTableDescriptor<
  T extends Value<T, V>,
  V extends Object?
>(wasm.TableDescriptor<T, V> descriptor) {
  final object = JSObject()
    ..['element'] = (descriptor.element.alias ?? descriptor.element.name).toJS
    ..['initial'] = descriptor.initial.toJS;
  final maximum = descriptor.maximum;
  if (maximum != null) {
    object['maximum'] = maximum.toJS;
  }
  return JSTableDescriptor._(object);
}
