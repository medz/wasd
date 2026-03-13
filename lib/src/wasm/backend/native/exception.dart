import '../../exception.dart' as wasm;
import '../../tag.dart';

class Exception implements wasm.Exception {
  Exception(this.tag, List<Object?> payload, [wasm.ExceptionOptions? options])
    : payload = List<Object?>.unmodifiable(payload);

  final Tag tag;
  final List<Object?> payload;

  @override
  bool isTag(Tag candidate) => identical(tag, candidate);

  @override
  Object? getArg(Tag candidate, int index) {
    if (!isTag(candidate)) {
      throw ArgumentError.value(
        candidate,
        'tag',
        'Tag mismatch for this exception',
      );
    }
    return payload[index];
  }
}
