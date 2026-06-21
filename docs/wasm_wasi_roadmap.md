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
  P2/P3 host model. Its current `p3` module is still documented as
  experimental, unstable, and incomplete, so wasd should copy the layering
  discipline rather than overclaiming support.
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
- The Component Model Canonical ABI defines `stream.new` and `future.new` as
  core functions returning a single `i64`, with the readable endpoint in the low
  32 bits and the writable endpoint in the high 32 bits. wasd handle-program
  adapters should expose that packed ABI shape at the core boundary while
  keeping typed Dart endpoint objects inside host operations.
  Reference: https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md
- The Component Model Canonical ABI defines `thread.index` as the current-thread
  identity query and `thread.available-parallelism` as a fixed per-instance
  capacity value. wasd should implement those identity operations before
  scheduler-dependent thread switching, suspension, yielding, and spawning, and
  must not expose the latter as supported until a real scheduler owns their
  lifecycle semantics.
  Reference: https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md

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
  send/recv, socket polling readiness including zero-length datagram
  readiness and queued accepts, and socket renumber/close descriptor paths.
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
  It can also derive a component resource binding list from the materialized
  component type index space and define those resource types in one pass, so
  future P2/P3 adapters do not need to rescan imports, exports, or aliases by
  hand. Resource host bindings also read decoded resource representation types
  and validate `resource.new` representation values, and resource-only
  canonical programs can be invoked by canonical index. Resource table handles
  are monotonically allocated within the canonical u32 range while slots are
  reused behind an O(1) handle-to-slot map, so hot create/drop paths do not
  overflow resource handles after a small number of generations.
  `lib/src/wasi/component/` also contains internal `stream<T>` and `future<T>`
  runtime primitives with separate readable/writable endpoints, cancellation,
  drop callbacks, and benchmark coverage, plus an internal async host that binds
  decoded canonical `stream.*`
  and `future.*` definitions to executable endpoint operations and
  resource-table-backed integer endpoint handles. Host async bindings now read
  decoded direct or type-indexed stream/future element types, including
  primitive and fixed-size composite values, and validate Dart values against
  those component-level constraints before writing. Handle-backed async
  operations borrow endpoint resources while executing read/write/cancel paths,
  so reentrant drops cannot invalidate an endpoint during host-side canonical
  execution; pending handle-backed reads hold asynchronous resource-table
  borrows until completion. Internal streams
  and futures now expose pending read completion primitives and can represent
  Component Model `stream<>`/`future<>` unit payloads as `null`; decoded unit
  async types reject non-unit payloads instead of acting as unconstrained
  streams/futures. Streams also support optional bounded buffering for
  backpressure, and canonical async programs can await pending `stream.read`,
  `stream.write`, and `future.read` operations through `invokeAsync`. The async
  host can also copy fixed-size and primitive string `stream<T>`/`future<T>`
  values between guest memory and async endpoints for canonical
  `stream.read`/`stream.write` and `future.read`/`future.write` adapters.
  Handle-backed canonical programs expose an ABI-shaped memory invocation path:
  `stream.{read,write}` use `(handle, ptr, n)` and `future.{read,write}` use
  `(handle, ptr)`, string read paths accept a canonical `realloc` callback for
  lowering payloads, and completed operations return the canonical packed copy
  result. The same handle-backed memory invocation path also has an awaited
  form for pending stream reads, bounded stream writes, and future reads, still
  returning canonical packed copy results after completion. Handle-backed
  canonical `stream.new` and `future.new` invocation returns the Canonical ABI
  packed `i64` handle pair while operation-level helpers keep typed Dart handle
  pairs for internal use. The async host also binds decoded `backpressure.set`,
  `backpressure.inc`, and
  `backpressure.dec` canonical definitions to an internal bounded counter with
  overflow/underflow checks. Internal stream readable endpoints also expose a
  forwarding primitive that moves queued values directly into another writable
  endpoint and falls back to the shared async read/write wait paths for pending
  source values or bounded destination capacity, giving the WASI 0.3
  "sandwich" forwarding case one reusable execution path. Internal
  waitable-set support now models table-backed waitables and waitable sets,
  canonical event codes, `waitable-set.{poll,wait}` payload writes to memory,
  `waitable.join` transfer/removal with `0` as the removal sentinel, and drop
  guards for non-empty or actively waited sets. Cancellable
  `waitable-set.{poll,wait}` can now observe an internal pending task
  cancellation once and write the canonical `TASK_CANCELLED` event payload.
  Handle-backed stream/future
  endpoints are now lazily resolvable as waitables, so canonical
  `waitable.join(endpoint, set)` can target the same endpoint handle without
  adding waitable allocation cost to ordinary handle paths. Handle-backed
  fixed-size `stream.read`, bounded `stream.write`, `future.read`, and
  `future.write` memory copies also have a canonical event-start path:
  immediate copies return the packed copy payload, pending copies return
  `0xffffffff` (`BLOCKED`) and later publish the corresponding waitable event
  with the endpoint handle and packed copy result. Pending event-start copies
  mark the endpoint waitable as owning an active copy until the event is
  delivered, so duplicate starts and drops trap instead of racing the pending
  copy. Cancelling a pending handle-backed copy now follows the Canonical ABI
  cancel-copy shape for handle-backed stream read, bounded stream write, future
  read, and future write events: the first asynchronous cancellation returns
  `BLOCKED` when the event is not immediately ready, repeated cancellation
  traps while the copy is being cancelled, and the usual waitable event returns
  either the cancelled payload or a completed payload when a future read already
  resolved before cancellation was observed. Non-async handle-backed
  cancel-copy definitions can also be invoked through `invokeAsync`, where the
  host waits for the pending copy event and returns the canonical packed
  payload instead of reporting an unsupported synchronous wait.
  Stream copy events also distinguish dropped peers from cancellation: pending
  stream reads report `DROPPED` when the writable end is dropped, and pending
  bounded stream writes report `DROPPED` when the readable end is dropped,
  while explicit same-end copy cancellation still reports `CANCELLED`. Future
  write events also wait for the first read observation before reporting
  `COMPLETED`, report `DROPPED` when the readable end is dropped before that
  observation, and report `CANCELLED` when the writable end cancels the active
  copy. Future read/write memory copies now track canonical copy consumption
  separately from the host-side future value, so a handle-backed Future copy
  endpoint moves to a done state after a completed canonical copy and rejects
  duplicate read/write copy starts while still allowing the required endpoint
  drop.
  Internal subtask support now models table-backed caller-side subtasks,
  canonical subtask state codes, `subtask.cancel`, `subtask.drop`, async
  `BLOCKED` cancellation, waitable-set `SUBTASK` event delivery, and non-async
  cancellation through an `invokeAsync` path that waits past intermediate
  `STARTED` progress until the final subtask state is available. Internal
  callee-side task support now models `task.return`, `task.cancel`,
  async-local current-task execution context, active-borrow return/cancel
  guards, caller-side subtask result storage, and cancellation propagation from
  `subtask.cancel` into cancellable `waitable-set.wait` through the shared
  waitable host. Internal
  context support now models the current Canonical ABI `i32` thread-local
  `context.get`/`context.set` cells with scoped current-context execution and
  fixed slot validation. Internal thread support now models implicit/current
  thread identity, per-thread context switching, `thread.index`, and configured
  `thread.available-parallelism` without introducing a scheduler yet. Full async
  lowering, task spawning, thread suspension/resume event production, and
  WIT-generated world integration remain future work, but stream/future copy
  plus task/subtask/context/thread identity runtime pieces are no longer
  placeholders.
  An internal canonical host facade now shares the component resource table,
  waitable resolvers, current context, task, thread, resource, async,
  waitable-set, subtask, and error-context hosts behind one canonical-indexed
  binding layer. It validates decoded components before binding canonical
  definitions so future P2/P3 adapters fail with component validation
  diagnostics instead of runtime-only host errors. It also reports all
  unsupported canonical definitions before building any operation table, so
  versioned adapters can surface real capability gaps without partially bound
  programs. The same facade can also prepare a reusable binding plan that
  captures component validation errors, unsupported canonical definitions, and
  the canonical definition snapshot once before any operation table is built.
  An internal component host adapter now combines that canonical plan with the
  decoded component resource and async value binding lists, defines component
  resources plus supported unit, primitive, fixed-size composite, and primitive
  string `stream<T>`/`future<T>` values on the shared table only after
  validation and capability checks pass, and returns the canonical-indexed
  program from the same shared host state. Async value bindings now also expose
  fixed-size
  Canonical ABI memory-copy layout through an internal Canonical ABI
  value-memory codec covering primitive values, records/tuples, fixed lists,
  flags, variants, options, results, and enums that do not require realloc,
  handle-table, borrow, or nested async semantics. Future P3 adapters can route
  stream/future memory lowering through this shared codec without re-deriving
  byte widths, alignments, and padding separately from the executable copy path.
  Component-host tests now also exercise decoded core-memory primitive
  `stream<T>`/`future<T>` copy paths through synchronous Canonical ABI calls,
  pending read completion through waitable events, and fixed-size record
  `stream<T>`/`future<T>` round trips through decoded core-memory copy
  definitions. Component validation now follows the Canonical ABI stream/future
  copy option split: `stream.read`/`future.read` require `realloc` for dynamic
  list/string elements, `stream.write`/`future.write` do not, `memory` is still
  required when an element type is present, and `realloc` itself requires
  `memory`. Primitive `string` `stream.write`/`future.write` now read
  canonical `(ptr, len)` string records from guest memory through the same
  UTF-8, UTF-16, and Latin1+UTF-16 adapter used by error-context memory paths,
  and direct/handle-backed primitive `string` `stream.read`/`future.read`
  paths can lower host strings back into guest memory through a canonical
  `realloc` callback plus `(ptr, len)` result records. This makes both
  directions of primitive string async memory copy executable in the internal
  async host. The canonical-indexed component program now also passes an
  explicit `realloc` callback through memory-backed invocation paths, so
  decoded component-host primitive string `stream.read`/`stream.write` round
  trips can execute through the same `(handle, ptr, n)` core-memory call shape.
  The adapter still does not automatically invoke decoded core realloc exports;
  callers must provide the realloc callback at invocation time. List values and
  composites containing dynamic values remain unsupported for executable memory
  copy. This is an adapter boundary for future P2/P3 version modules, not a
  public support claim.
  Internal
  error-context support now models
  `error-context.new`, `error-context.debug-message`, and `error-context.drop`
  as table-backed handles with real stale-handle/drop validation. It also has
  a shared canonical string memory adapter covering UTF-8, UTF-16, and
  Latin1+UTF-16 for reading `error-context.new` messages from guest memory,
  writing `error-context.debug-message` payloads through a canonical-style
  `realloc` callback, and writing canonical `(ptr, len)` result records.
  Integration with real core realloc exports remains future canonical ABI
  adapter work.
  Heavy process-based verification now uses a shared measured-process helper:
  `tool/spec_runner.dart` records elapsed time and sampled peak RSS per step in
  its JSON/Markdown reports, and the DOOM smoke tests include the same metrics
  in failure diagnostics. The spec testsuite runner also caches `.wast`
  conversion outputs by converter/input hash under `.dart_tool/spec_runner`,
  then copies cached outputs into fresh execution directories so repeated
  conformance runs avoid redundant external converter work without reusing
  mutable execution state. Targeted spec execution can now run individual
  `.wast` files with `tool/spec_testsuite_runner.dart --file=<path>`, which is
  the preferred loop for hot files such as `memory_copy.wast`,
  `table_copy.wast`, and SIMD stress cases. Native table copying now delegates
  to Dart range-copy semantics instead of a manual element loop while preserving
  same-table overlapping copy behavior. Native memory bulk operations now avoid
  BigInt allocation for memory32 operands on the hot VM path and cache stable
  per-instruction memory/index-type metadata for repeated `memory.copy` and
  `memory.fill` execution. Native linear memory growth also returns immediately
  for `memory.grow(0)`, avoiding an unnecessary same-size buffer allocation and
  copy while preserving the required previous-page-count result.
  P2/P3 host instantiation, WIT ingestion, full canonical ABI
  lowering/lifting, memory-backed typed stream/future copy, and full async
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
- Test runners must report elapsed time and peak memory for heavy paths. The
  spec runner and DOOM smoke tests use the shared measured-process helper for
  elapsed time and sampled child-process peak RSS; future heavy runners should
  reuse the same helper instead of open-coding process timing.
