# Wasm and WASI Roadmap

This repository is moving from limited Wasm plus WASI Preview 1 support toward
real, verified Wasm and WASI support across Preview 1, WASI 0.2, and WASI 0.3.
This document is the working architecture guide for that transition.

Status date: 2026-06-21.

## External Reference Points

- WASI.dev describes WASI as standards-track APIs for Wasm and explicitly maps
  the three milestone releases to Preview 1, Preview 2, and Preview 3. WASI 0.3
  adds Component Model native `async`, `future<T>`, and `stream<T>`.
  References: https://wasi.dev/ and https://wasi.dev/releases/wasi-p3
- WASI.dev states that WASI 0.3.0 was released on 2026-06-11. Its current
  runtime notes say Wasmtime 45 runs the latest release candidate, Wasmtime 46
  will ship WASI 0.3.0 with Component Model Async enabled by default, and jco
  supports JavaScript environments. The shared `wasi-testsuite` is the
  conformance reference for Wasmtime and jco across Linux, macOS, and Windows.
  Reference: https://wasi.dev/releases/wasi-p3
- Wasmtime exposes WASI through per-store `WasiCtx`, `WasiCtxView`, and
  `ResourceTable`, with interface groups for `cli`, `clocks`, `filesystem`,
  `random`, and `sockets`. That split is a useful boundary for wasd's future
  P2/P3 host model.
  Reference: https://docs.rs/wasmtime-wasi/latest/wasmtime_wasi/
- wasmCloud keeps P3 behind a `wasip3` Cargo feature, registers P3
  implementations alongside P2, and keeps P2 as the stable default.
  Reference: https://wasmcloud.com/docs/runtime/
- jco includes a dedicated `preview3-shim` package for mapping WASI Preview 3 to
  Node.js while reusing the broader component tooling pipeline for building,
  transpiling, and running WebAssembly components.
  Reference: https://github.com/bytecodealliance/jco

## Implementation Baselines

wasd should learn from these projects at the architecture-boundary level, not by
copying their internals directly.

- Wasmtime proves the first stable boundary should be the component runtime:
  generated bindings, interface-group modules, per-store context, and a resource
  table. For wasd, this means P3 work must start with component validation,
  canonical ABI semantics, resource ownership, and async lifecycle primitives
  before broad host APIs are advertised.
- wasmCloud proves P3 can coexist with P2 when the host registration layer is
  versioned. For wasd, Preview 1, WASI 0.2, and WASI 0.3 adapters should be
  separate modules over shared low-level host primitives.
- jco proves JavaScript support needs an explicit shim boundary instead of
  leaking Node or browser behavior into the core model. For wasd, JS runtime
  support should route through small Preview-specific bridges while preserving
  the same component and WASI semantics as the Dart VM runtime.
- WASI.dev's 0.3 release makes stream/future performance part of the API
  design, not a later optimization. For wasd, stream/future forwarding,
  cancellation, and buffering must get benchmarks and resource-lifetime tests as
  they are implemented.

## Current wasd Baseline

This is the implementation state as of 2026-06-21 on `main`.

- Preview 1 is real but still incomplete. Native and browser hosts share
  `lib/src/wasi/preview1/common/vfs.dart` for virtual files, directories,
  readdir state, hard links, symlinks/readlink, configured stream/datagram
  sockets, descriptor flags, descriptor rights, descriptor times, descriptor
  sync/advice validation, clock/file/socket polling readiness, and descriptor
  renumbering. Node still delegates Preview 1 behavior to `node:wasi`.
- Preview 1 `proc_raise` is no longer a blanket `ENOSYS` stub: native hosts
  deliver mapped process signals by default, native/browser hosts can inject a
  `procRaiseHandler` for controlled signal handling, and browser hosts still
  return `ENOSYS` when no handler exists.
- Preview 1 stdio descriptors, virtual files, configured stream/datagram
  sockets, open directories, and preopens now live in one VFS
  descriptor/capability table with base rights, inheriting rights, descriptor
  flags, renumbering, and close state. Preview1 does not define socket creation
  syscalls, so native/browser socket support is host-provided descriptor
  injection through
  `WASIPreview1Socket`, not raw networking.
- Preview 1 directory entries are indexed through per-directory child maps so
  common path/link/symlink mutation paths rebuild only affected directories.
  The benchmark entrypoint is `dart run tool/wasi_vfs_benchmark.dart --json`;
  it also covers socket multi-iov peek/waitall, datagram truncation, socket
  send/recv, socket polling readiness, and socket renumber/close descriptor
  paths.
- Component decoding and validation exist under
  `lib/src/wasm/backend/native/interpreter/component.dart`, and
  `lib/src/wasi/component/` now provides an internal typed resource table plus
  a resource host that binds decoded canonical `resource.new`, `resource.rep`,
  and `resource.drop` definitions, in canonical definition order, to
  table-local nominal resource type tokens. Component validation now
  materializes `componentType` imports for abstract resources into the same
  component type index space used by canonical resource definitions; component
  type validation also treats type-declaration `componentType` imports as local
  type introductions, so WIT-shaped worlds can reference imported resources in
  later local value/function types. Component-type aliases of known inline and
  instantiated component instance exports are also materialized, including
  resource aliases used by canonical resource definitions. Function and value
  aliases of instantiated component exports now preserve the child export's
  function/value type metadata, so parent components can validate aliased start
  signatures and argument value types. The resource host can bind those imported
  or aliased abstract resources with an unconstrained host representation.
  Resource host bindings also read decoded resource representation types and
  validate `resource.new` representation values, and resource-only canonical
  programs can be invoked by canonical index. `lib/src/wasi/component/` also
  contains internal `stream<T>` and `future<T>` runtime primitives with separate
  readable/writable endpoints, cancellation, drop callbacks, and benchmark
  coverage, plus an internal async host that binds decoded canonical `stream.*`
  and `future.*` definitions to executable endpoint operations. P2/P3 host
  instantiation, WIT ingestion, full canonical ABI lowering/lifting, and async
  stream/future execution are not production-supported yet.
