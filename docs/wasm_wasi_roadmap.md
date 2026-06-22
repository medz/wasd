# Wasm and WASI Executable Roadmap

This repository is moving from limited Wasm plus WASI Preview 1 support toward
real, verified Wasm and WASI support across Preview 1, WASI 0.2, and WASI 0.3.
This document is the working architecture guide, execution queue, and evidence
ledger for that transition. A support claim is not done until the checklist row
names the runtime path, the proof files, the verification command, and the exact
condition for marking it complete.

Status date: 2026-06-22.

## Roadmap Contract

- Treat every row with an ID as work that can be executed, reviewed, and checked
  off independently.
- Treat `[x]` as "implemented and covered by the listed evidence", not as a
  marketing support claim. Full-version support needs the support-gate table
  below, not just one completed implementation row.
- Treat `[ ]` as executable backlog. Each item must name the files to touch, the
  behavior to prove, the command that verifies it, and the condition for marking
  the row complete.
- Keep claims narrow. If only an internal host path is verified, do not mark a
  public API, cross-runtime, or full-version support row complete.
- Add a test or benchmark name with every completed row. If the evidence cannot
  be named, the row is not complete.
- For performance-sensitive work, include a benchmark command before updating
  the row. Test heat is a symptom; measured hot paths are the evidence.
- When a commit completes a row, update that row in the same commit with the
  exact verification command that was run.
- Never mark a version support gate complete from internal helper tests alone.
  P1/P2/P3 gates require the version-specific runtime path named in the row.
- If a row cannot name a failing or missing behavior, split it until it can.
- Do not add prose-only roadmap TODOs to active sections. A roadmap item is
  executable only when another maintainer can start from its fields without
  re-inferring the test, files, or done condition.

## Checklist Row Format

Every new backlog item must use these fields. Existing rows should be normalized
to this shape as they are touched.

- [ ] `ID` - One independently reviewable behavior, architecture, performance,
  or documentation boundary.
  - Scope: the narrow runtime/API/version boundary affected by this row.
  - Edit targets: files or directories expected to change.
  - Red test: the focused test or benchmark that should fail, be missing, or
    expose the gap before the implementation.
  - Implementation gate: the command that proves the behavior after the fix.
  - Performance gate: benchmark command, or `N/A` with the reason.
  - Done when: objective condition for changing `[ ]` to `[x]`.
  - Evidence update: roadmap, README, API docs, or support matrix updates that
    must happen in the same commit.
  - Claim impact: support gate changed by this row, or `None`.

## Execution Loop

Use this loop for every behavior or performance increment.

- [ ] Pick exactly one backlog ID unless the rows are mechanically inseparable.
- [ ] Write or extend the focused regression/spec test first.
- [ ] Confirm the new test fails for the expected missing behavior when
  practical.
- [ ] Implement the smallest runtime or host change that satisfies the row
  without crossing version boundaries.
- [ ] Run the row's gate command and any benchmark named by the row.
- [ ] Update the verification matrix or backlog row with the exact evidence.
- [ ] Commit the code, test, and roadmap evidence together.

## Current Execution Board

This is the active, ordered board. Treat the first unchecked row as the default
next commit. Split a row before starting if the red test or done condition is
too broad to verify in one commit.

### Now

- [ ] `P1-SOCKET-CONFORMANCE` - Close the next concrete Preview1 socket
  conformance gap.
  - Scope: native/browser shared Preview1 socket and descriptor semantics.
  - Edit targets: `test/wasi_test.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/socket.dart`, and
    `tool/wasi_vfs_benchmark.dart` when the touched path is performance-relevant.
  - Red test: add the smallest missing socket regression under
    `test/wasi_test.dart`, then confirm it fails or is absent for the expected
    reason before the fix.
  - Implementation gate: `dart test test/wasi_test.dart`;
    add `dart test -p chrome test/wasi_test.dart --name "<focused socket name>"`
    when the shared browser path is touched.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: the selected socket edge has regression coverage, native/browser
    behavior agrees for the supported subset, output pointers are not mutated on
    error paths, and the affected socket path is visible in benchmark output.
  - Evidence update: update this roadmap row or split it into a checked child row
    with the exact command evidence.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete it until every
    remaining Preview1 socket row and runtime gate is checked.

### Queued Next

- [ ] `CM-VALIDATION-GAPS` - Add one deterministic component validation failure
  before adding host behavior.
  - Scope: component decoder/validator behavior before runtime host mutation.
  - Edit targets: `lib/src/wasm/backend/native/interpreter/component.dart`,
    `lib/src/wasi/component/`, `test/component_test.dart`, and
    `test/wasi_component_async_host_test.dart` as needed by the selected gap.
  - Red test: add the missing validation case and confirm the current runtime
    accepts it, traps too late, or reports the wrong diagnostic.
  - Implementation gate: `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`.
  - Performance gate: N/A unless validation introduces a new decoded-shape hot
    path; in that case add the relevant component benchmark command here.
  - Done when: the invalid component fails before host state is mutated and the
    diagnostic names the rejected shape or interface boundary.
  - Evidence update: record the failing shape and the exact command evidence.
  - Claim impact: reduces `SUPPORT-P2` and `SUPPORT-P3` validation risk; no
    support gate changes directly.
- [ ] `P2-P3-ADAPTERS` - Bind one real Preview2/Preview3 adapter path over shared
  component primitives.
  - Scope: versioned component host adapters, not Preview1 imports.
  - Edit targets: `lib/src/wasi/preview2/`,
    `lib/src/wasi/preview3/`, `lib/src/wasi/component/`,
    `test/wasi_component_versioned_host_test.dart`, and adapter-specific tests.
  - Red test: add a real versioned adapter execution case that fails because the
    interface is not yet bound through the versioned host.
  - Implementation gate: `dart test test/wasi_component_versioned_host_test.dart`
    plus the adapter-specific focused test.
  - Performance gate: run the component/resource benchmark that covers any new
    resource, stream, future, or callback path added by the adapter.
  - Done when: one real P2/P3 component path executes through the versioned host
    without leaking Preview1 imports or bypassing shared component ownership.
  - Evidence update: record adapter files, tests, and benchmark output in this
    document.
  - Claim impact: starts concrete `SUPPORT-P2` / `SUPPORT-P3` evidence; does not
    complete either gate.
