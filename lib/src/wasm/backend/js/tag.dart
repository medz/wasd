@JS()
library;

import 'dart:js_interop';

import '../../tag.dart' as wasm;
import '../../value.dart';

class Tag implements wasm.Tag {
  Tag(wasm.TagDescriptor descriptor)
    : host = JSTag(
        JSTagType(
          parameters: descriptor.parameters
              .map((kind) => (kind.alias ?? kind.name).toJS)
              .toList(growable: false)
              .toJS,
        ),
      );

  final JSTag host;

  @override
  wasm.TagDescriptor type() {
    final parameters = host
        .type()
        .parameters
        .toDart
        .map((name) {
          final dartName = name.toDart;
          return switch (dartName) {
            'i32' => ValueKind.i32 as ValueKind,
            'i64' => ValueKind.i64 as ValueKind,
            'f32' => ValueKind.f32 as ValueKind,
            'f64' => ValueKind.f64 as ValueKind,
            'v128' => ValueKind.v128 as ValueKind,
            'externref' => ValueKind.externref as ValueKind,
            'funcref' || 'anyfunc' => ValueKind.funcref as ValueKind,
            _ => throw UnsupportedError(
              'Unsupported tag parameter type: $dartName',
            ),
          };
        })
        .toList(growable: false);
    return wasm.TagDescriptor(parameters: parameters);
  }
}

extension type JSTagType._(JSObject _) implements JSObject {
  external factory JSTagType({required JSArray<JSString> parameters});

  external JSArray<JSString> get parameters;
}

@JS('WebAssembly.Tag')
extension type JSTag._(JSObject _) implements JSObject {
  external factory JSTag(JSTagType descriptor);

  external JSTagType type();
}
