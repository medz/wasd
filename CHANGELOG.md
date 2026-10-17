## 0.6.1

- Keep canonical resource, stream/future, task, waitable-set and error-context
  handles local to each Component instance. Preserve resource type identity,
  own/borrow lifetimes and invocation-local thread context across supported
  aliases and asynchronous calls. Validate complete argument/result conversions
  before consuming owned handles, preserving earlier owners on failure.
- Transfer owned async values only for accepted prefixes; preserve pending
  cursors, cumulative progress and once-only cleanup on cancellation, failed
  stores or destructor traps. Reclaim temporary error-context references.
- Run concrete local resource destructors with their instantiated Core state,
  preserve destructor failures, and reject invalid destructor signatures.
- Support typed Future host callbacks on JavaScript engines with JSPI; preserve
  original host errors and stacks on VM, Node and browser paths. Reject erased
  Future results without replaying guest execution. Core start callbacks remain
  synchronous.
- Improve the Component specification runner's void assertions, anonymous
  definitions and phase-specific negative assertions. Keep unsupported commands
  and dependent actions that were not executed separate from runtime failures.
- Report blocking synchronous stream copies after `task.return` before
  retaining a pending buffer. Immediate copies remain executable; complete
  caller-continuation scheduling is still tracked in #156.
- Retain the frozen Core 261-file/65,336-command, Component 3-file/59-command,
  native Preview1 72-case and native Preview3 0.3.0 45-case gates.

Full standards acceptance and broader platform coverage remain tracked in
`doc/standards.md`.

## 0.6.0

Regular release, including all changes from `0.6.0-dev.1` through
`0.6.0-dev.3`.

- Include public Dart VM Core feature options, numeric host globals and
  tags/exceptions, floating-point/GC fixes, synchronous Component map adapters,
  named WIT bindings and WASI `0.3.1` contract/linking support alongside `0.3.0`.
- Extend actual WASD Component execution to the complete frozen realloc file:
  three value files and `59/59` commands. Check realloc alignment before bounds,
  including empty lists, and distinguish ABI faults from ordinary host errors.
- Retain the frozen Core `65,336`-command gate, 72-case native Preview1 gate
  and 45-case native Preview3 `0.3.0` gate. Shared canonical-memory regressions
  also run on Node and Chrome.

Selected-file and host gates retain the boundaries in `doc/standards.md`;
this release does not claim full Core, Component Model or WASI conformance.

## 0.6.0-dev.3

Preview.

- Add Component maps with synchronous Canonical ABI/WIT adapters. Ordered tuple
  pairs preserve duplicate keys; memory views refresh after realloc growth.
- Support modern Component name attributes and named WIT interfaces, preserving
  external-ID metadata, distinct callbacks and local resource identities.
- Execute complete frozen Component strings and numerics files through WASD:
  `43/43` commands, with 17 initializations, one definition registration,
  18 exact returns and seven invocation traps. Reuse the runtime for nested
  Core execution and lexical outer type scopes. Keep nested Component starts
  and concrete local resource aliases explicitly unsupported.
- Ignore undefined upper flags bits during flat Canonical ABI lifting, retaining
  declared labels and existing integer, host-label and enum-index checks.
- Add exact WASI `0.3.1` contracts and linking alongside `0.3.0`, covering six
  packages and eight worlds. Custom command/service guests exercise real host
  calls and resource cleanup; the official `45/45` native suite remains a
  separate `0.3.0` compatibility gate.
- Freeze and enforce the complete 72-case official Preview1 native inventory,
  verifying 137 fixture inputs and 15 runner source files. Reject missing,
  duplicate, skipped and unexecuted cases. Native CI reuses one compiled Dart
  runner across fixture processes; default JIT and Node/browser regressions
  remain separate profiles.
- Read actual Preview1 host process/thread CPU clocks on supported Linux/macOS
  and Node capabilities, preserving 64-bit nanosecond encoding. Missing APIs
  fail without modifying output. CPU timer subscriptions report `INVAL` events;
  guest-specific CPU accounting remains outside this slice.

These selected-file and host gates do not establish full Core, Component Model
or WASI conformance. The frozen targets and remaining acceptance work are in
`doc/standards.md`.

## 0.6.0-dev.2

Preview.

- Decode custom-section names as UTF-8, including non-ASCII names.
- Add public numeric `Tag` and `Exception` APIs with host/guest propagation,
  tag identity, cross-instance rethrows and preserved floating-point payloads.
  Native modules require `CoreFeature.exceptionHandling`; Dart2js on Node and
  Chrome uses the platform engine.
- Restore all `261` original frozen Core 3.0 source paths and reject multiple
  supertypes during validation. Record `65,336/65,336` commands with zero
  failures or skips; empty conversions and skipped commands fail the gate.
  Binary assertions use WASD's internal interpreter, while malformed text
  assertions use external parsers. Public API coverage remains separate.
- Close a Preview2 TCP socket after a terminal `finish-listen` failure;
  an unfinished operation still returns `would-block` and remains pending.
- Implement separate Preview3 TCP bind/listen on Linux and macOS using one
  native OS socket through bind, listen or connect. Preserve the explicit
  `not-supported` boundary for TCP bind on other platforms.
- Recheck Preview3 monotonic deadlines after host timer wakeups and round
  scheduled delays up to milliseconds, preserving zero waits and bounded
  chunks for long waits.
- Record `45/45` frozen official Preview3 fixtures with native AOT, zero
  failures, skips, expected failures or unexpected passes. Native CI compiles
  this repository's runner once for each Linux/macOS job and retains the
  30-second per-fixture timeout. The earlier `39/45` published baseline remains
  historical evidence below.
- Keep the historical Component Model gate separate: WASD strict decode
  `37/37`, `wasm-tools` `1.254.0` validation `31/31`, and Wasmtime
  `48.0.0 (e8ac8c27f)` reference execution `31/31`. Updating the Core converter
  to `wasm-tools` `1.262.0` does not replace that frozen draft validation.

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