- [ ] `P3-ASYNC-COPY-GAPS` - Expand one validated async value shape through copy,
  waitable, cancel/drop, and benchmark paths.
  - Scope: WASI 0.3 stream/future async host and value-memory behavior.
  - Edit targets: `lib/src/wasi/component/async_host.dart`,
    `lib/src/wasi/component/value_memory.dart`,
    `lib/src/wasi/component/waitable_set.dart`,
    `test/wasi_component_host_test.dart`,
    `test/wasi_component_async_host_test.dart`, and async benchmark tools.
  - Red test: add one missing `stream<T>` or `future<T>` shape that currently
    cannot be copied, waited, canceled, or dropped through the same host path.
  - Implementation gate: `dart test test/wasi_component_host_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart test test/wasi_component_value_memory_test.dart`.
  - Performance gate:
    `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`;
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`.
  - Done when: the selected shape is validated, copied, completed or canceled,
    dropped, and benchmarked through the same P3 host path.
  - Evidence update: record shape, tests, and benchmark output in this document.
  - Claim impact: moves `SUPPORT-P3` toward execution coverage; no public claim.
- [ ] `CM-VALUE-VALIDATION` - Add one composite value shape only when the same
  shape can be executed.
  - Scope: Canonical ABI value validation matched to executable lift/lower paths.
  - Edit targets: `lib/src/wasi/component/value_memory.dart`,
    `lib/src/wasi/component/adapter_host.dart`,
    `test/wasi_component_value_memory_test.dart`, and component-host tests.
  - Red test: add a composite shape that currently validates incorrectly or lacks
    a matching executable lowering/lifting path.
  - Implementation gate: value-memory, async-host, and component-host focused
    tests for the selected shape.
  - Performance gate: relevant component or async benchmark when the shape adds a
    repeated copy or allocation path.
  - Done when: validation and execution accept/reject the same shape under the
    same ownership and memory rules.
  - Evidence update: record the selected shape and command evidence.
  - Claim impact: reduces P2/P3 adapter inconsistency; no direct support gate.
- [ ] `WIT-INGESTION` - Bind imported/generated WIT worlds through versioned
  adapters.
  - Scope: WIT package/interface/world ingestion into Preview2/Preview3 adapter
    binding.
  - Edit targets: `lib/src/wasi/component/wit_document.dart`,
    versioned adapter modules, WIT ingestion tests, and component-host binding
    tests.
  - Red test: add an imported/generated world that parses but cannot bind through
    the versioned host.
  - Implementation gate: WIT ingestion tests plus the matching component-host
    binding tests.
  - Performance gate: N/A for parsing-only increments; add adapter benchmark
    evidence when the row binds executable host calls.
  - Done when: imported/generated worlds bind through Preview2/Preview3 adapters
    and failures name the interface/world boundary.
  - Evidence update: record WIT files, versioned adapter tests, and command
    evidence.
  - Claim impact: required before `SUPPORT-P2` or `SUPPORT-P3` can be checked.

### Recently Checked

- [x] `P1-SOCKET-RECEIVE-SHUTDOWN-TERMINAL` - Receive-side shutdown remains
  terminal across host-injected data and poll readiness.
  - Evidence:
    `dart test test/wasi_test.dart --name "virtual socket receive shutdown remains terminal"`
    failed before the fix, then passed after the fix;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket receive shutdown remains terminal"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_shutdown and descriptor rights are enforced for preview1 sockets"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`;
    `dart analyze`.
  - Claim impact: aligns shared Preview1 stream/datagram receive and poll state
    with shutdown semantics for `SUPPORT-P1`; does not complete the parent
    `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-SEND-SHUTDOWN-VFS` - Shared VFS socket send rejects
  write-side shutdown with `EPIPE`.
  - Evidence:
    `dart test test/wasi_test.dart --name "virtual socket send rejects write-side shutdown"`
    failed before the fix, then passed after the fix;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "sock_send reports pipe after write-side shutdown"`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket send rejects write-side shutdown"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`;
    `dart analyze`.
  - Claim impact: aligns shared Preview1 VFS stream/datagram send behavior with
    `sock_send` shutdown semantics for `SUPPORT-P1`; does not complete the parent
    `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-ACCEPT-STREAM-QUEUE` - Accepted socket queues reject datagram
  descriptors before `sock_accept` can expose them.
  - Evidence:
    `dart test test/wasi_test.dart --name "accepted socket queues require stream sockets"`
    failed before the fix, then passed after the fix;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "accepted socket queues require stream sockets"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`;
    `dart analyze`.
  - Claim impact: closes one Preview1 host-injected socket conformance edge for
    `SUPPORT-P1`; does not complete the parent `P1-SOCKET-CONFORMANCE` row.
- [x] `PERF-WASM-COMPILE-PREDECODE` - Validator signature classification avoids
  byte-list churn, native Modules retain validated predecode results, and
  instantiate reuses them instead of decoding functions again.
  - Evidence: `dart run tool/doom_instantiate_profile.dart --compile-breakdown --json`;
    `dart run tool/doom_instantiate_profile.dart --instantiate-breakdown --json`;
    `dart run tool/doom_instantiate_profile.dart --json`;
    `dart test test/wasm_predecode_test.dart test/wasm_test.dart test/wasi_test.dart`;
    `dart analyze`.
  - Claim impact: removes the DOOM compile/instantiate predecode heat blocker;
    does not complete `SUPPORT-WASM`.
- [x] `PERF-DOOM-INSTANTIATE-PHASES` - DOOM instantiate has phase-level RSS and
  duration evidence, and decoder byte reads avoid avoidable section/body double
  copies.
  - Evidence: `dart run tool/doom_instantiate_profile.dart --json`;
    `dart test test/wasm_test.dart`; `dart test test/component_test.dart`;
    `dart test test/doom_smoke_test.dart --name "doom cli runtime matrix"`;
    `dart analyze`.
  - Claim impact: identifies remaining compile/validation allocation blockers;
    does not complete `SUPPORT-WASM`.
- [x] `PERF-HEAVY-RUNNERS` - DOOM runtime matrix reports per-runtime elapsed time
  and peak RSS; spec testsuite reports conversion cache hits/misses and Top Slow
  Files.
  - Evidence:
    `dart run tool/spec_testsuite_runner.dart --suite=core --file=imports0.wast --output-json=.dart_tool/spec_runner/perf_heavy_runners_imports0.json --output-md=.dart_tool/spec_runner/perf_heavy_runners_imports0.md --prepare-root=.dart_tool/spec_runner/perf_heavy_runners_bundle --conversion-cache-dir=.dart_tool/spec_runner/conversion_cache`;
    `dart test test/doom_smoke_test.dart --name "doom cli runtime matrix"`.
  - Claim impact: gives performance evidence for `SUPPORT-WASM` and
    `PERFORMANCE-GATES`; does not complete either support claim.
- [x] `WIT-DOCUMENT-BOUNDARIES` - Internal WIT package/interface/world parsing
  with diagnostics is implemented under `lib/src/wasi/component/`.
  - Evidence: `dart test test/wasi_component_wit_test.dart`; `dart analyze`.
  - Claim impact: provides structured input for later P2/P3 adapters, but no
    public support claim.

## Support Claim Gates

These are release-claim gates, not implementation tasks. A lower-level row in
the roadmap can be complete while the version-level support claim remains
unchecked.

- [ ] `SUPPORT-WASM` - Full core Wasm support.
  - Current: core module parsing and execution exist, with conformance work
    still in progress.
  - Required gate: spec-suite coverage is wired into a repeatable runner,
    current failures are triaged, and hot files have targeted performance
    evidence.
- [ ] `SUPPORT-P1` - Full WASI Preview1 support.
  - Current: `WASI(...)` supports Preview1, but socket and host-backed edge
    cases are still incomplete.
  - Required gate: native, browser, and Node-relevant Preview1 paths have
    focused regression coverage, descriptor/socket benchmarks, and
    conformance-shaped evidence.
- [ ] `SUPPORT-P2` - Full WASI 0.2 / Preview2 support.
  - Current: the public factory rejects Preview2; internal versioned component
    gates exist.
  - Required gate: real Preview2 components bind through versioned adapters,
    WIT/interface ingestion exists, and public docs/API expose only verified
    behavior.
- [ ] `SUPPORT-P3` - Full WASI 0.3 / Preview3 support.
  - Current: the public factory rejects Preview3; internal P3 resources, async
    primitives, waitables, tasks, context, thread identity, and copy paths are
    partially executable.
  - Required gate: real Preview3 components execute through a versioned host
    with resources, streams, futures, waitables, tasks, async behavior,
    cancellation, and benchmark evidence.

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

## Verification Matrix

| Status | Capability boundary | Evidence to inspect | Verification gate | Remaining gap |
| --- | --- | --- | --- | --- |
| [x] | Preview1 native/browser VFS descriptor subset | `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Conformance-shaped socket edge cases and native adapter boundaries. |
| [x] | Component decoder and canonical validation base | `lib/src/wasm/backend/native/interpreter/component.dart`, `test/component_test.dart` | `dart test test/component_test.dart` | WIT/world ingestion and broader official component suite coverage. |
| [x] | Resource table plus decoded `resource.*` host binding | `lib/src/wasi/component/resource_table.dart`, `lib/src/wasi/component/resource_host.dart`, `test/wasi_component_resource_table_test.dart`, `test/wasi_component_resource_host_test.dart` | `dart test test/wasi_component_resource_table_test.dart test/wasi_component_resource_host_test.dart` | Full Canonical ABI ownership/drop integration across generated adapters. |
| [x] | Versioned Preview2/Preview3 capability gates | `lib/src/wasi/component/versioned_host.dart`, `lib/src/wasi/preview2/component_host.dart`, `lib/src/wasi/preview3/component_host.dart`, `test/wasi_component_versioned_host_test.dart` | `dart test test/wasi_component_versioned_host_test.dart` | Concrete P2/P3 interface adapter modules instead of generic facade binding. |
| [x] | Internal P3 async endpoints, waitables, tasks, context, thread identity | `lib/src/wasi/component/async_host.dart`, `lib/src/wasi/component/waitable_set.dart`, `lib/src/wasi/component/task.dart`, `lib/src/wasi/component/thread.dart`, `test/wasi_component_async_host_test.dart` | `dart test test/wasi_component_async_host_test.dart test/wasi_component_waitable_set_test.dart test/wasi_component_task_test.dart test/wasi_component_thread_test.dart` | Full async lowering, task spawning, scheduler-owned thread switch/suspend/resume. |
| [x] | Owned-resource stream/future copy buffers, pending copy events, and cancel-copy events through async, component, and versioned Preview3 hosts | `lib/src/wasi/component/value_memory.dart`, `test/wasi_component_async_host_test.dart`, `test/wasi_component_host_test.dart`, `test/wasi_component_versioned_host_test.dart`, `test/support/component_fixtures.dart` | `dart test test/wasi_component_host_test.dart test/wasi_component_versioned_host_test.dart test/wasi_component_async_host_test.dart test/wasi_component_value_memory_test.dart`; `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`; `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json` | Borrowed payload lifetimes, nested async payloads, and public P3 API claims remain unsupported. |
| [x] | Canonical lift/lower adapter planning and internal callback invocation | `lib/src/wasi/component/adapter_plan.dart`, `lib/src/wasi/component/adapter_host.dart`, `test/wasi_component_adapter_plan_test.dart` | `dart test test/wasi_component_adapter_plan_test.dart`; `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json` | Automatic binding of decoded lift/lower definitions to instantiated core/component functions. |
| [ ] | Preview1 full socket conformance | Add focused regressions under `test/wasi_test.dart` and VFS/socket benchmarks | `dart test test/wasi_test.dart`; `dart run tool/wasi_vfs_benchmark.dart --json` | Native adapter boundaries and broader socket conformance remain incomplete. |
| [x] | WIT package/interface/world boundary parser | `lib/src/wasi/component/wit_document.dart`, `test/wasi_component_wit_test.dart` | `dart test test/wasi_component_wit_test.dart`; `dart analyze` | Parser evidence alone does not unlock P2/P3 support; it only feeds adapter binding. |
| [ ] | P2/P3 world/interface ingestion | Bind parsed/generated WIT worlds through versioned Preview2/Preview3 adapters | Future gate: dedicated WIT ingestion tests plus component host binding tests | No public claim until generated/imported worlds bind through versioned hosts. |
| [ ] | Full WASI 0.3 support | Real P3 components through versioned host with resources, streams, futures, waitables, tasks, and async behavior | Future gate: wasi-testsuite-style component runs plus performance gates | Current work is internal capability coverage, not full P3 support. |

