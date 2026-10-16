# Public tags and exceptions

Version `0.6.0-dev.2` includes numeric public `Tag`/`Exception` bindings and the
native `CoreFeature.exceptionHandling` opt-in. Version `0.6.0-dev.1` does not
provide these additions.
The JavaScript adapter uses its platform engine and does not accept explicit
feature options. The native Dart VM requires the option below.

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

Create and inspect public exceptions using the same tag:

```dart
import 'package:wasd/wasm.dart' as wasm;

final tag = wasm.Tag(wasm.TagDescriptor(parameters: [wasm.ValueKind.i32]));
final error = wasm.Exception(tag, [42]);
assert(error.isTag(tag));
assert(error.getArg(tag, 0) == 42);
```

Native numeric payloads use `int` for `i32`, `BigInt` for `i64`, and `double`
for `f32`/`f64`. Payload length and value kinds must match the tag. Construction
copies and normalizes numeric values once; later changes to the input list do
not change the exception. `getArg` requires the matching tag and a valid index.

A host function can throw this public exception and a guest can catch it by tag.
An uncaught guest exception becomes a public `Exception` at the Dart boundary,
including when thrown during module start. Re-throwing it into another guest
preserves its tag, payload and wrapper identity. Inspecting floating-point
payloads does not discard their original Wasm NaN bits before re-throwing.
Weak caches preserve wrapper identity without keeping every exception alive.
Ordinary Dart host failures are not matched by guest exception tags.
`ExceptionOptions.traceStack` requests platform stack capture when available;
the native adapter does not capture an additional construction stack.

JavaScript exported tags obtain their signatures lazily from the original
module metadata. Byte and stream compilation snapshot the necessary sections;
the adapter does not depend on a platform `WebAssembly.Tag.type()` method.

The verified host targets are Dart VM and Dart2js on Node/Chrome. Dart2wasm host
exception interoperability remains unqualified. Throwing public exceptions
from JavaScript host callbacks requires the engine's `WebAssembly.JSTag` support.

General reference/vector native tags and whole-Core conformance remain separate
acceptance work under the [standards plan](standards.md).

```sh
dart test test/wasm_host_tags_test.dart test/wasm_exception_bridge_test.dart test/wasm_core_features_test.dart
dart test test/wasm_exception_test.dart
dart test -p node test/wasm_exception_test.dart test/wasm_core_features_test.dart
dart test -p chrome test/wasm_exception_test.dart test/wasm_core_features_test.dart
```
