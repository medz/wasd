# WASI Preview2 fixtures

## `wasmtime_v47_0_3_hello.component.wasm`

This is a fixed, offline conformance fixture for a real
`wasi:cli/command` component. It writes `Hello, world!\n` to stdout and exits
with status 0.

- Upstream release: Wasmtime `v47.0.3`
- Upstream commit: `5554cc1a651da536af2cc46c7324bdc085b162e3`
- Source:
  [`hello_wasi_snapshot1.wat`](https://raw.githubusercontent.com/bytecodealliance/wasmtime/5554cc1a651da536af2cc46c7324bdc085b162e3/tests/all/cli_tests/hello_wasi_snapshot1.wat)
  - Size: 728 bytes
  - SHA-256:
    `86a3163046a33dec0b8f0625242d07e8edb7cfee40411f86106dfad4b9c22fc6`
- Preview1 command adapter:
  [`wasi_snapshot_preview1.command.wasm`](https://github.com/bytecodealliance/wasmtime/releases/download/v47.0.3/wasi_snapshot_preview1.command.wasm)
  - Size: 52,870 bytes
  - SHA-256:
    `9b1c0683da07acc749a148335c98ac5cbd9155876013dc20d73679f86a421bcd`
- Generator: `wasm-tools 1.252.0 (d66d4364c 2026-06-12)`
- Generated core module:
  - Size: 254 bytes
  - SHA-256:
    `9bf371b7e1f46d4c3e07bffb065d6523d71b296d69f2d50aa05b783fc73189ac`
- Generated component:
  - Size: 18,717 bytes
  - SHA-256:
    `9bc764eae49b55c963bbce08b5d9caebe176d7e32fdee097a85930495396a329`

Generate from the verified source and adapter files at the repository root:

```sh
.toolchains/bin/wasm-tools parse \
  hello_wasi_snapshot1.wat \
  -o hello_wasi_snapshot1.wasm

.toolchains/bin/wasm-tools component new \
  hello_wasi_snapshot1.wasm \
  --adapt wasi_snapshot_preview1=wasi_snapshot_preview1.command.wasm \
  -o wasmtime_v47_0_3_hello.component.wasm
```

Wasmtime distributes the source and adapter under
[Apache-2.0 WITH LLVM-exception](../../../third_party/component-model-tests/test/wasmtime/LICENSE-Apache-2.0_WITH_LLVM-exception).