## Current wasd Baseline

This is the implementation state as of 2026-06-22 on `main`.

- Preview 1 is real but still incomplete. Native and browser hosts share
  `lib/src/wasi/preview1/common/vfs.dart` for virtual files, directories,
  readdir state, hard links, symlinks/readlink, configured stream/datagram
  sockets, descriptor flags, descriptor rights, descriptor times, descriptor
  sync/advice validation, clock/file/socket polling readiness including
  host-supplied socket readiness hints, host-backed stream/datagram
  receive/send handlers, and descriptor renumbering. Node still delegates
  Preview 1 behavior to `node:wasi`.
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
  `WASIPreview1Socket`, not raw networking. Stream socket `sock_recv` and
  `sock_send` preflight the complete iovec array before mutating guest memory,
  consuming receive data, or recording sent bytes, matching the datagram path's
  all-or-error validation boundary.
- Preview 1 directory entries are indexed through per-directory child maps so
  common path/link/symlink mutation paths rebuild only affected directories.
  File lookup fallback indexes are also maintained as ordered path buckets, so
  hard-link, rename, and unlink mutations update only touched lower-path and
  basename keys instead of rebuilding every file lookup index. Empty-directory
  removal uses the same child map instead of scanning every virtual path.
  The benchmark entrypoint is
  `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; it reports
  baseline, directory-heavy, descriptor-heavy, and socket-heavy distributions.
  It also covers socket multi-iov peek/waitall, datagram truncation, socket
  send/recv including host-backed stream/datagram handlers and write-side
  and read-side would-block behavior, socket polling readiness including
  zero-length datagram readiness, queued accepts, and externally backed
  read/write readiness hints, and socket renumber/close descriptor paths.
  Stream socket sends are recorded as owned byte chunks, and long receive
  streams compact consumed prefixes in larger batches so socket-heavy reads do
  not repeatedly shift the backing buffer. Default datagram socket sends now
  transfer the VFS-owned message buffer into the socket record path instead of
  copying it a second time, while caller-owned `writeMessage` lists still keep
  defensive copy semantics. The owned-buffer hook is hidden from the public
  `package:wasd/wasi.dart` export so the user-facing socket API stays small.
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
  host can also copy primitive, fixed-composite, string, and string/list
  `stream<T>`/`future<T>` values between guest memory and async endpoints for
  canonical `stream.read`/`stream.write` and `future.read`/`future.write`
  adapters.
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
  `future.write` memory copies, plus primitive string `stream.read`,
  `future.read`, and `future.write` memory copies, and decoded owned-resource
  stream/future element copy buffers represented as canonical `u32` handles,
  also have a canonical event-start path: immediate copies return the packed
  copy payload, pending
  copies return `0xffffffff` (`BLOCKED`) and later publish the corresponding
  waitable event with the endpoint handle and packed copy result.
  Pending event-start copies
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
  programs. It now also exposes a structured canonical capability report for
  every decoded canonical kind, including the runtime area and any unsupported
  reason, so future Preview 2 / Preview 3 adapters can preflight host coverage
  without copying private dispatch switches or parsing exception strings. The
  internal versioned component-host facade consumes that report to separate
  version-profile errors from host capability gaps: Preview2 resource canonical
  components can bind through the shared component host, Preview2 rejects P3
  stream/future canonical definitions before host mutation, and Preview3 admits
  the async profile while still reporting unimplemented host capabilities such
  as `canon lower` as host gaps. The same facade can also prepare a reusable
  binding plan that captures component validation errors, unsupported canonical
  definitions, and the canonical definition snapshot once before any operation
  table is built. Internal Preview2 and Preview3 component-host modules now pin
  that facade to their respective profiles, giving future version adapters a
  concrete entrypoint instead of constructing mixed-version component hosts.
  An internal component host adapter now combines that canonical plan with the
  decoded component resource and async value binding lists, defines component
  resources plus supported unit, primitive, owned-resource, fixed-size
  composite, string, and fixed-width-element list `stream<T>`/`future<T>`
  values on the shared table only after validation and capability checks pass,
  and returns the canonical-indexed program from the same shared host state.
  The same component-host plan also captures canonical `lift`/`lower` adapter
  metadata:
  decoded function signatures, string encoding and core option indexes,
  Canonical ABI value-memory codecs for supported parameter/result shapes, and
  structured `own`/`borrow` resource handle uses. An internal direct adapter
  host can execute synchronous `lift`/`lower` plans over direct component
  values validated by the shared Canonical ABI value-memory codec, including
  primitive values and dynamic string/list payloads passed as Dart-side
  component values, plus canonical `u32` handles for direct or memory-backed
  resource and `error-context` adapter calls, including resource handles nested
  inside supported composite adapter value-memory shapes. It resolves callbacks
  by decoded `coreFunctionIndex` / `functionIndex`, then exposes those
  operations through a canonical-indexed adapter program. Memory-backed adapter
  invocation still rejects nested async values, async adapters, and value shapes
  without a supported codec instead of approximating them. Resource handle
  ownership, drop, and borrow lifetime semantics remain a higher-level resource
  table concern instead of being approximated in the value-memory codec. This
  keeps future
  adapter generation inputs explicit while automatic binding of decoded
  `lift`/`lower` definitions to instantiated core/component functions is still
  reported as a host capability gap instead of being overclaimed. The same
  adapter program can also load direct adapter parameters from canonical value
  memory, store direct adapter results back through the shared value-memory
  codec plus explicit `realloc`, and invoke the supported primitive/string
  plus record/tuple/fixed-list/flags/enum/list/variant/option/result/resource
  and error-context subset through flat scalar values such as canonical string
  and dynamic list `(ptr, len)` pairs, field-by-field record scalars, flags
  bitsets, enum discriminants, generic variant tag/payload pairs, option
  tag/payload pairs, result tag/payload pairs, `own`/`borrow` canonical `u32`
  handles, and `error-context` canonical `u32` handles. These are value-codec
  adapter boundaries, not a complete flattened core function ABI. Async value
  bindings now also expose Canonical ABI memory-copy layout through an
  internal Canonical ABI value-memory codec covering primitive values,
  records/tuples, fixed lists, flags, variants, options, results, enums, and
  dynamic strings/lists, including `list<string>`. Dynamic string/list storage
  uses canonical `(ptr, len)` records plus explicit `realloc`; owned resource
  handles use canonical `u32` copy-buffer values for decoded stream/future
  elements, while resource handle-table ownership/drop, borrow lifetime
  enforcement, and nested async payload semantics remain unsupported instead of
  being approximated. Future P3 adapters can route stream/future
  memory lowering through this shared codec without re-deriving byte widths,
  alignments, padding, or dynamic payload allocation separately from the
  executable copy path.
  An internal WIT document boundary parser now normalizes package, interface,
  world, import, and export declarations into structured objects with
  line/column diagnostics for duplicate names and unresolved local world
  references. This is a parser/input boundary for future Preview2/Preview3
  adapter binding, not WIT-generated execution or a public P2/P3 support claim.
  Component-host tests now also exercise decoded core-memory primitive
  `stream<T>`/`future<T>` copy paths through synchronous Canonical ABI calls,
  pending fixed-size and primitive string completion through waitable events,
  and fixed-size record, fixed-width-element list, primitive string, plus
  `list<string>` `stream<T>`/`future<T>` round trips through decoded
  core-memory copy definitions. Component validation now follows the Canonical
  ABI stream/future copy option split: `stream.read`/`future.read` require
  `realloc` for dynamic list/string elements, `stream.write`/`future.write` do
  not, `memory` is still required when an element type is present, and
  `realloc` itself requires `memory`. Primitive `string`
  `stream.write`/`future.write` now read
  canonical `(ptr, len)` string records from guest memory through the same
  UTF-8, UTF-16, and Latin1+UTF-16 adapter used by error-context memory paths,
  and direct/handle-backed primitive `string` `stream.read`/`future.read`
  paths can lower host strings back into guest memory through a canonical
  `realloc` callback plus `(ptr, len)` result records. This makes both
  directions of primitive string async memory copy executable in the internal
  async host. The canonical-indexed component program now also passes an
  explicit `realloc` callback through memory-backed invocation paths, so
  decoded component-host primitive string `stream.read`/`stream.write` and
  `future.read`/`future.write` round trips can execute through their respective
  `(handle, ptr, n)` and `(handle, ptr)` core-memory call shapes.
  Dynamic list values now use the same callback to allocate payload storage
  before writing the canonical `(ptr, len)` record, and list elements containing
  strings recursively allocate their own canonical string payloads. The adapter
  still does not automatically invoke decoded core realloc exports; callers
  must provide the realloc callback at invocation time. Lists containing
  borrows or nested async values remain unsupported for executable memory copy.
  This is an adapter boundary for future P2/P3 version modules, not a public
  support claim.
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
  lowering/lifting, general memory-backed typed stream/future copy beyond the
  verified primitive/string/fixed-composite/list/string-list subset, and full
  async stream/future execution are not production-supported yet.
- The public `WASIVersion` enum names Preview1, Preview2, and Preview3, but the
  `WASI(...)` factory now accepts only Preview1 and throws `UnsupportedError`
  for component-model WASI versions. Internal component-host version profiles
  and fixed Preview2/Preview3 component-host modules now exist for P2/P3
  preflight, but this is still an intentional public version boundary, not a
  support claim.

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

## Ordered Execution Queue

Work from this queue before opening new lines of implementation. The order is
chosen to keep public claims honest, keep the architecture layered, and keep
performance visible while the support surface expands.

1. `P1-SOCKET-CONFORMANCE`
   - Why: Preview1 is the only public WASI surface today, so remaining P1 gaps
     should be measured before P2/P3 become public.
   - Do not: add raw networking APIs that Preview1 does not specify.
2. `PERF-VFS-DISTRIBUTIONS`
   - Why: socket and descriptor work needs benchmark distributions that
     resemble conformance loads, not only small unit tests.
   - Do not: optimize VFS code from CPU heat alone without benchmark data.
3. `PERF-HEAVY-RUNNERS`
   - Why: heavy tests and fixture conversion can hide runtime regressions or
     create false performance signals.
   - Do not: treat one hot test run as proof of a runtime algorithm problem.
4. `CM-VALIDATION-GAPS`
   - Why: deterministic validation rules should fail early before runtime host
     state is mutated.
   - Do not: approximate unsupported Canonical ABI shapes at runtime.
5. `P3-ASYNC-COPY-GAPS`
   - Why: P3 stream/future behavior must grow through the shared async host and
     memory codec.
   - Do not: add public P3 claims for shapes not covered by copy, cancellation,
     waitable, and benchmark gates.
6. `WIT-DOCUMENT-BOUNDARIES`
   - Why: WIT parsing needs a real diagnostic model before generated worlds can
     be safely bound to Preview2/Preview3 adapters.
   - Do not: expose this as public P2/P3 support or generate bindings before
     adapter ownership semantics are ready.
7. `P2-P3-ADAPTERS`
   - Why: versioned adapters are the boundary that turns internal primitives
     into real WASI versions.
   - Do not: leak Preview1 imports or types into component worlds.
8. `CM-VALUE-VALIDATION`
   - Why: composite value validation should expand only with matching
     lowering/lifting support.
   - Do not: validate shapes that cannot be executed through the same host path.
9. `WIT-INGESTION`
   - Why: WIT/world ingestion should bind into stable versioned hosts, not
     around them.
   - Do not: claim P2/P3 support from decoded canonical snippets alone.

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
  spec runner, DOOM runtime matrix, and DOOM smoke tests use the shared
  measured-process helper for elapsed time and sampled child-process peak RSS;
  future heavy runners should reuse the same helper instead of open-coding
  process timing.
- DOOM instantiate profiling must stay phase-level, not only whole-process.
  `tool/doom_instantiate_profile.dart --json` reports fixture sizes, total
  duration, baseline/peak RSS, and per-phase RSS deltas. A local run after
  eliminating avoidable byte-reader double copies still measured the
  `compile_module` phase as the dominant spike
  (`rss_delta_bytes=442023936`), so the next optimization target is
  validation/predecode allocation rather than runner scheduling.
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
  `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`, covering
  baseline, directory-heavy, descriptor-heavy, and socket-heavy distributions,
  plus `path_open`, `fd_readdir`, link/symlink mutation, rights checks, socket
  multi-iov `RECV_PEEK`/`RECV_WAITALL`, datagram truncation, default and
  host-backed datagram send, socket send/recv including read/write
  would-block paths and stream iovec preflight costs, and socket poll
  readiness, plus file, directory, and socket descriptor renumber/close over
  large directory and descriptor sets. Keep optimizing against benchmark data
  instead of test suite heat alone.
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
  delivery, plus fixed-size primitive and owned-resource stream/future
  memory-copy costs, are measured by
  `dart run tool/wasi_component_async_benchmark.dart --json`. Keep active-copy
  state checks on the waitable-event path so ordinary handle and memory
  invocations do not pay for event lifecycle enforcement.
- Component resource table canonical `resource.new`/`resource.rep`/
  `resource.drop`, decoded resource-only canonical program invocation,
  component resource binding extraction from decoded type index spaces,
  component-host binding startup with resource, Preview2 version-profile
  resource binding, stream, Preview3 version-profile stream binding, decoded
  core-memory primitive and owned-resource stream-copy, decoded core-memory
  fixed-size record, list, and string-list stream-copy, decoded direct string
  adapter program invocation, decoded direct string adapter flat-scalar invocation, decoded
  direct record, tuple, and fixed-list adapter flat-scalar invocation, decoded
  direct flags/enum adapter flat-scalar invocation, decoded direct list adapter
  flat pointer/length invocation, decoded direct variant adapter flat tag/payload
  invocation,
  decoded direct option adapter flat tag/payload invocation,
  decoded direct result adapter flat tag/payload invocation,
  decoded direct resource adapter handle invocation, decoded direct resource
  adapter flat handle invocation, decoded direct resource adapter memory
  invocation, decoded direct resource-record adapter memory invocation, decoded
  direct error-context adapter handle invocation, decoded direct error-context
  adapter flat handle invocation, decoded direct error-context adapter memory
  invocation, decoded direct string adapter memory invocation, decoded
  core-memory primitive and owned-resource future-copy, and decoded core-memory
  list plus string-list future-copy round trips, mixed
  canonical-host
  program invocation over shared component state, error-context canonical
  lifecycle invocation, error-context canonical string memory adapter invocation
  with result records, nominal typed lookup, synchronous/asynchronous borrow,
  and drop behavior are measured by
  `dart run tool/wasi_resource_table_benchmark.dart --json`.

## Near-Term Execution Backlog

- [ ] `P1-SOCKET-CONFORMANCE` - Preview1 socket conformance edge cases.
  - Scope: native/browser shared Preview1 socket and descriptor behavior,
    including host-backed adapters, queued accepts, shutdown/readiness state, and
    guest-memory side effects on errors.
  - Edit targets: `test/wasi_test.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/socket.dart`, and
    `tool/wasi_vfs_benchmark.dart` when the selected edge affects measured
    socket paths.
  - Red test: add the smallest missing regression under `test/wasi_test.dart`;
    for shared behavior, also plan a focused browser gate with
    `dart test -p chrome test/wasi_test.dart --name "<focused socket name>"`.
  - Implementation gate: `dart test test/wasi_test.dart`; add the focused Chrome
    command when shared browser code changes.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: every newly selected socket edge has regression coverage, error
    paths preserve output pointers and queued data, native/browser behavior agrees
    for the supported subset, and benchmark output names the affected socket
    paths.
  - Evidence update: split each completed edge into a checked child row or update
    this row with the exact commands run.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete it until the
    Preview1 socket and runtime gates are all checked.
- [x] `P1-SOCKET-ACCEPT-STREAM-QUEUE` - Accepted socket queues require stream
  sockets.
  - Scope: host-injected Preview1 stream listener state before VFS fd allocation
    and `sock_accept` exposure.
  - Edit targets: `lib/src/wasi/preview1/socket.dart` and `test/wasi_test.dart`.
  - Red test:
    `dart test test/wasi_test.dart --name "accepted socket queues require stream sockets"`
    failed before the fix because a stream listener accepted a datagram socket.
  - Implementation gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "accepted socket queues require stream sockets"`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
    The validation runs only on host queue construction/mutation; the benchmark
    records that existing socket recv/send/poll/renumber paths remain covered.
  - Done when: both constructor-supplied `pendingAccepted` sockets and later
    `queueAccepted` calls reject datagram sockets before any invalid accepted fd
    can be exposed.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
