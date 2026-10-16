@JS()
library;

import 'dart:js_interop';

import '../../tag.dart' as wasm;
import '../../value.dart';

class Tag implements wasm.Tag {
  Tag(wasm.TagDescriptor descriptor)
    : _parameters = _copyParameters(descriptor.parameters),
      _loadType = null,
      host = JSTag(
        JSTagType(
          parameters: descriptor.parameters
              .map((kind) => (kind.alias ?? kind.name).toJS)
              .toList(growable: false)
              .toJS,
        ),
      );

  Tag.fromHost(this.host, this._loadType);

  final JSTag host;
  final wasm.TagDescriptor Function()? _loadType;
  List<ValueKind>? _parameters;

  @override
  wasm.TagDescriptor type() => wasm.TagDescriptor(
    parameters: _copyParameters(
      _parameters ??= _copyParameters(_loadType!().parameters),
    ),
  );
}

// Avoid the SDK's Function type substitution bug in Iterable copy assertions.
List<ValueKind> _copyParameters(List<ValueKind> parameters) =>
    List<ValueKind>.generate(parameters.length, (index) => parameters[index]);

extension type JSTagType._(JSObject _) implements JSObject {
  external factory JSTagType({required JSArray<JSString> parameters});

  external JSArray<JSString> get parameters;
}

@JS('WebAssembly.Tag')
extension type JSTag._(JSObject _) implements JSObject {
  external factory JSTag(JSTagType descriptor);
}
