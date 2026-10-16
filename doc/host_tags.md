# Public exception tags

This native Dart VM addition is unreleased. Published `0.6.0-dev.1` does not
provide it. The JavaScript adapter continues to use its platform engine and
does not accept explicit feature options.

Enable exception handling when compiling a module that imports or defines tags:

```dart
import 'package:wasd/wasm.dart';

final error = Tag(TagDescriptor(parameters: [ValueKind.i32]));
final module = Module(bytes.buffer, features: {CoreFeature.exceptionHandling});
final instance = Instance(module, {
  'host': {'error': ImportExportKind.tag(error)},
});
final exported = (instance.exports['error'] as TagImportExportValue).ref;
final parameters = exported.type().parameters;
```

The module must declare the matching `host.error` import and `error` export.
Empty payloads and ordered `i32`, `i64`, `f32`, and `f64` payloads are supported.
Bindings use simple final function types; non-final types, supertypes and
multi-type recursive groups remain unsupported and fail before guest start.
Missing providers, wrong import kinds and different payload types fail linking.
Reference and vector host signatures remain unsupported; numeric tags cannot
satisfy reference signatures merely because they share an internal carrier.

Each new tag has its own identity. Passing one tag under several import names
shares that identity; two tags with identical signatures remain distinct.
Guest-defined tags preserve their identity when exported and imported by another
instance. Wasm catches match identity, rather than the payload signature.
The constructor copies the descriptor parameters, and `type()` returns a fresh
list, so changing either caller-owned list cannot change an existing tag.

Synchronous and asynchronous instances propagate the same guest exception
through imported exported functions. Async-only exports retain their async
calling convention when re-imported, so an importing instance selects the async
pipeline without replaying a synchronous attempt. Exception references captured
by `catch_ref` also remain valid across instances and interpreter modes.

The option does not enable unrelated interpreter extensions. Tag-only modules
also require this option, even when they execute no exception instructions;
older native compilation accepted these declarations without usable public tag
bindings. Default scalar modules retain their existing behavior.
Throwing or inspecting guest exceptions
through the existing public host `Exception` API remains unsupported.
General reference/vector tags, JavaScript tag
reflection and whole-Core conformance remain separate acceptance work under the
[standards plan](standards.md).

```sh
dart test test/wasm_host_tags_test.dart test/wasm_exception_bridge_test.dart test/wasm_core_features_test.dart
dart test -p node test/wasm_core_features_test.dart
dart test -p chrome test/wasm_core_features_test.dart
```
