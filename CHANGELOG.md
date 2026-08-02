## 0.4.0

- Execute stable WASI 0.2.12 `wasi:cli/command` and `wasi:http/proxy`
  components on the native Dart VM backend.
- Implement the synchronous Canonical ABI paths required by those verified
  WASI 0.2.12 worlds and fixtures, including lowering/lifting, indirect values,
  post-return, nested component index spaces, and nominal resource ownership.
- Add scoped resource cleanup and ownership enforcement across Preview2 CLI,
  filesystem, I/O, sockets, and HTTP hosts.
- Align stable host semantics for stream permits and terminal errors,
  symlink-safe filesystem paths and byte-accurate metadata, socket and DNS
  lifecycles, dependency-free IDNA ToASCII names, and wire-faithful HTTP
  redirects, content coding, body, and trailer completion.
- Verify command execution against a Wasmtime Preview2 fixture and proxy
  execution against components generated from the official WASI 0.2.12 WIT.
- Keep Dart `HttpClient` trailer limitations explicit: outgoing-handler
  requests and incoming responses that declare trailers report
  `HTTP-protocol-error`, while proxy response trailers remain available.

## 0.3.0

- Stabilize Preview1 command-module support with real host filesystem preopens
  across Dart VM and Node.js, including host-backed file, directory, symlink,
  and timestamp behavior.
- Record the current WebAssembly core and WASI Preview1 conformance gates in an
  executable TODO under `doc/`.
- Add Preview2 component host/import coverage for standard `wasi:io`,
  `wasi:cli`, `wasi:filesystem`, and `wasi:sockets` packages.
- Add Preview3 component host/filesystem/async-profile scaffolding without
  claiming full Preview3 runtime coverage.
- Keep unsupported Preview2 and Preview3 operations explicit through WASI error
  results instead of reporting fake success.

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
