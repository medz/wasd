import '../../tag.dart' as wasm;
import '../../value.dart';

class Tag implements wasm.Tag {
  Tag(this.descriptor);

  @override
  wasm.TagDescriptor type() =>
      wasm.TagDescriptor(parameters: List<ValueKind>.of(descriptor.parameters));

  final wasm.TagDescriptor descriptor;
}