- Heavy external-process tests should be grouped behind explicit runner modes so
  default validation remains useful without hiding performance regressions.
- Any new conformance runner should cache toolchain discovery, generated
  bundles, and fixture conversion results by input hash. The current
  spec-testsuite runner caches converter outputs but still executes each file
  from a fresh work directory to preserve isolation. It also records per-file
  elapsed time and emits a Top Slow Files table in Markdown reports so hot paths
  can be selected from data. Use `--file=<path>` for targeted hot-file
  verification before running broader conformance smoke checks.
- Preview 1 VFS path resolution, directory-entry rebuilding, descriptor rights,
  and socket descriptor paths are measured by
  `dart run tool/wasi_vfs_benchmark.dart --json`, covering `path_open`,
  `fd_readdir`, link/symlink mutation, rights checks, socket multi-iov
  `RECV_PEEK`/`RECV_WAITALL`, datagram truncation, socket send/recv, and socket
  poll readiness, plus file, directory, and socket descriptor renumber/close
  over large directory and descriptor sets. Keep optimizing against benchmark
  data instead of test suite heat alone.
- Component async host paths are measured by
  `dart run tool/wasi_component_async_benchmark.dart --json`, including
  canonical async stream/future copies, context get/set TLS operations,
  thread identity/context switching, waitable-set event delivery, task
  cancellation delivery, subtask cancellation delivery, task return/cancel
  delivery, and async current-task scope switching. Add new async lifecycle work
  to this benchmark before treating hot test behavior as an implementation
  detail.
