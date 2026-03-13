## 0.2.0

- Restructure the package around explicit `package:wasd/wasm.dart` and `package:wasd/wasi.dart` entrypoints, with `package:wasd/wasd.dart` re-exporting both surfaces.
- Ship the pure Dart WebAssembly runtime split into JS and native backends with regression-tested `compile`, `instantiate`, `validate`, typed exports, memory/table/global/tag wrappers, and host import support.
- Replace the old WASI API with a single `WASI` Preview1 surface aligned with the current 0.2 package design, covering command-style execution plus virtual filesystem basics on native and browser runtimes.
- Refresh examples and docs around the new 0.2 API, including the Flutter DOOM demo under `example/doom`.

## 0.1.0

- Promote the package to the first minor release with a stable public entrypoint at `package:wasd/wasd.dart`.
- Expand runtime coverage with regression-tested module execution, host imports, and validator behavior.
- Ship WASI Preview1 support with `WasiPreview1` and `WasiRunner` execution paths.
- Add component-model decoding/instantiation and canonical ABI invocation helpers.
- Improve tooling and examples, including conformance runners and the Flutter `example/doom` demo.

## 0.0.1

- Rename project to WASD (Wasm And Dart System / WebAssembly System for Dart).
- Publish initial open-source package structure on pub.dev.
- Add `lib/wasd.dart` as the primary package entrypoint.
- Update examples, tests, and demo app imports to `package:wasd/wasd.dart`.
- Keep `lib/pure_wasm_runtime.dart` as a compatibility alias.
