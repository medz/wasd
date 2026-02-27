# WASD

WASD (Wasm And Dart System / WebAssembly System for Dart) is a pure Dart
WebAssembly runtime that runs across Dart VM, dart2js, and dart2wasm targets.

## Current coverage

- Core Wasm decoding and execution
- Proposal execution used by the repository conformance gates
- Component model decode/instantiate subset with official gate integration
- WASI Snapshot Preview1 API set (`wasi_snapshot_preview1`)
- Cross-target conformance runners under `tool/`

## Examples

Example index:

- [example/README.md](example/README.md)

Run:

```bash
dart run example/hello.dart
dart run example/sum.dart
dart run example/sum.dart 3 9
```

## Conformance tooling

The repository includes conformance runners and pinned toolchain bootstrap.
Official testsuites are tracked as git submodules under `third_party/`.

```bash
git submodule update --init --recursive third_party/wasm-spec-tests third_party/component-model-tests
tool/ensure_toolchains.sh
dart run tool/spec_runner.dart --target=vm --suite=all
dart run tool/spec_runner.dart --target=js --suite=all
dart run tool/spec_runner.dart --target=wasm --suite=all
```

Strict gate example:

```bash
dart run tool/spec_runner.dart --target=all --suite=all --strict-proposals --strict-component-subset --strict-component-official --strict-component-decode-probe
```

Artifacts are written to `.dart_tool/spec_runner/` including:

- `wasm_conformance_matrix.md`
- `latest.json`

## Why WASD

No FFI, no native runtime dependencies, and one interpreter model across Dart
compile targets.