- P2/P3 streams and futures need latency, allocation, and cancellation
  benchmarks before they are advertised as production-ready. The "sandwich"
  async forwarding case from WASI 0.3 must be a first-class benchmark, not only
  a functional test.
- Internal component stream/future endpoint round-trip, cancellation,
  completion/drop, pending stream/future-read completion, bounded stream-write
  backpressure completion, stream forwarding "sandwich" throughput,
  backpressure counter operations, waitable-set event delivery and memory
  payload writes, decoded canonical async program invocation, decoded unit
  stream/future program invocation, and resource-table-backed borrowed handle
  invocation costs, context get/set TLS operations, thread identity/context
  switching, waitable-set task-cancellation delivery, async current-task scope
  switching, synchronous, awaited, and waitable-event handle-program
  fixed-size memory-copy invocation costs, synchronous handle-program
  cancel-copy wait costs, subtask cancellation delivery, task return/cancel
  delivery, plus fixed-size primitive stream/future memory-copy costs, are
  measured by
  `dart run tool/wasi_component_async_benchmark.dart --json`. Keep active-copy
  state checks on the waitable-event path so ordinary handle and memory
  invocations do not pay for event lifecycle enforcement.
- Component resource table canonical `resource.new`/`resource.rep`/
  `resource.drop`, decoded resource-only canonical program invocation,
  component resource binding extraction from decoded type index spaces,
  component-host binding startup with resource, stream, decoded core-memory
  primitive stream-copy, decoded core-memory fixed-size record stream-copy, and
  decoded core-memory primitive future-copy round trips, mixed canonical-host
  program invocation over shared component state, error-context canonical
  lifecycle invocation, error-context canonical string memory adapter invocation
  with result records, nominal typed lookup, synchronous/asynchronous borrow,
  and drop behavior are measured by
  `dart run tool/wasi_resource_table_benchmark.dart --json`.

## Near-Term Slices

1. Extend Preview 1 socket coverage toward conformance edge cases that are not
   covered yet: native adapter boundaries and externally backed readiness.
2. Extend the VFS/descriptor benchmark with larger conformance-shaped path
   distributions, then use it as the gate for further VFS optimizations.
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
7. Extend async host value validation beyond primitive element aliases only
   when composite value lowering/lifting support is implemented.
8. Add WIT/interface ingestion only after the versioned host boundary and
   resource table are wired into canonical ABI ownership behavior.

## Completion Bar

The project should not claim full WASI 0.3 support until it can run real P3
components through a versioned host layer with resource, stream, future, and
async behavior covered by tests and measured performance gates.
