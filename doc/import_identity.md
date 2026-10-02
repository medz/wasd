# Core import identity

The `0.6.0-dev.1` preview fixes ambiguous native import keys.
`("a", "b::c")` and `("a::b", "c")` used to become the same `a::b::c` key,
allowing the wrong function, memory, table, global or tag to satisfy an import.
The VM now supports both valid name pairs through the existing public API.

One internal encoder prefixes both original strings with their lengths:
`1:a4:b::c` and `4:a::b1:c`. Lengths count Dart UTF-16 code units; this map
representation does not change the binary format's UTF-8 encoding. Empty names,
Unicode and colons remain unchanged. Each decimal length and following colon
locates one complete string, so separators within names are unambiguous.

`WasmImports.key` and decoded `WasmImport.key` call the same encoder. All ten
internal maps keep their `String` key types: synchronous/asynchronous functions,
function types/depths, memories, tables, global values/types/bindings and tags.
The spec runner/player's registered-instance bindings and the existing Component
Core connector already use `WasmImports.key`, so they follow the same identity.
The native adapter still selects globals using the original module/name pair
and checks type/mutability through the existing linker. Intentional sharing of
the same host binding remains supported.

No formal public type or nested imports-map format changes. These interpreter
classes are not exported from `wasm.dart` or `wasd.dart`. Code directly importing
`lib/src` must use `WasmImports.key` instead of manually concatenating names;
there is no legacy-key lookup or ambiguous fallback. Internal error messages
that include keys now show the length-prefixed identity.

Regressions execute all five import kinds, exact and asynchronous functions,
metadata association, missing/type/mutability errors, deliberate global aliases,
empty/Unicode/colon names and both public global collision cases. Officially
valid local fixtures separately exercise registered bindings in the VM spec
runner and the pure Dart interpreter compiled to JavaScript. The JavaScript
regression runs with the platform `WebAssembly` global disabled. Component checks
exercise all five kinds within its existing single-memory/table gates, including
colliding function/global/tag pairs; those gates are not expanded.

The local six-command script is regression evidence, not an additional official
conformance suite. The pinned official Core suite and fixed public multi-memory
subset are reported separately. No GC, parser or instruction-execution algorithm
is redesigned by this change.
