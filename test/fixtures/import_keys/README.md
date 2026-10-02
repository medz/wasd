# Import-name regressions

All checked-in `.wat` binaries are parsed and validated with wasm-tools 1.254.0.
The three Core name sets use colons, empty names and Unicode (including an astral
character). They collide under the old `module::name` concatenation. Function and
exact-function pairs have distinct result types to check metadata association;
memories/tables have distinct sizes; global storage and tag identity are distinct.

```sh
.toolchains/bin/wasm-tools parse test/fixtures/import_keys/global_colon.wat \
  -o test/fixtures/import_keys/global_colon.wasm
.toolchains/bin/wasm-tools validate test/fixtures/import_keys/global_colon.wasm
```

`registry.wast` has six commands and supplies all five kinds via registered
instances. The native spec runner and compiled-JS pure Dart spec player execute
the assertions; wasm-tools only converts the source. This is a local regression
script, not part of the pinned upstream conformance count.

The two Component fixtures instantiate Core modules with all five import kinds.
Function/global/tag pairs collide under the old key. Each consumer has one memory
and table, selecting respectively the first or second namespace, so they stay
within the Component connector's existing gates. Their `run` traps if any value
or tag identity is misbound. No native Wasm engine executes these tests.