- [x] `P1-SOCKET-SEND-SHUTDOWN-VFS` - Shared VFS send rejects write-side
  shutdown.
  - Scope: native/browser shared Preview1 VFS `writeSocketFromIov` behavior for
    stream and datagram descriptors after `sock_shutdown(..., WR)`.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart` and
    `test/wasi_test.dart`.
  - Red test:
    `dart test test/wasi_test.dart --name "virtual socket send rejects write-side shutdown"`
    failed before the fix because the shared helper returned success with zero
    bytes instead of `EPIPE`.
  - Implementation gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "sock_send reports pipe after write-side shutdown"`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket send rejects write-side shutdown"`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: stream and datagram VFS sends return `EPIPE` after write-side
    shutdown, leave `nwritten` unchanged, and record no sent bytes/messages.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
- [x] `P1-SOCKET-RECEIVE-SHUTDOWN-TERMINAL` - Receive-side shutdown remains
  terminal.
  - Scope: native/browser shared Preview1 socket state for stream/datagram
    receive, host-injected receive data, and `poll_oneoff` read readiness after
    `sock_shutdown(..., RD)`.
  - Edit targets: `lib/src/wasi/preview1/socket.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, and `test/wasi_test.dart`.
  - Red test:
    `dart test test/wasi_test.dart --name "virtual socket receive shutdown remains terminal"`
    failed before the fix because host-injected data reopened the receive side
    and poll reported queued bytes instead of hangup.
  - Implementation gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket receive shutdown remains terminal"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_shutdown and descriptor rights are enforced for preview1 sockets"`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: stream and datagram receive-side shutdown remains monotonic,
    host-injected receive data cannot reopen it, poll reports hangup before
    queued data/readiness hints, and VFS receive returns zero bytes.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
