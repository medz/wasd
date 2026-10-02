# Numeric host-global fixtures

These local WAT sources are converted and validated with pinned wasm-tools
1.254.0. Every fixture is officially valid; the negative linking tests vary
the public host descriptors, rather than supplying invalid module bytes.

```sh
.toolchains/bin/wasm-tools parse test/fixtures/host_globals/alias.wat \
  -o test/fixtures/host_globals/alias.wasm
.toolchains/bin/wasm-tools validate test/fixtures/host_globals/alias.wasm
```

`test/support/host_global_fixtures.dart` embeds the same binaries as base64 for
Node/Chrome tests without dart:io. Regenerate its entries after editing a WAT
source. The evidence records byte-identical binary rebuilds.

The i64 fixtures also export both 32-bit halves and accept i32 setters, allowing
the JS tests to inspect the binding without changing the existing JS function
bigint ABI. Float export/import fixtures ensure a host getter and re-import do
not rewrite the underlying signaling NaN bits in the Dart VM.

The name-boundary fixtures use valid `::`-containing names. One verifies unused
colliding host pairs cannot satisfy an import. The other checks distinct declared
pairs retain independent bindings under the shared unambiguous import encoding.
