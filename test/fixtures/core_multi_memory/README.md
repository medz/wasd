# Public multi-memory regression fixtures

These are local WAT fixtures, converted with the pinned `wasm-tools 1.254.0`.
They are separate from the unmodified upstream testsuite executed by
`tool/core_multi_memory_public_runner.dart`.

```sh
.toolchains/bin/wasm-tools parse test/fixtures/core_multi_memory/operations.wat \
  -o test/fixtures/core_multi_memory/operations.wasm
.toolchains/bin/wasm-tools validate test/fixtures/core_multi_memory/operations.wasm
```

Apply the conversion to each WAT file. `invalid_*` binaries must fail official
validation. All other binaries validate, including `active_bounds` (which traps
when instantiated) and the valid SIMD/GC/multiple-table combinations (which
WASD rejects because those additional gates remain disabled).

`test/support/core_multi_memory_fixtures.dart` embeds the same binaries as
base64 so the public option tests can load them on Node and Chrome without
`dart:io`. Regenerate those entries after changing a fixture and format the Dart
file. Release evidence records byte-identical rebuilds and validation results.