- [x] `P1-SOCKET-READINESS-HINTS` - Preview1 host-backed socket readiness.
  - Change: let injected `WASIPreview1Socket` descriptors expose read byte-count
    readiness and write readiness without buffering fake data.
  - Evidence: `lib/src/wasi/preview1/socket.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`.
  - Gate: `dart test test/wasi_test.dart`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: `poll_oneoff`/VFS reports host-supplied read readiness,
    host-blocked write readiness, and benchmark output includes both paths.
- [x] `P1-SOCKET-SEND-BACKPRESSURE` - Preview1 socket send would-block state.
  - Change: make `writeReady=false` block `sock_send` with `EAGAIN` without
    writing `nwritten` or recording sent bytes.
  - Evidence: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`.
  - Gate: `dart test test/wasi_test.dart`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: poll and send agree on host-blocked writable state and the
    benchmark includes the blocked-send path.
- [x] `P1-SOCKET-HOST-STREAM-IO` - Preview1 host-backed stream socket IO.
  - Change: let injected stream sockets pull receive bytes from a host provider
    and delegate sent bytes to a host handler.
  - Evidence: `lib/src/wasi/preview1/socket.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, `README.md`.
  - Gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "host-backed stream handlers"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: `sock_recv` can satisfy `RECV_WAITALL` from the host provider,
    `sock_send` reaches the host handler, partial host writes stop the multi-iov
    send, and benchmark output includes the host-backed stream path.
