## 0.6.0-dev.1

Preview release. The floating-point fixes previously prepared
for an unpublished `0.5.3` candidate are included in this batch; no separate
`0.5.3` release is planned.

- Use one unambiguous internal import-name encoding for functions, memories,
  tables, globals and tags, including metadata, spec registrations and Component
  Core connections. Accept legal colliding names through existing public imports;
  internal callers must use the key factory, with no legacy concatenation fallback.
- Add optional `Module(..., features: {CoreFeature.multiMemory})` and immutable
  `Module.supportedFeatures` for the Dart VM's pure Dart multi-memory engine.
  Preserve empty/default compilation behavior; reject explicit options on the
  JavaScript adapter. Other interpreter feature gates remain unchanged.
- Accept existing typed numeric host global wrappers on the Dart VM, preserving
  live host/Wasm aliases and numeric re-exports while checking type and mutability.
  Keep standalone value-box behavior until first binding; reject unsupported
  reference/vector host kinds explicitly.
- Execute a pinned 16-file, 396-command official memory subset through the
  public API, with public sync/async-host import/export and negative regressions.
  Include `data0`/`data1` through public immutable global imports and report
  unexpected link failures and dependent commands not run separately.

- Accept immutable `f32`/`f64` `global.get` seeds in supported GC array element
  expressions. Evaluate these expressions per instance after its globals are
  initialized, preserving raw float bits and nested aliases while rejecting
  mutable globals, incompatible seeds and incompatible element result types.
- Give each instance its own active/passive GC element array literals, including
  nested arrays, while preserving internal aliases and instance global identity.

- Accept `f64.const` in supported active/passive GC array element expressions
  using exact low/high bit decoding, with synchronous and forced async
  regressions for NaN payloads/signs and adjacent global/data/storage controls.
- Preserve raw `f32` constants during ordinary global and GC global/element
  initialization, including signaling NaN payloads and signs. Accept `f32.const`
  in supported active/passive GC array element expressions without converting
  through a Dart floating-point value.
- Preserve raw `f32` bits when GC arrays read data segments and store values in
  the synchronous and forced async pure Dart interpreters. Signaling NaNs no
  longer acquire a quiet bit during `array.new_data`, `array.init_data`,
  `array.copy` or `array.set` without floating-point arithmetic.
- Add exact-bit regressions for NaN payloads/signs, negative zero, subnormals,
  finite values, infinities and unaligned offsets, plus f64 and bounds controls.

## 0.5.2

- Initialize GC `v128` struct and array defaults with the interned all-zero
  vector in synchronous, forced async, global and element initialization paths.
- Cover default constructors, active/passive element segments, untouched array
  elements after writes and valid SIMD operands with twenty regressions.
- Run the new GC default regressions in both supported Dart SDK CI jobs.

## 0.5.1

- Initialize GC arrays with `v128` elements from data segments in both the
  synchronous and forced async Dart interpreters, including unaligned offsets.
- Make the native TCP listener resume regression deterministic across OS listen
  queues while retaining detection of a missing `resume()` transition.
- Preserve async tail-call exception semantics and document intentional direct
  Future returns; restore strict analyzer checks instead of ignoring warnings
  for the entire package.
- Add pinned Core conformance CI on Dart 3.11.0 and 3.13.4, native regression
  gates on Linux and macOS, and a fixed standards coverage/1.0 acceptance plan.
- Reject empty Core testsuite selections instead of reporting conformance success.
- Recheck native Preview1 clock subscriptions after early host wakeups; make
  HTTP timeout and UDP reservation regressions independent of setup timing and
  platform address reuse defaults.

## 0.5.0

- Execute stable WASI 0.3.0 `wasi:cli/command` and `wasi:http/service`
  components on the native Dart VM backend.
- Bind the frozen six-package, eight-world WASI 0.3.0 contract across `random`,
  `clocks`, `filesystem`, `sockets`, `cli`, and `http`; keep
  `wasi:clocks/timezone` explicitly outside the release contract.
- Complete the async Canonical ABI paths required by those worlds, including
  task/subtask scheduling, waitables, futures, streams, cancellation,
  backpressure, resource ownership, and scoped component types.
- Add native Preview3 filesystem, socket, outgoing HTTP, command, and HTTP
  service execution while keeping Node.js and browser runner support
  unclaimed.
- Keep explicit native TCP bind unsupported rather than exposing Dart's
  already-listening `ServerSocket.bind` as a false WASI bound state; unbound
  TCP listen and connect remain available.
- Reject static absolute-path, parent-traversal, and symlink escapes from
  native Preview3 preopens; document that path-based Dart filesystem APIs do
  not prevent races with an external actor replacing path nodes concurrently.
- Record the frozen Component Model async gates separately: WASD strict decode
  `37/37`, `wasm-tools` validation `31/31`, and Wasmtime reference execution
  `31/31`. The latter two are upstream validation/reference evidence, not WASD
  WAST execution.
- Pass `39/45` frozen official `wasm32-wasip3` wasi-testsuite fixtures. The six
  native TCP bind-dependent fixtures (`sockets-tcp-bind`,
  `sockets-tcp-listen`, `sockets-echo`, `sockets-tcp-connect`,
  `sockets-tcp-receive`, and `sockets-tcp-send`) fail with the documented
  `not-supported` capability boundary; there are no skips, expected failures,
  or unexpected passes.
- Pin the official WASI, Component Model, wasi-testsuite source, and precompiled
  fixture revisions used by the Preview3 release gate.

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
