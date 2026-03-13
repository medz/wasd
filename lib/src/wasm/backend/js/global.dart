@JS()
library;

import 'dart:js_interop';

import '../../global.dart' as wasm;
import '../../value.dart';
import 'value_codec.dart' as codec;

class Global<T extends Value<T, V>, V extends Object?>
    implements wasm.Global<T, V> {
  Global(this.descriptor, V value)
    : host = JSGlobal(
        JSGlobalDescriptor(
          value: descriptor.value.name.toJS,
          mutable: descriptor.mutable,
        ),
        codec.encodeRef(descriptor.value, value),
      );

  final JSGlobal host;
  final wasm.GlobalDescriptor<T, V> descriptor;

  @override
  V get value => codec.decodeRef(descriptor.value, host.value);

  @override
  set value(V value) {
    host.value = codec.encodeRef(descriptor.value, value);
  }
}

extension type JSGlobalDescriptor._(JSObject _) implements JSObject {
  external factory JSGlobalDescriptor({required JSString value, bool mutable});
}

@JS('WebAssembly.Global')
extension type JSGlobal._(JSObject _) implements JSObject {
  external factory JSGlobal(JSGlobalDescriptor descriptor, [JSAny? value]);

  external JSAny? get value;
  external set value(JSAny? value);
}