- [x] `P1-SOCKET-HOST-DATAGRAM-IO` - Preview1 host-backed datagram socket IO.
  - Change: let injected datagram sockets pull whole messages from a host
    provider and delegate sent datagrams to a host handler.
  - Evidence: `lib/src/wasi/preview1/socket.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, `README.md`.
  - Gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "host-backed datagram handlers"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: host-provided zero-length datagrams remain readable,
    `sock_recv`/`RECV_PEEK` preserve host-provided messages, `sock_send`
    reaches the datagram handler, and benchmark output includes host-backed
    datagram receive/send paths.
- [x] `P1-SOCKET-HOST-HANDLER-VALIDATION` - Preview1 socket host callback
  result validation.
  - Change: reject invalid host send counts with `EINVAL` instead of leaking a
    Dart exception or writing an untrusted `nwritten` value.
  - Evidence: `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`.
  - Gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "invalid write counts"`.
  - Done when: stream and datagram host send handlers returning out-of-range
    counts leave `nwritten` unchanged and report `EINVAL`.
- [x] `P1-SOCKET-RECV-WOULD-BLOCK` - Preview1 socket receive would-block state.
  - Scope: native/browser shared Preview1 `sock_recv` behavior for empty
    stream and datagram descriptors.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and `tool/wasi_vfs_benchmark.dart`.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_recv returns again"` failed
    before the fix.
  - Implementation gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv"`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: empty, non-shutdown stream/datagram sockets return `EAGAIN`
    without modifying `nread`/`roflags`, receive-shutdown sockets still report
    success with zero bytes, and the socket benchmark covers both read-side
    would-block paths.
- [x] `P1-SOCKET-IOV-PREFLIGHT` - Preview1 stream socket iovec preflight.
  - Scope: native/browser shared Preview1 stream `sock_recv` and `sock_send`
    validation before socket or guest-memory side effects.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "validate stream iovs"` failed
    before the fix.
  - Implementation gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "sock_"`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: invalid later stream iovs return `EINVAL` without modifying
    output pointers, guest buffers, receive queues, or sent-byte state, and
    the all-distribution VFS benchmark covers the stream recv/send hot path
    with preflight enabled.
- [x] `P1-SOCKET-DATAGRAM-SEND-OWNED` - Preview1 datagram send copy reduction.
  - Scope: native/browser shared Preview1 VFS datagram send hot path.
  - Edit targets: `lib/src/wasi/preview1/socket.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`, and
    `tool/wasi_vfs_benchmark.dart`.
  - Red test: N/A for the narrow performance-only copy reduction; the focused
    regression keeps caller-owned `writeMessage` copy semantics separate from
    the VFS-owned hot path.
  - Implementation gate: `dart test test/wasi_test.dart`; `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=socket-heavy --iterations=1000 --json`.
  - Done when: VFS-created datagram messages are recorded without a second
    defensive copy, the owned-buffer hook is not exported through
    `package:wasd/wasi.dart`, caller-owned `writeMessage` input is still
    copied, and the socket-heavy benchmark covers default and host-backed
    datagram send paths.