- The public `WASIVersion` enum names Preview1, Preview2, and Preview3, but the
  `WASI(...)` factory now accepts only Preview1 and throws `UnsupportedError`
  for component-model WASI versions. This is an intentional version boundary,
  not a support claim.

## Architecture Direction

1. Keep the Wasm core runtime, component decoder, and WASI host layers separate.
   Component decoding may be permissive, but semantic validation must be
   explicit and diagnosable.
2. Treat WASI Preview 1, WASI 0.2, and WASI 0.3 as versioned host surfaces, not
   as one mixed namespace. Shared host primitives should sit below the versioned
   adapters.
3. Model component resources with a resource table abstraction before claiming
   production P2/P3 support. P3 streams and futures require stable ownership,
   borrowing, drop, and async lifecycle behavior.
4. Keep runtime support claims tied to real verification. README and public API
   docs must distinguish implemented, experimental, and planned surfaces.
5. Prefer generated or spec-derived interface bindings once WIT coverage starts.
   Hand-written host shims should stay narrow and tested.

## Next Implementation Order

1. Extend Preview1 socket coverage only where the current descriptor-backed
   model still has real gaps: native adapter boundaries, externally backed
   readiness, and larger conformance-shaped descriptor distributions before
   adding raw networking APIs.
2. For P2/P3, replace the current explicit constructor rejection with real
   versioned adapters over shared descriptor, resource, clock, random,
   filesystem, and socket primitives. Do not extend `wasi_snapshot_preview1`
   types into component worlds.
3. Expand the resource host into a component host adapter for imports, exports,
   representation-aware canonical lift/lower ownership, and async lifecycle
   state before adding WIT ingestion and generated binding support.

## Performance Direction

- Validation must be linear in the decoded component graph wherever possible.
  Recursive graph checks must use memoization and visiting sets.
- Component type index spaces should be materialized once per decoded
  component and reused by host binding code; canonical resource invocation must
  stay on prebound table/type tokens instead of rescanning import/export
  descriptors.
- Component decode and validation changes should be measured with
  `dart run tool/component_benchmark.dart --json`. The synthetic benchmark
  exercises repeated `stream<T>` definitions over a shared borrow-containing
  type graph, which is the current stress case for component validation.
- Test runners must report elapsed time and peak memory for heavy paths, at
  minimum the spec runner and DOOM runtime tests.
- Heavy external-process tests should be grouped behind explicit runner modes so
  default validation remains useful without hiding performance regressions.
- Any new conformance runner should cache toolchain discovery, generated
  bundles, and fixture conversion results by input hash.
- Preview 1 VFS path resolution, directory-entry rebuilding, descriptor rights,
  and socket descriptor paths are measured by
  `dart run tool/wasi_vfs_benchmark.dart --json`, covering `path_open`,
  `fd_readdir`, link/symlink mutation, rights checks, socket multi-iov
  `RECV_PEEK`/`RECV_WAITALL`, datagram truncation, socket send/recv, and socket
  poll readiness and renumber/close over large directory and descriptor sets.
  Keep optimizing against benchmark data instead of test suite heat alone.
- P2/P3 streams and futures need latency, allocation, and cancellation
  benchmarks before they are advertised as production-ready. The "sandwich"
  async forwarding case from WASI 0.3 must be a first-class benchmark, not only
  a functional test.
- Internal component stream/future endpoint round-trip, cancellation,
  completion/drop, and decoded canonical async program invocation costs are
  measured by
  `dart run tool/wasi_component_async_benchmark.dart --json`.
- Component resource table canonical `resource.new`/`resource.rep`/
  `resource.drop`, decoded resource-only canonical program invocation, nominal
  typed lookup, borrow, and drop behavior are measured by
  `dart run tool/wasi_resource_table_benchmark.dart --json`.

## Near-Term Slices

1. Extend Preview 1 socket coverage toward conformance edge cases that are not
   covered yet: native adapter boundaries and externally backed readiness.
2. Extend the VFS/descriptor benchmark with descriptor renumbering and larger
   conformance-shaped path distributions, then use it as the gate for further
   VFS optimizations.
3. Audit `tool/spec_runner.dart` and DOOM tests for process-spawn and fixture
   conversion hot spots, then add timing and caching where it changes actual
   runtime cost.
4. Keep closing component-model validation gaps that are local and
   deterministic, then wire validated borrow, stream, and future shapes into
   runtime host state.
5. Wire canonical `stream.*` and `future.*` memory lowering/lifting and async
   scheduling around the internal async host before adding public P3 API claims.
6. Introduce explicit WASI version modules for future P2/P3 work instead of
   extending Preview 1 host types in place.
7. Add WIT/interface ingestion only after the versioned host boundary and
   resource table are wired into canonical ABI ownership behavior.

## Completion Bar

The project should not claim full WASI 0.3 support until it can run real P3
components through a versioned host layer with resource, stream, future, and
async behavior covered by tests and measured performance gates.