- [x] `PERF-VFS-DISTRIBUTIONS` - VFS/descriptor benchmark distributions.
  - Change: extend benchmark data to larger conformance-shaped path, directory,
    socket, and descriptor sets before optimizing more VFS code.
  - Evidence: `tool/wasi_vfs_benchmark.dart`.
  - Gate: `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: benchmark JSON reports baseline, directory-heavy,
    descriptor-heavy, and socket-heavy runs with the dimensions and metrics for
    each distribution.
- [x] `PERF-HEAVY-RUNNERS` - Heavy runner process and fixture-conversion audit.
  - Change: add timing/cache evidence for spec runner and DOOM runtime hot
    paths before changing runtime code for test heat.
  - Evidence: `tool/spec_testsuite_runner.dart`,
    `tool/doom_runtime_matrix.dart`, DOOM smoke tests, measured process output,
    `.dart_tool/spec_runner/perf_heavy_runners_imports0.json`, and
    `.dart_tool/spec_runner/perf_heavy_runners_imports0.md`.
  - Gate:
    - `dart run tool/spec_testsuite_runner.dart --suite=core --file=imports0.wast --output-json=.dart_tool/spec_runner/perf_heavy_runners_imports0.json --output-md=.dart_tool/spec_runner/perf_heavy_runners_imports0.md --prepare-root=.dart_tool/spec_runner/perf_heavy_runners_bundle --conversion-cache-dir=.dart_tool/spec_runner/conversion_cache`
    - `dart test test/doom_smoke_test.dart --name "doom cli runtime matrix"`
    - `dart test test/measured_process_test.dart`
    - `dart analyze`
  - Done when: reports include elapsed time, peak RSS, cache hits/misses, and
    the slowest conversion/execution steps.
  - Result: targeted spec report recorded one conversion cache hit, zero
    misses, and a Top Slow Files row for `imports0.wast`; the DOOM runtime
    matrix now reports `elapsed_ms` and `peak_rss_bytes` for both `dart-vm` and
    `node-js` on successful runs. A local instantiate-mode run measured the
    Dart VM child at `peak_rss_bytes=859389952`, which makes VM instantiate
    memory the next performance root-cause candidate rather than a test runner
    scheduling artifact.
- [x] `PERF-DOOM-INSTANTIATE-PHASES` - DOOM instantiate phase profiler.
  - Change: add a reusable DOOM instantiate profiler and remove avoidable
    decoder/example byte copies without weakening compiled-module byte
    isolation.
  - Evidence: `tool/doom_instantiate_profile.dart`,
    `lib/src/wasm/backend/native/interpreter/byte_reader.dart`,
    `lib/src/wasm/backend/native/interpreter/module.dart`,
    `lib/src/wasm/backend/native/interpreter/component.dart`, and
    `example/doom_cli.dart`.
  - Gate:
    - `dart run tool/doom_instantiate_profile.dart --json`
    - `dart test test/wasm_test.dart`
    - `dart test test/component_test.dart`
    - `dart test test/doom_smoke_test.dart --name "doom cli runtime matrix"`
    - `dart analyze`
  - Done when: the DOOM instantiate path reports per-phase duration/RSS, the
    module/component byte readers avoid `sublist` plus `fromList` double
    copies, section/body subreaders use bounded views while retained bytes are
    still copied, and the example no longer copies file-loaded wasm/IWAD bytes
    before handing them to APIs that already own their isolation boundary.
  - Result: a local JSON run reported `peak_rss_bytes=788201472` and
    `compile_module.rss_delta_bytes=442023936`. The minor byte-copy cleanup did
    not solve the peak, which confirms the next root-cause row is
    validation/predecode allocation.
- [x] `PERF-WASM-COMPILE-PREDECODE` - Compile-time validation/predecode memory.
  - Change: reduce temporary instruction/predecode allocation during
    `WebAssembly.compile` without skipping validation or hiding malformed
    modules.
  - Evidence: `tool/doom_instantiate_profile.dart`,
    `lib/src/wasm/backend/native/interpreter/validator.dart`,
    `lib/src/wasm/backend/native/interpreter/predecode.dart`, and
    `lib/src/wasm/backend/native/interpreter/instance.dart`.
  - Gate:
    - `dart run tool/doom_instantiate_profile.dart --compile-breakdown --json`
    - `dart run tool/doom_instantiate_profile.dart --json`
    - `dart test test/wasm_predecode_test.dart test/wasm_test.dart`
    - `dart analyze`
  - Progress:
    - `tool/doom_instantiate_profile.dart --compile-breakdown --json` now
      separates internal `decode_module` and `validate_module` phases and
      reports module size stats. A local run on the DOOM fixture reported
      `module_stats.instruction_bytes=335836` and
      `validate_module.rss_delta_bytes=438878208`, confirming validation stack
      analysis was the dominant compile-time RSS source before signature-list
      reuse.
    - `WasmPredecoder` now reuses shared instruction objects for pure
      no-immediate opcodes, guarded by `test/wasm_predecode_test.dart`. This is
      a small allocation reduction, not the completion of this row.
    - Validator and predecoder block/function signature paths now reuse
      immutable predecoded signature lists instead of repeatedly copying short
      lists. A later local compile-breakdown run reported
      `validate_module.rss_delta_bytes=296042496` and
      `validate_module.duration_ms=486`, while a full instantiate run still
      reported `compile_module.rss_delta_bytes=356057088`.
    - Simple stack and reference branch validation now avoid transient
      `br_table`, `br_on_non_null`, and branch-cast prefix lists. A local
      compile-breakdown run reported `validate_module.rss_delta_bytes=289144832`
      and `validate_module.duration_ms=472`; a full instantiate run still
      reported `compile_module.rss_delta_bytes=360955904`.
    - `WasmPredecoder` now reuses whitelisted small-immediate instruction
      objects for branch, local, global, `memory.size`, `memory.grow`, and
      `ref.func` opcodes that do not mutate `Instruction` runtime caches. The
      regression keeps `call` instructions unshared because the VM caches call
      targets on the instruction object. In the same local run, the
      compile-breakdown profile moved from
      `validate_module.rss_delta_bytes=312852480` and
      `validate_module.duration_ms=482` before this change to
      `validate_module.rss_delta_bytes=309346304` and
      `validate_module.duration_ms=479` after it. A full instantiate run
      reported `compile_module.rss_delta_bytes=326025216`, but the end-to-end
      peak is still noisy because `instantiate_module` reported
      `rss_delta_bytes=163037184` in that run.
    - Simple stack validation now precomputes the function's global index space
      once instead of rebuilding imported-global lists for every
      `global.get/set`. The public compile regression covers a module that
      indexes both an imported global and a local global. In the same local run,
      the compile-breakdown profile moved from
      `validate_module.rss_delta_bytes=306495488` and
      `validate_module.duration_ms=480` before this change to
      `validate_module.rss_delta_bytes=287162368` and
      `validate_module.duration_ms=482` after it. A full instantiate run
      reported `compile_module.rss_delta_bytes=325812224` and
      `instantiate_module.rss_delta_bytes=164364288`, so retained instantiate
      RSS still needs separate work.
    - Function validation now passes module-level table, tag, and global index
      views into simple stack validation instead of rebuilding them per
      function, and simple stack validation now builds parameter/local
      signatures directly without an intermediate local-signature list. The
      compile-breakdown RSS remains noisy across local runs
      (`validate_module.rss_delta_bytes=312213504`, then `293535744`, then
      `309870592`), but the same final full instantiate run reported
      `compile_module.rss_delta_bytes=285687808` and
      `instantiate_module.rss_delta_bytes=88293376`.
    - Validator signature classification now reads leading hex bytes without
      allocating `List<int>` or substring objects for reference/numeric/packed
      checks, while preserving full byte parsing for Canonical/GC ref
      signatures that need it. Repeated compile-breakdown runs reported
      `validate_module.rss_delta_bytes=132513792` and then `133611520`, with
      `validate_module.duration_ms=386` and then `396`. The matching full
      instantiate run reported `compile_module.rss_delta_bytes=132972544`, but
      `instantiate_module.rss_delta_bytes=212844544`, so the next peak has moved
      past compile validation.
    - Native `Module` now stores the `PredecodedFunction` list produced during
      validation, native instantiation reuses it, and
      `tool/doom_instantiate_profile.dart --instantiate-breakdown --json` can
      show internal instantiate phases. The breakdown confirmed
      `predecode_functions.rss_delta_bytes=180224`; repeated full profiles
      reported `compile_module.rss_delta_bytes=58081280` then `67747840`, and
      `instantiate_module.rss_delta_bytes=3981312` then `9879552`.
    - A final compile-breakdown gate reported
      `validate_module.rss_delta_bytes=84099072` and
      `validate_module.duration_ms=388`.
  - Done when: the profile shows a lower `compile_module.rss_delta_bytes` on
    DOOM-sized modules with stable repeated runs and no shifted peak into
    `instantiate_module`.
- [ ] `CM-VALIDATION-GAPS` - Component validation gaps that are deterministic
  and local.
  - Change: add validation tests before runtime wiring for remaining borrow,
    stream, future, and nested-shape rules.
  - Evidence: `test/component_test.dart`,
    `test/wasi_component_async_host_test.dart`.
  - Gate:
    - `dart test test/component_test.dart`
    - `dart test test/wasi_component_async_host_test.dart`
  - Done when: unsupported shapes fail during validation with structured
    diagnostics before host mutation.
- [ ] `P3-ASYNC-COPY-GAPS` - Canonical `stream.*` / `future.*` lowering beyond
  the current copy-buffer subset.
  - Change: wire validated shapes into the internal async host and component
    host before adding public P3 API claims.
  - Evidence: `lib/src/wasi/component/async_host.dart`,
    `test/wasi_component_host_test.dart`.
  - Gate: `dart test test/wasi_component_host_test.dart`; async/resource
    benchmark commands from the verification matrix.
  - Done when: the same shape has validation, memory copy,
    cancellation/drop behavior, waitable behavior when applicable, and
    benchmark coverage.
- [ ] `P2-P3-ADAPTERS` - Concrete Preview2/Preview3 adapter modules.
  - Change: grow `lib/src/wasi/preview2/` and `lib/src/wasi/preview3/`
    adapters over shared component primitives instead of extending Preview1
    host types.
  - Evidence: preview-specific host modules, owned-resource async lifecycle,
    memory-copy, pending-copy-event, and cancel-copy-event wrapper tests, and
    versioned-host tests.
  - Gate: `dart test test/wasi_component_versioned_host_test.dart` plus new
    adapter-specific tests.
  - Done when: a real versioned adapter can bind and execute the covered
    component path without constructing a mixed-version generic host manually.
- [x] `WIT-DOCUMENT-BOUNDARIES` - WIT package/interface/world boundary parser.
  - Scope: internal component-model input normalization only; no generated
    bindings and no public Preview2/Preview3 support claim.
  - Edit targets: `lib/src/wasi/component/wit_document.dart`,
    `test/wasi_component_wit_test.dart`, and this roadmap.
  - Red test: `dart test test/wasi_component_wit_test.dart` failed before the
    parser/model existed.
  - Implementation gate: `dart test test/wasi_component_wit_test.dart`;
    `dart analyze`.
  - Performance gate: N/A for the first parser boundary; add a benchmark before
    parsing generated or large WIT packages.
  - Done when: package, interface, world, import, and export boundaries are
    parsed into structured objects; duplicate names and unresolved local world
    references fail with line/column diagnostics that name the boundary.
  - Evidence update: the verification matrix gains the WIT parser evidence, but
    `WIT-INGESTION`, `SUPPORT-P2`, and `SUPPORT-P3` stay unchecked.
- [ ] `CM-VALUE-VALIDATION` - Async host value validation beyond primitive
  aliases.
  - Change: extend only when matching lowering/lifting support exists for the
    same composite shape.
  - Evidence: value-memory tests, async-host tests, component-host tests.
  - Gate:
    - `dart test test/wasi_component_value_memory_test.dart`
    - `dart test test/wasi_component_async_host_test.dart`
    - `dart test test/wasi_component_host_test.dart`
  - Done when: validated composite shapes can be lowered, lifted, copied, and
    rejected consistently across value-memory, async-host, and component-host
    tests.
- [ ] `WIT-INGESTION` - WIT/interface ingestion.
  - Change: add ingestion only after versioned host boundaries and resource
    ownership behavior are strong enough to bind generated worlds.
  - Evidence: future WIT fixtures and versioned host tests.
  - Gate: future WIT ingestion test suite plus component-host binding tests.
  - Done when: imported/generated worlds bind through Preview2/Preview3
    adapters and failures name the interface/world boundary.

## Completion Checklist

Full WASI 0.3 support must remain unclaimed until every row below is checked.
Checking a row requires the current command evidence to be added to that row or
to a linked checked child row in the same commit.

- [ ] `P3-VERSIONED-RUN`
  - Condition: real P3 components run through a versioned Preview3 host layer.
  - Gate: versioned Preview3 adapter tests plus component-host execution tests.
- [ ] `P3-RESOURCE-LIFETIME`
  - Condition: resource ownership, `own`, `borrow`, drop, stale-handle, and
    active-borrow behavior are covered by tests and benchmarks.
  - Gate: resource table, resource host, adapter, component-host, and benchmark
    gates.
- [ ] `P3-STREAM-FUTURE-SHAPES`
  - Condition: `stream<T>` and `future<T>` cover primitive, composite,
    owned-resource, dynamic string/list, cancellation, waitable, and
    backpressure behavior.
  - Gate: async-host, value-memory, component-host, waitable, and async
    benchmark gates.
- [ ] `P3-TASK-CONTEXT-THREAD`
  - Condition: async task/subtask/context/thread behavior is covered by
    executable component/versioned-host tests, not only direct helper calls.
  - Gate: task, subtask, context, thread, waitable-set, and versioned-host
    tests.
- [ ] `PUBLIC-API-DOCS`
  - Condition: public API and README wording match the implemented support
    matrix.
  - Gate: README snippet/command tests when snippets change plus support-gate
    review.
- [ ] `VERSION-GATES`
  - Condition: P1, P2, and P3 gates each have their own test command and do not
    rely on a narrower internal helper as proof.
  - Gate: separate Preview1, Preview2, and Preview3 command evidence in this
    document.
- [ ] `PERFORMANCE-GATES`
  - Condition: performance gates cover stream/future forwarding, memory copy,
    resource table borrow/drop, VFS descriptors, and heavy process runners.
  - Gate: current JSON outputs from the async, resource table, VFS, component,
    and heavy-runner benchmarks.
- [ ] `FULL-VERIFY`
  - Condition: a full verification run has current evidence.
  - Gate: `dart format .`, `dart analyze`, `dart test`, targeted browser/node
    checks when touched, and the relevant benchmark JSON outputs.
