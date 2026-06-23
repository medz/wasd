# Wasm and WASI Executable Roadmap

This repository is moving from limited Wasm plus WASI Preview 1 support toward
real, verified Wasm and WASI support across Preview 1, WASI 0.2, and WASI 0.3.
This document is the working architecture guide, execution queue, and evidence
ledger for that transition. A support claim is not done until the checklist row
names the runtime path, the proof files, the verification command, and the exact
condition for marking it complete.

Status date: 2026-06-23.

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
- Treat the `Current Execution Board` as the canonical next-action queue. When a
  touched ID also appears in the detailed backlog, verification matrix, or
  completion checklist, update those entries in the same commit so the roadmap
  stays mechanically auditable.

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

Checked rows keep the same shape, but the `Red test` and `Implementation gate`
must include the exact command evidence that was actually run. If a checked row
cannot name its command evidence, demote it back to unchecked or split it into a
new executable child row.

## Roadmap Audit Checklist

Use this checklist before committing roadmap changes. These checkboxes are a
process guard, not support progress.

- [ ] Every touched executable row has `Scope`, `Edit targets`, `Red test`,
  `Implementation gate`, `Performance gate`, `Done when`, `Evidence update`,
  and `Claim impact`.
- [ ] Every touched checked row names the focused command that failed or exposed
  the gap before the fix, plus the exact commands that passed after the fix.
- [ ] Every touched support gate names required rows, implementation commands,
  performance commands, the done condition, and the evidence update location.
- [ ] The current execution board, detailed backlog, verification matrix, and
  completion checklist agree for every touched ID.
- [ ] No public P1/P2/P3 support claim is inferred from an internal helper test;
  the version-specific gate remains unchecked until its row says otherwise.

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

- [x] `P1-OFFICIAL-FS-CONFORMANCE` - Drive official Preview1 filesystem
  failures to zero one checked child at a time.
  - Scope: native/browser shared Preview1 VFS and syscall behavior exercised by
    upstream `WebAssembly/wasi-testsuite` `wasm32-wasip1` command modules.
  - Edit targets: `test/wasi_test.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, native/browser syscall adapters
    under `lib/src/wasi/preview1/`, and the testsuite runner only when the
    selected failure proves a harness gap rather than a runtime gap.
  - Red test: each child row picked exactly one failing official module, added
    the smallest focused regression under `test/wasi_test.dart`, and confirmed
    the regression or official single-module run failed for the expected reason
    before the fix.
  - Implementation gate: focused `dart test test/wasi_test.dart --name ...`;
    matching `dart test -p chrome test/wasi_test.dart --name ...` when shared
    browser behavior is touched; the matching
    `dart tool/wasi_testsuite_preview1_runner.dart .../<case>.wasm`; then the
    upstream `./run-tests --runtime-adapter <wasd>/tool/wasi_testsuite_wasd_adapter.py`
    rerun with the new pass/fail delta recorded.
  - Performance gate: N/A for constant-time descriptor/syscall preflight rows;
    run `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` for
    directory traversal, readdir, path lookup, descriptor allocation, or any row
    that adds a repeated VFS hot path.
  - Checked child rows: `P1-FD-RENUMBER-TARGET-PREFLIGHT`,
    `P1-FD-CLOSE-PREOPEN`, `P1-PATH-OPEN-DIRFD-NOT-DIR`,
    `P1-DIRECTORY-NO-SEEK-RIGHT`, `P1-TRAILING-SLASH-PATH-MUTATIONS`,
    `P1-GUEST-PATH-CAPABILITY-BOUNDARY`, `P1-PATH-LINK-EDGE-SEMANTICS`,
    `P1-SYMLINK-NOFOLLOW-OPEN-LOOP`, and
    `P1-PATH-RENAME-DIRECTORY-TARGETS`, and
    `P1-PATH-OPEN-PREOPEN-DIRECTORY-RIGHTS`.
  - Done when: the official Preview1 command-module run reports zero Preview1
    failures with no unexpected Preview1 skips, and every previously failing
    module has a narrow checked child row with local and official evidence.
  - Evidence update: update this board, the detailed backlog, the verification
    matrix, and current baseline numbers in the same commit.
  - Claim impact: completes the official Preview1 command-module filesystem
    conformance gate for `SUPPORT-P1`; it does not complete `SUPPORT-P2` or
    `SUPPORT-P3`, and skipped Preview3 modules remain unsupported.

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
  - Checked child rows: `CM-CANONICAL-COPY-OPTION-PLACEMENT` covers invalid
    option placement for `stream.read`, `stream.write`, `future.read`, and
    `future.write` copy definitions;
    `CM-RESOURCE-REPRESENTATION-VALIDATION` covers resource representation
    validation for the currently valid `i32` representation and structured
    rejection of non-`i32` resource reps, including typed reference encodings;
    `CM-INSTANTIATION-IMPORT-MATCHING` covers known local child-component
    instantiation import name, missing argument, and sort matching checks.
  - Done when: the invalid component fails before host state is mutated and the
    diagnostic names the rejected shape or interface boundary.
  - Evidence update: record the failing shape and the exact command evidence.
  - Claim impact: reduces `SUPPORT-P2` and `SUPPORT-P3` validation risk; no
    support gate changes directly.
- [x] `P2-P3-ADAPTERS` - Bind one real Preview2/Preview3 adapter path over shared
  component primitives.
  - Scope: versioned component host adapters, not Preview1 imports.
  - Edit targets: `lib/src/wasi/preview2/`,
    `lib/src/wasi/preview3/`, `lib/src/wasi/component/`,
    `test/wasi_component_versioned_host_test.dart`, and adapter-specific tests.
  - Red test:
    `dart test test/wasi_component_versioned_host_test.dart --name "Preview2 and Preview3 wrappers execute primitive adapters"`
    failed before the fix because `WASIPreview2ComponentHost` and
    `WASIPreview3ComponentHost` did not expose `bindAdapters`.
  - Implementation gate:
    `dart test test/wasi_component_versioned_host_test.dart --name "Preview2 and Preview3 wrappers execute primitive adapters"`;
    `dart test test/wasi_component_versioned_host_test.dart`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_versioned_adapter_program_invoke.operations=8000` and
    `component_versioned_adapter_program_invoke.per_operation_us=0.192`;
    `dart analyze`.
  - Done when: one real P2/P3 component path executes through the versioned host
    without leaking Preview1 imports or bypassing shared component ownership.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
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
  - Checked child rows: `P3-ASYNC-ERROR-CONTEXT-COPY` covers the canonical memory
    copy path for `stream<error-context>` and `future<error-context>`;
    `P3-ASYNC-CHAR-SCALAR` covers Unicode-scalar validation for `future<char>`
    before host values can enter canonical memory copy;
    `P3-OPTION-STREAM-SELECTOR-VALIDATION` covers decoded
    `stream<option<u32>>` copy plus conflicting option selector rejection before
    enqueue.
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
  - Checked child rows: `CM-VARIANT-PAYLOAD-STORE-VALIDATION` covers
    payload-bearing and payloadless variant store validation before canonical
    memory writes, with adapter variant/option/result benchmarks still passing;
    `P3-OPTION-STREAM-SELECTOR-VALIDATION` covers consistent variant, option,
    and result case selectors in the shared value-memory codec before P3 async
    host writes can mutate endpoints.
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
    tests. Executable adapter increments also update
    `tool/wasi_resource_table_benchmark.dart`.
  - Red test: add an imported/generated world that parses but cannot bind through
    the versioned host.
  - Implementation gate: WIT ingestion tests plus the matching component-host
    binding tests.
  - Performance gate: N/A for parsing-only increments; executable adapter
    increments must run
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    and record the relevant metric.
  - Checked child rows: `WIT-WORLD-VERSION-PROFILE-INGESTION` covers annotated
    Preview3 WIT function/import/include parsing plus Preview2/Preview3
    version-profile ingestion before generated adapter binding;
    `WIT-WORLD-PRIMITIVE-ADAPTER-BINDING` covers local synchronous primitive WIT
    import/export functions bound to executable Preview2/Preview3 adapter
    callbacks; `WIT-WORLD-COMPOSITE-ADAPTER-BINDING` covers synchronous
    `option<T>` and `result<T, E>` WIT adapter value trees with selector and
    payload validation; `WIT-WORLD-LIST-TUPLE-ADAPTER-BINDING` covers
    synchronous `list<T>` and `tuple<T...>` WIT adapter value trees;
    `WIT-WORLD-RECORD-ADAPTER-BINDING` covers local named WIT `record`
    declarations referenced by synchronous adapter signatures.
  - Done when: imported/generated worlds bind through Preview2/Preview3 adapters
    and failures name the interface/world boundary.
  - Evidence update: record WIT files, versioned adapter tests, and command
    evidence.
  - Claim impact: required before `SUPPORT-P2` or `SUPPORT-P3` can be checked.

### Recently Checked

- [x] `WIT-WORLD-RECORD-ADAPTER-BINDING` - Execute local named WIT record values
  through versioned adapter callbacks.
  - Scope: local WIT interfaces imported by a selected world, limited to
    synchronous signatures that reference records declared in the same
    interface and whose fields use already supported primitive, list, tuple,
    option, or result payloads.
  - Edit targets: `lib/src/wasi/component/wit_document.dart`,
    `lib/src/wasi/component/wit_adapter.dart`,
    `test/wasi_component_wit_test.dart`,
    `test/wasi_component_versioned_host_test.dart`,
    `tool/wasi_resource_table_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_wit_test.dart --name "local record" --reporter=expanded`
    failed before the fix because parsed interfaces exposed no record
    declarations;
    `dart test test/wasi_component_versioned_host_test.dart --name "named WIT record" --reporter=expanded`
    failed before the fix because named record adapter signatures were
    unsupported and `canBindAdapters` stayed false.
  - Implementation gate:
    `dart test test/wasi_component_wit_test.dart --name "local record" --reporter=expanded`;
    `dart test test/wasi_component_versioned_host_test.dart --name "named WIT record" --reporter=expanded`;
    `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_wit_record_adapter_program_invoke.operations=2000`
    and `component_wit_record_adapter_program_invoke.per_operation_us=0.6135`.
  - Done when: parsed local WIT `record` declarations are retained on their
    interface, same-interface record names resolve during adapter signature
    parsing, valid record arguments/results execute through Preview2 and
    Preview3 world adapter plans, field count or field-kind mismatches fail at
    the adapter boundary, recursive records remain unsupported with a
    diagnostic instead of unbounded parsing, and async WIT functions remain
    outside the synchronous adapter path.
  - Evidence update: this checked row plus `WIT-INGESTION`, the verification
    matrix, detailed backlog, and resource benchmark metric.
  - Claim impact: advances `WIT-INGESTION` and concrete `SUPPORT-P2`/`SUPPORT-P3`
    adapter evidence; does not complete generated multi-package binding,
    cross-interface named type resolution, variant/resource WIT adapter
    execution, async WIT adapters, `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `WIT-WORLD-LIST-TUPLE-ADAPTER-BINDING` - Execute synchronous WIT
  list/tuple values through versioned adapter callbacks.
  - Scope: local WIT interfaces imported by a selected world, limited to
    synchronous `list<T>` and `tuple<T...>` parameters/results over already
    supported primitive payloads and fixed Preview2/Preview3 version profiles.
  - Edit targets: `lib/src/wasi/component/wit_adapter.dart`,
    `test/wasi_component_versioned_host_test.dart`,
    `tool/wasi_resource_table_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_versioned_host_test.dart --name "list and tuple WIT values" --reporter=expanded`
    failed before the fix because WIT adapter signatures containing
    `tuple<string, u32>` and `list<tuple<string, string>>` were unsupported and
    `canBindAdapters` stayed false.
  - Implementation gate:
    `dart test test/wasi_component_versioned_host_test.dart --name "list and tuple WIT values" --reporter=expanded`;
    `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_wit_list_tuple_adapter_program_invoke.operations=2000`
    and `component_wit_list_tuple_adapter_program_invoke.per_operation_us=1.585`.
  - Done when: parsed WIT `list<T>` and `tuple<T...>` signatures bind through
    Preview2 and Preview3 world adapter plans, list elements and tuple fields
    recursively reuse `WasmComponentValueData`, tuple arity mismatches fail
    before host callbacks run, invalid nested list/tuple payload kinds fail at
    the adapter boundary, and async WIT functions remain outside the
    synchronous adapter path.
  - Evidence update: this checked row plus `WIT-INGESTION`, the verification
    matrix, detailed backlog, and resource benchmark metric.
  - Claim impact: advances `WIT-INGESTION` and concrete `SUPPORT-P2`/`SUPPORT-P3`
    adapter evidence; does not complete generated multi-package binding,
    cross-interface record resolution, variant/resource WIT adapter execution,
    async WIT adapters, `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `WIT-WORLD-COMPOSITE-ADAPTER-BINDING` - Execute synchronous composite WIT
  values through versioned adapter callbacks.
  - Scope: local WIT interfaces imported by a selected world, limited to
    synchronous `option<T>` and `result<T, E>` parameters/results over already
    supported primitive payloads and fixed Preview2/Preview3 version profiles.
  - Edit targets: `lib/src/wasi/component/wit_adapter.dart`,
    `test/wasi_component_versioned_host_test.dart`,
    `tool/wasi_resource_table_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_versioned_host_test.dart --name "composite WIT values" --reporter=expanded`
    failed before the fix because WIT adapter signatures containing
    `option<u32>` and `result<u32, string>` were unsupported and
    `canBindAdapters` stayed false.
  - Implementation gate:
    `dart test test/wasi_component_versioned_host_test.dart --name "composite WIT values" --reporter=expanded`;
    `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_wit_composite_adapter_program_invoke.operations=4000`
    and `component_wit_composite_adapter_program_invoke.per_operation_us=0.712`.
  - Done when: parsed WIT `option<T>` and `result<T, E>` signatures bind through
    Preview2 and Preview3 world adapter plans, nested primitive payloads reuse
    `WasmComponentValueData`, invalid option/result selectors fail before host
    callbacks run, invalid payload kinds fail before callbacks run, and async
    WIT functions remain outside the synchronous adapter path.
  - Evidence update: this checked row plus `WIT-INGESTION`, the verification
    matrix, detailed backlog, and resource benchmark metric.
  - Claim impact: advances `WIT-INGESTION` and concrete `SUPPORT-P2`/`SUPPORT-P3`
    adapter evidence; does not complete generated multi-package binding,
    async WIT adapters, `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `WIT-WORLD-PRIMITIVE-ADAPTER-BINDING` - Execute local primitive WIT world
  functions through versioned adapter callbacks.
  - Scope: local WIT interfaces imported/exported by a selected world, limited
    to synchronous primitive parameters/results and fixed Preview2/Preview3
    version profiles.
  - Edit targets: `lib/src/wasi/component/versioned_host.dart`,
    `lib/src/wasi/component/wit_adapter.dart`,
    `test/wasi_component_versioned_host_test.dart`,
    `tool/wasi_resource_table_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_versioned_host_test.dart --name "WIT world adapters" --reporter=expanded`
    failed before the fix because `WASIComponentVersionedWitWorldPlan` had no
    `canBindAdapters`, `functions`, or `bindAdapters` API.
  - Implementation gate:
    `dart test test/wasi_component_versioned_host_test.dart --name "WIT world adapters" --reporter=expanded`;
    `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_wit_adapter_program_invoke.operations=4000` and
    `component_wit_adapter_program_invoke.per_operation_us=0.22325`.
  - Done when: a parsed WIT world expands local import/export interface
    functions once during planning, Preview2 and Preview3 bind the resulting
    synchronous primitive adapters to callbacks, import/export invocation
    validates WIT primitive values before calling callbacks, and Preview3 async
    WIT worlds remain ingestible but not falsely bindable as synchronous
    adapters.
  - Evidence update: this checked row plus `WIT-INGESTION`, the verification
    matrix, detailed backlog, and resource benchmark metric.
  - Claim impact: advances `WIT-INGESTION` and concrete `SUPPORT-P2`/`SUPPORT-P3`
    adapter evidence; does not complete generated multi-package binding,
    async WIT adapters, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `WIT-WORLD-VERSION-PROFILE-INGESTION` - Feed parsed WIT worlds into
  Preview2/Preview3 version profiles.
  - Scope: WIT document ingestion for package annotations, interface function
    boundaries including nested resource methods, world imports/exports/includes,
    and Preview3 async surface detection before component adapter generation.
  - Edit targets: `lib/src/wasi/component/wit_document.dart`,
    `lib/src/wasi/component/versioned_host.dart`,
    `lib/src/wasi/preview2/component_host.dart`,
    `lib/src/wasi/preview3/component_host.dart`,
    `test/wasi_component_wit_test.dart`,
    `test/wasi_component_versioned_host_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_wit_test.dart test/wasi_component_versioned_host_test.dart --name "parses annotated|ingest WIT worlds" --reporter=expanded`
    failed before the fix because WIT interfaces had no parsed function
    boundaries, worlds had no `include` items, and fixed P2/P3 wrappers had no
    `prepareWitWorld` path.
  - Implementation gate:
    `dart test test/wasi_component_wit_test.dart test/wasi_component_versioned_host_test.dart --name "parses annotated|ingest WIT worlds" --reporter=expanded`;
    `dart test test/wasi_component_wit_test.dart test/wasi_component_versioned_host_test.dart test/wasi_component_host_test.dart --reporter=compact`.
  - Performance gate: N/A; this only extends declaration-boundary parsing and
    version-profile preflight. Add a parser benchmark before ingesting generated
    multi-package WIT graphs. Supplemental
    `dart run tool/component_benchmark.dart --json > .dart_tool/component_benchmark_after_wit_ingestion.json`
    reported component decode at `57.325us/iter` and validation at
    `112.59us/iter`.
  - Done when: annotated Preview3 WIT snippets parse `async func`,
    `stream<T>`, `future<T>`, nested resource methods, and `include`
    boundaries; Preview2 rejects those P3 async/0.3 targets through version
    errors; Preview3 accepts the same WIT world for adapter binding preflight.
  - Evidence update: this checked row plus `WIT-INGESTION`, verification
    matrix, and detailed backlog.
  - Claim impact: moves WIT ingestion into the P2/P3 versioned host boundary;
    does not complete generated world binding, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-PATH-OPEN-PREOPEN-DIRECTORY-RIGHTS` - Match Preview1
  `path_open` preopen directory read/write rights semantics.
  - Scope: native/browser shared Preview1 VFS `path_open` behavior when a
    preopened directory is opened through `O_DIRECTORY` with empty, read-only,
    full directory, or file read/write rights.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open rejects directory read-write" --reporter=expanded`
    failed before the fix with `Expected: <31> Actual: <0>` because
    `O_DIRECTORY` plus pure `FD_READ|FD_WRITE` rights opened the directory
    successfully instead of returning `ISDIR`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open rejects directory read-write" --reporter=compact`;
    `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_open_preopen.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_open_preopen.json --disable-colors`
    reported `PASS: 72 tests passed (41 skipped)`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_path_open_preopen.json`
    reported `path_open_close` at `1.398us/op` baseline, `0.775us/op`
    directory-heavy, `0.703us/op` descriptor-heavy, and `0.903us/op`
    socket-heavy. The fix adds a constant-time rights mask check only on the
    directory-open path.
  - Done when: `O_DIRECTORY` opens of preopen directories with empty,
    read-only, or full directory rights still succeed; pure
    `FD_READ|FD_WRITE` file rights return `ISDIR`; and
    `path_open_preopen.wasm` passes.
  - Evidence update: this checked row plus `SUPPORT-P1`, verification matrix,
    current baseline, and ordered execution queue.
  - Claim impact: closes the final official Preview1 filesystem failure; P2/P3
    remain unsupported and skipped Preview3 modules are not support evidence.
- [x] `P1-PATH-RENAME-DIRECTORY-TARGETS` - Match Preview1 directory rename
  target replacement semantics.
  - Scope: native/browser shared Preview1 VFS `path_rename` behavior when the
    source is a directory and the target is missing, an existing empty
    directory, an existing non-empty directory, or a non-directory node.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_rename replaces empty directories" --reporter=compact`
    failed before the fix with `Expected: <0> Actual: <20>` because an
    existing empty target directory returned `EXIST`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_rename replaces empty directories" --reporter=compact`;
    `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_rename.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_rename.json --disable-colors`
    reported `1/72` Preview1 failures after the fix, down from `2/72`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_path_rename.json`
    reported mutation cost at `8.854us/op` baseline, `12.546us/op`
    directory-heavy, `5.875us/op` descriptor-heavy, and `5.524us/op`
    socket-heavy; `path_open_close` stayed at `1.311us/op`, `0.717us/op`,
    `0.714us/op`, and `0.732us/op` for the same distributions.
  - Done when: directory rename replaces empty target directories, rejects
    non-empty target directories with `NOTEMPTY`, rejects non-directory targets
    with `NOTDIR`, and `path_rename.wasm` passes.
  - Evidence update: this checked row plus `SUPPORT-P1`, verification matrix,
    current baseline, and ordered execution queue.
  - Claim impact: closes one official Preview1 filesystem failure for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-SYMLINK-NOFOLLOW-OPEN-LOOP` - Preview1 `path_open` no-follow
  symlink opens report `LOOP` instead of missing paths.
  - Scope: native/browser shared Preview1 `path_open` and VFS open-result
    semantics for symlink nodes when `LOOKUPFLAGS_SYMLINK_FOLLOW` is absent.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open rejects nofollow symlinks" --reporter=compact`
    failed before the fix because no-follow opening a symlink returned
    `NOENT` instead of `LOOP`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open rejects nofollow symlinks" --reporter=compact`;
    `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/nofollow_errors.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/dangling_symlink.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/symlink_loop.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_symlink_nofollow.json --disable-colors`
    reported `2/72` Preview1 failures after the fix, down from `5/72`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_symlink_nofollow.json`
    reported `path_open_close` at `1.422us/op` baseline, `0.7265us/op`
    directory-heavy, `0.708us/op` descriptor-heavy, and `0.76525us/op`
    socket-heavy. The implementation adds one symlink map lookup to the
    existing `openPath` decision tree.
  - Done when: no-follow `path_open` on directory, dangling, and
    self-referential symlinks returns `LOOP`; symlink-follow opening of a
    symlinked directory still succeeds; and `nofollow_errors.wasm`,
    `dangling_symlink.wasm`, and `symlink_loop.wasm` pass.
  - Evidence update: this checked row plus `SUPPORT-P1`, verification matrix,
    current baseline, and ordered execution queue.
  - Claim impact: closes three official Preview1 testsuite failures for
    `SUPPORT-P1`; it does not complete full P1/P2/P3 support.

- [x] `P1-PATH-LINK-EDGE-SEMANTICS` - Preview1 `path_link` matches
  official hard-link and symlink edge semantics.
  - Scope: native/browser shared Preview1 `path_link`, VFS hard links for
    regular files and symbolic links, directory-source errno, trailing-slash
    target errno, and symlink-follow flag rejection.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_link handles directory" --reporter=compact`
    failed before the fix because linking a directory source returned
    `ISDIR` instead of `PERM`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_link handles directory" --reporter=compact`;
    `dart test test/wasi_test.dart --name "path_symlink and path_readlink preserve" --reporter=compact`;
    `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_link.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_link.json --disable-colors`
    reported `5/72` Preview1 failures after the fix, down from `6/72`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_path_link.json`
    reported `mutations_benchmark` at `7.893571428571429us/op` baseline,
    `9.092857142857143us/op` directory-heavy, `5.385us/op`
    descriptor-heavy, and `5.177142857142857us/op` socket-heavy. The
    implementation keeps hard-link creation to map insertion plus one local
    directory-entry rebuild; it does not add path-wide scans.
  - Done when: `path_link` rejects `LOOKUPFLAGS_SYMLINK_FOLLOW` with
    `INVAL`, hard-links symlink nodes without following them, returns `PERM`
    for directory sources, preserves `NOENT` for missing trailing-slash
    targets, updates link counts for linked symlinks, and the official
    `path_link.wasm` module passes.
  - Evidence update: this checked row plus `SUPPORT-P1`, verification matrix,
    current baseline, and ordered execution queue.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; it does not complete full P1/P2/P3 support.

- [x] `P1-GUEST-PATH-CAPABILITY-BOUNDARY` - guest path decoding preserves
  Preview1 sandbox, NUL, and trailing-slash open semantics.
  - Scope: native/browser shared Preview1 guest path decode for path syscalls,
    `path_open` trailing slash behavior, and absolute `path_symlink` targets.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open rejects absolute, escaping, nul, and file-slash paths" --reporter=expanded`
    failed before the fix because `path_open("/dir/nested/file")` returned
    success instead of `NOTCAPABLE`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open rejects absolute, escaping, nul, and file-slash paths" --reporter=expanded`;
    `dart test -p chrome test/wasi_test.dart --name "path_open rejects absolute, escaping, nul, and file-slash paths" --reporter=expanded`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/interesting_paths.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/symlink_create.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_decode.json --disable-colors`
    reported `6/72` Preview1 failures after the fix, down from `8/72`;
    `dart test test/wasi_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `path_open_close` at `1.3065us/op` baseline, `0.6965us/op`
    directory-heavy, `0.692us/op` descriptor-heavy, and `0.697625us/op`
    socket-heavy. The decode path computes absolute, escaping, NUL, and
    trailing-separator metadata once and passes a small result object through
    the syscall boundary.
  - Done when: absolute and preopen-escaping guest paths return
    `NOTCAPABLE`, paths containing NUL return `INVAL`, opening a regular file
    with a trailing slash returns `NOTDIR` without writing the output fd,
    opening a directory with trailing slashes succeeds, and absolute symlink
    targets are rejected.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and current baseline.
  - Claim impact: closes two official Preview1 testsuite failures
    (`interesting_paths` and `symlink_create`) for `SUPPORT-P1`; it does not
    complete `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-TRAILING-SLASH-PATH-MUTATIONS` - path mutation syscalls preserve
  trailing-slash errno semantics.
  - Scope: native/browser shared Preview1 VFS path mutation behavior for
    `path_unlink_file` and `path_symlink` link paths.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path mutation preserves trailing slash errors" --reporter=expanded`
    failed before the fix because `path_unlink_file("file.txt/")` returned
    success and removed the file instead of returning `NOTDIR`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path mutation preserves trailing slash errors" --reporter=expanded`;
    `dart test test/wasi_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/unlink_file_trailing_slashes.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_symlink_trailing_slashes.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_trailing_slash.json --disable-colors`
    reported `8/72` Preview1 failures after the fix, down from `10/72`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `mutations_benchmark` at `9.469285714285714us/op` baseline,
    `13.462857142857143us/op` directory-heavy,
    `6.211428571428572us/op` descriptor-heavy, and
    `5.648571428571429us/op` socket-heavy. The implementation carries a single
    decoded trailing-separator bit from the syscall boundary into mutation
    helpers instead of reparsing or adding traversal loops.
  - Done when: `path_unlink_file` leaves regular files intact when the guest
    path ends in `/`, reports `ISDIR` for directory paths ending in `/`, and
    `path_symlink` distinguishes trailing-slash missing, file, symlink, and
    directory link paths with Preview1 errno values that match the official
    modules.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and current baseline.
  - Claim impact: closes two official Preview1 testsuite failures
    (`unlink_file_trailing_slashes` and `path_symlink_trailing_slashes`) for
    `SUPPORT-P1`; it does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P1-NODE-METADATA-TIMESTAMPS` - new virtual files, directories, and
  symlinks start with non-zero filestat timestamps.
  - Scope: native/browser shared Preview1 VFS metadata creation and
    `fd_filestat_get`/`path_filestat_get` timestamp reporting.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "new virtual nodes start with non-zero filestat timestamps" --reporter=expanded`
    failed before the fix because freshly snapshotted files reported
    `atim == 0` and `mtim == 0`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "new virtual nodes start with non-zero filestat timestamps" --reporter=expanded`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_filestat.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/symlink_filestat.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fd_filestat_set.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_filestat_timestamps.json --disable-colors`
    reported `10/72` Preview1 failures after the fix, down from `13/72`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `readdir` at `0.489us/op` baseline, `0.3215us/op` directory-heavy,
    `0.276us/op` descriptor-heavy, and `0.30625us/op` socket-heavy. Metadata
    uses a wall-clock seed plus monotonic virtual increments, avoiding
    per-node system clock calls while keeping timestamps non-zero.
  - Done when: every newly created VFS node reports non-zero access and
    modification timestamps through filestat, explicit timestamp setters still
    persist exact values, and official `path_filestat`, `symlink_filestat`, and
    `fd_filestat_set` modules pass.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and current baseline.
  - Claim impact: closes three official Preview1 testsuite failures
    (`path_filestat`, `symlink_filestat`, and `fd_filestat_set`) for
    `SUPPORT-P1`; it does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P1-FILE-IDENTITY-AND-READDIR-PAGING` - virtual files, directories, hard
  links, `filestat`, and `fd_readdir` share stable device/inode identity and
  keep paged directory reads non-EOF while entries remain.
  - Scope: native/browser shared Preview1 VFS metadata, directory-entry cache,
    `fd_filestat_get`, `path_filestat_get`, hard-link link counts, and
    `fd_readdir` buffer pagination.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/common/fd_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red tests:
    `dart test test/wasi_test.dart --name "filestat and readdir report stable virtual node identities" --reporter=expanded`
    failed before the fix because `fd_filestat_get` reported inode `0`;
    `dart test test/wasi_test.dart --name "fd_readdir keeps buffer full while directory entries remain" --reporter=expanded`
    failed before the fix with `8` entries instead of `102`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "filestat and readdir report stable virtual node identities" --reporter=expanded`;
    `dart test test/wasi_test.dart --name "fd_readdir keeps buffer full while directory entries remain" --reporter=expanded`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/stat-dev-ino.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/fdopendir-with-access.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fd_readdir.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_inode_readdir.json --disable-colors`
    reported `13/72` Preview1 failures after the fix, down from `16/72`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `readdir` at `0.4415us/op` baseline, `0.3085us/op` directory-heavy,
    `0.297us/op` descriptor-heavy, and `0.292375us/op` socket-heavy; inode
    lookup is cached into directory entries instead of performed per
    `fd_readdir` write.
  - Done when: `filestat.dev` is stable and non-zero inside the VFS,
    distinct files have distinct `filestat.ino`, hard links share `ino` and
    link count, `fd_readdir.d_ino` matches `filestat.ino`, and partial buffers
    only signal EOF when no entries remain.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and current baseline.
  - Claim impact: closes three official Preview1 testsuite failures
    (`stat-dev-ino`, `fdopendir-with-access`, and `fd_readdir`) for
    `SUPPORT-P1`; it does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P1-DIRECTORY-NO-SEEK-RIGHT` - directory descriptors do not receive
  `FD_SEEK` in base rights.
  - Scope: native/browser shared Preview1 directory descriptor rights exposed by
    `path_open`, `fd_fdstat_get`, and `fd_seek`.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open does not grant fd_seek rights to directories" --reporter=compact`
    failed before the fix because an opened directory fdstat still included
    `FD_SEEK` in `fs_rights_base`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open does not grant fd_seek rights to directories" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "path_open does not grant fd_seek rights to directories" --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/directory_seek.wasm`;
    upstream `wasi-testsuite` rerun reported `16/72` Preview1 failures after
    this change, down from `17/72`.
  - Performance gate: N/A; this masks a constant directory base-right bit at
    descriptor construction time and does not affect path lookup or fd IO loops.
  - Done when: directory fdstat no longer exposes `FD_SEEK`, `fd_seek` on that
    descriptor returns `ENOTCAPABLE` without writing the output offset, and
    directory inheriting rights still flow to child opens.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and current baseline.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; it does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P1-PATH-OPEN-DIRFD-NOT-DIR` - `path_open` rejects non-directory base
  descriptors as `NOTDIR`.
  - Scope: native/browser shared Preview1 path syscall descriptor preflight for
    directory-base fds.
  - Edit targets: `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open rejects file descriptors as directory bases" --reporter=compact`
    failed before the fix because a live regular-file descriptor used as
    `path_open`'s `dirfd` returned `BADF` instead of `NOTDIR`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open rejects file descriptors as directory bases" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "path_open rejects file descriptors as directory bases" --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_open_dirfd_not_dir.wasm`;
    upstream `wasi-testsuite` rerun reported `17/72` Preview1 failures after
    this change, down from `18/72`.
  - Performance gate: N/A; this is a constant-time descriptor-kind preflight
    and does not add directory traversal or path lookup work.
  - Done when: missing fds still return `BADF`, open directory/preopen fds
    continue through the normal path flow, live non-directory descriptors return
    `NOTDIR`, and failed `path_open` leaves the output fd pointer unchanged.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and current baseline.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; it does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P1-FD-CLOSE-PREOPEN` - `fd_close` closes preopen directory
  descriptors without closing already opened child descriptors.
  - Scope: native/browser shared Preview1 descriptor table semantics for
    preopen directory descriptors.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "fd_close closes preopen descriptors without closing opened directories" --reporter=compact`
    failed before the fix because `fd_close(3)` returned `BADF` for a configured
    preopen descriptor after a child directory had been opened.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd_close closes preopen descriptors without closing opened directories" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "fd_close closes preopen descriptors without closing opened directories" --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/close_preopen.wasm`;
    upstream `wasi-testsuite` rerun reported `18/72` Preview1 failures after
    this change, down from `19/72`.
  - Performance gate: N/A; this replaces duplicated descriptor cleanup branches
    with one constant-time `_hasDescriptor`/`_closeDescriptor` path.
  - Done when: `fd_close` succeeds for a live preopen fd, later preopen metadata
    queries for that fd return `BADF`, and a directory fd opened from that
    preopen remains usable as `FILETYPE_DIRECTORY`.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and current baseline.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; it does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P1-FD-RENUMBER-TARGET-PREFLIGHT` - `fd_renumber` rejects invalid
  destination descriptors before moving the source descriptor.
  - Scope: native/browser shared Preview1 descriptor table semantics for
    `fd_renumber(from, to)`.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "fd_renumber" --reporter=compact`
    previously encoded the wrong behavior by allowing a virtual file descriptor
    to renumber into a closed destination fd.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd_renumber" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "fd_renumber" --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/renumber.wasm`;
    upstream `wasi-testsuite` rerun reported `19/72` Preview1 failures after
    this change, down from `20/72`.
  - Performance gate: N/A; this adds one descriptor-table preflight and does not
    touch fd read/write hot loops.
  - Done when: invalid negative descriptors still return `EINVAL`, missing
    source descriptors return `BADF`, `from == to` for an open descriptor remains
    a no-op success, missing destination descriptors return `BADF`, and the
    source descriptor remains usable after that failure.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and current baseline.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; it does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P1-OFFICIAL-TESTSUITE-ADAPTER` - wasd can be invoked by the official
  `wasi-testsuite` runner for Preview1 command modules.
  - Scope: external conformance execution entrypoint for `wasm32-wasip1`
    `wasi:cli/command` tests, not a new public support claim.
  - Edit targets: `tool/wasi_testsuite_preview1_runner.dart`,
    `tool/wasi_testsuite_wasd_adapter.py`, `test/wasi_testsuite_runner_test.dart`,
    `test/support/wasm_fixtures.dart`, and this roadmap.
  - Red test:
    before this row, the repository had no `wasi-testsuite` runtime adapter and
    no subprocess runner that accepted testsuite-style `--env`, `--dir
    HOST::GUEST`, module path, and argv inputs for wasd.
  - Implementation gate:
    `dart test test/wasi_testsuite_runner_test.dart --reporter=compact`;
    `dart run tool/wasi_testsuite_preview1_runner.dart --version`;
    `python3 -m py_compile tool/wasi_testsuite_wasd_adapter.py`.
  - Performance gate: N/A; this adds a conformance subprocess entrypoint and
    host-root snapshot setup, not a runtime hot path.
  - Done when: the adapter reports only the actually supported
    `wasm32-wasip1` / `wasi:cli/command` target, computes argv for the Dart
    runner, the runner executes a real WASI command module that opens and reads
    a snapshotted preopen file through `path_open`/`fd_read`, and returns its
    `proc_exit` code.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and current baseline.
  - Claim impact: creates an official Preview1 conformance gate for
    `SUPPORT-P1`; it does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`, and the adapter intentionally does not claim Preview3.
- [x] `CM-INSTANTIATION-IMPORT-MATCHING` - Component instantiation arguments
  are matched against known local child component imports before runtime
  planning.
  - Scope: component-model validation for `instantiate` expressions that target
    a locally decoded child component.
  - Edit targets: `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments" --reporter=compact`
    failed before the fix because a child component importing `"need"`
    accepted an instantiation argument named `"other"` with no missing-import
    diagnostic.
  - Implementation gate:
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments" --reporter=compact`;
    `dart test test/component_test.dart --reporter=compact`;
    `dart test test/wasi_component_host_test.dart test/wasi_component_versioned_host_test.dart --reporter=compact`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/component_benchmark.dart --json` reported
    `decode.per_iteration_us=59.835` and `validate.per_iteration_us=122.87`.
  - Done when: known local child component instantiation rejects unknown
    argument names, missing required imports, and wrong argument sort before
    component host planning or adapter binding can observe the invalid shape.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and current baseline.
  - Claim impact: reduces `CM-VALIDATION-GAPS` and Preview2/Preview3 adapter
    interface risk; does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P3-OPTION-STREAM-SELECTOR-VALIDATION` - Canonical
  variant/option/result selectors are internally consistent before value-memory
  writes or P3 async stream enqueues.
  - Scope: shared Canonical ABI value-memory selector resolution plus decoded
    `stream<option<u32>>` memory-copy execution through the Preview3 async host.
  - Edit targets: `lib/src/wasi/component/value_memory.dart`,
    `test/wasi_component_value_memory_test.dart`,
    `test/wasi_component_async_host_test.dart`,
    `tool/wasi_component_async_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_value_memory_test.dart test/wasi_component_async_host_test.dart --name "rejects conflicting variant case selectors before writing memory|rejects conflicting option stream value selectors" --reporter=compact`
    failed before the fix because the variant store returned successfully when
    `index` and `label` named different cases, and the async `stream.write`
    accepted an option value whose `index` and `isSome` disagreed.
  - Implementation gate:
    `dart test test/wasi_component_value_memory_test.dart test/wasi_component_async_host_test.dart --name "rejects conflicting variant case selectors before writing memory|rejects conflicting option stream value selectors" --reporter=compact`;
    broader value-memory, async-host, component-host, and versioned-host suites
    must pass before commit.
  - Performance gate:
    `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`
    now reports `stream_option_memory_copy.operations=64000` and
    `stream_option_memory_copy.per_operation_us=0.128375`.
  - Done when: conflicting variant labels/indexes and option/result booleans
    throw before guest-memory writes or async endpoint mutation, valid decoded
    `stream<option<u32>>` still round-trips through canonical memory, and the
    async benchmark includes an option stream copy metric.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and benchmark metric.
  - Claim impact: contributes to `P3-ASYNC-COPY-GAPS`,
    `CM-VALUE-VALIDATION`, `SUPPORT-P2`, and `SUPPORT-P3`; it does not complete
    `SUPPORT-P1`/`SUPPORT-P2`/`SUPPORT-P3` or broader component value coverage.
- [x] `P3-FLAGS-STREAM-COPY-VALIDATION` - decoded `stream<flags>` values copy
  through canonical memory and duplicate host-side flag labels fail before
  enqueue or memory writes.
  - Scope: Preview3 async stream copy over shared value-memory flags layout,
    including host-side value validation before stream mutation.
  - Edit targets: `lib/src/wasi/component/value_memory.dart`,
    `test/wasi_component_value_memory_test.dart`,
    `test/wasi_component_async_host_test.dart`,
    `tool/wasi_component_async_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_value_memory_test.dart test/wasi_component_async_host_test.dart --name "rejects duplicate flag labels before writing memory|copies decoded flags stream values through canonical memory" --reporter=compact`
    failed before the fix because duplicate labels were silently folded into a
    single flag bit and the async stream write returned success.
  - Implementation gate:
    `dart test test/wasi_component_value_memory_test.dart --reporter=compact`;
    `dart test test/wasi_component_async_host_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`
    now reports `stream_flags_memory_copy.operations=64000` and
    `stream_flags_memory_copy.per_operation_us=0.103828125`.
  - Done when: canonical memory copy round-trips decoded `stream<flags>`
    values, duplicate host-side flag labels throw before writes/enqueues, and
    the async benchmark includes a flags copy metric.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and benchmark metric.
  - Claim impact: contributes to `P3-ASYNC-COPY-GAPS`,
    `CM-VALUE-VALIDATION`, and `SUPPORT-P3`; it does not complete
    `SUPPORT-P1`/`SUPPORT-P2`/`SUPPORT-P3` or broader P3 async copy coverage.
- [x] `CM-TASK-RETURN-BORROW-VALIDATION` - canonical `task.return` result
  types reject borrowed values during component validation.
  - Scope: Component Model validation for Preview3 task-return boundaries before
    task host binding, async lowering, or value-memory mutation can observe an
    invalid borrowed result.
  - Edit targets: `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart --name "reports task.return result types containing borrow" --reporter=compact`
    failed before the fix because `task.return` accepted a result type that
    resolved to `borrow<resource>` with no validation diagnostic.
  - Implementation gate:
    `dart test test/component_test.dart --name "reports task.return result types containing borrow|reports missing canonical option requirements|reports invalid canonical result value type indexes" --reporter=compact`.
  - Performance gate:
    `dart run tool/component_benchmark.dart --json` reported
    `decode.per_iteration_us=60.435` and `validate.per_iteration_us=118.19`.
  - Done when: a decoded canonical `task.return` whose result type directly or
    indirectly contains `borrow` reports a structured validation error before
    any Preview3 task result can be bound to host execution.
  - Evidence update: this checked row plus the detailed backlog row and
    verification matrix.
  - Claim impact: contributes to `CM-VALIDATION-GAPS`, `SUPPORT-P2`, and
    `SUPPORT-P3`; it does not complete `SUPPORT-P1`/`SUPPORT-P2`/`SUPPORT-P3`
    or the broader component validation backlog.
- [x] `P1-SOCKET-FILESTAT-RIGHTS-PREFLIGHT` - `fd_filestat_get` descriptor and
  capability errors preflight guest-memory validation.
  - Scope: native/browser shared Preview1 `fd_filestat_get` errno ordering and
    filestat writes for socket, file, directory, and stdio descriptors.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/fd_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "fd_filestat_get descriptor errors do not require bound memory" --reporter=compact`
    failed before the fix because an unknown descriptor with no bound memory
    returned `EINVAL(28)` instead of `BADF(8)`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd_filestat_get descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_tell, fd_filestat_set_size, and fd_allocate update file size|fd_filestat_set_times and path_filestat_set_times persist virtual timestamps" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "fd_filestat_get descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_tell, fd_filestat_set_size, and fd_allocate update file size|fd_filestat_set_times and path_filestat_set_times persist virtual timestamps" --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` now
    includes `socket_filestat_rights_preflight`, with baseline
    `operations=4000`, `per_operation_us=0.73825`, and socket-heavy
    `operations=16000`, `per_operation_us=0.1220625`.
  - Done when: unknown descriptors return `BADF` before memory lookup, valid
    descriptors lacking `FD_FILESTAT_GET` return `ENOTCAPABLE` before output
    pointer validation, filestat output remains unchanged on those errors,
    successful socket filestat writes still expose socket filetypes, and
    native/browser imports share the same helper.
  - Evidence update: this checked row plus the detailed backlog row,
    verification matrix, and benchmark metric.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete the parent `P1-SOCKET-CONFORMANCE` row or any
    `SUPPORT-P1`/`SUPPORT-P2`/`SUPPORT-P3` gate.
- [x] `P1-SOCKET-POSITIONED-RIGHTS-PREFLIGHT` - Positioned fd operations on
  socket descriptors fail as capability errors before file lookup.
  - Scope: native/browser shared Preview1 `fd_pread`, `fd_pwrite`, `fd_seek`,
    and `fd_tell` errno ordering for valid socket descriptors without
    positioned-file rights.
  - Edit targets: `lib/src/wasi/preview1/common/fd_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "default socket rights expose socket-specific operations only" --reporter=compact`
    failed before the fix because `fd_pread` on a valid socket returned
    `BADF(8)` instead of `ENOTCAPABLE(76)`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "positioned fd descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_fdstat_set_rights persists and enforces descriptor rights|path_open creates, exclusively opens, and truncates virtual files|path_open create and truncate require directory rights|fd_pread, fd_pwrite, and fd_write update virtual files|fd_tell, fd_filestat_set_size, and fd_allocate update file size" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "positioned fd descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_fdstat_set_rights persists and enforces descriptor rights|path_open creates, exclusively opens, and truncates virtual files|path_open create and truncate require directory rights|fd_pread, fd_pwrite, and fd_write update virtual files|fd_tell, fd_filestat_set_size, and fd_allocate update file size" --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` now
    includes `socket_positioned_rights_preflight`, with baseline
    `operations=8000`, `per_operation_us=0.5745`, and socket-heavy
    `operations=32000`, `per_operation_us=0.07315625`.
  - Done when: default sockets report `ENOTCAPABLE` for `fd_pread`,
    `fd_pwrite`, `fd_seek`, and `fd_tell`, output pointers remain unchanged on
    those errors, unknown descriptors still report `BADF`, positioned file IO
    requires `FD_SEEK` alongside read/write capability, and native/browser
    imports share the same helper.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete the parent row or any `SUPPORT-P1`/`SUPPORT-P2`/`SUPPORT-P3`
    gate.
- [x] `P1-SOCKET-STREAM-ZERO-SEND` - Zero-byte stream socket writes are
  no-ops even when the stream is not write-ready.
  - Scope: native/browser shared Preview1 byte-stream `sock_send` and
    socket-backed `fd_write` zero-capacity writes.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_send and fd_write treat zero-byte stream writes as no-ops" --reporter=compact`
    failed before the fix because `sock_send` on a blocked stream returned
    `EAGAIN(6)` instead of writing `nwritten=0`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_send and fd_write treat zero-byte stream writes as no-ops" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "sock_send and fd_write treat zero-byte stream writes as no-ops" --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` now
    includes `socket_stream_zero_send`, with baseline `operations=2000`,
    `per_operation_us=0.0665`, and socket-heavy `operations=8000`,
    `per_operation_us=0.023375`.
  - Done when: stream zero-capacity writes still validate iovs and output
    pointers, preserve send-side shutdown errors, bypass `writeReady=false`,
    write `nwritten=0`, and do not record sent bytes.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete the parent row or any `SUPPORT-P1`/`SUPPORT-P2`/`SUPPORT-P3`
    gate.
- [x] `P1-SOCKET-FILE-RIGHTS-PREFLIGHT` - File-only fd mutations on socket
  descriptors fail as capability errors before file lookup.
  - Scope: native/browser shared Preview1 `fd_allocate` and
    `fd_filestat_set_size` errno ordering for valid socket descriptors without
    file-only rights.
  - Edit targets: `lib/src/wasi/preview1/common/fd_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "default socket rights expose socket-specific operations only" --reporter=compact`
    failed before the fix because `fd_allocate` on a valid socket returned
    `BADF(8)` instead of `ENOTCAPABLE(76)`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "default socket rights expose socket-specific operations only" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "default socket rights expose socket-specific operations only" --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` now
    includes `socket_file_rights_preflight`, with baseline
    `operations=4000`, `per_operation_us=0.10475`, and socket-heavy
    `operations=16000`, `per_operation_us=0.0638125`.
  - Done when: default sockets report `ENOTCAPABLE` for `fd_allocate` and
    `fd_filestat_set_size`, unknown descriptors still report `BADF`, real files
    still allocate/truncate, and native/browser imports share the same helper.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete the parent row or any `SUPPORT-P1`/`SUPPORT-P2`/`SUPPORT-P3`
    gate.
- [x] `P1-SOCKET-DGRAM-READINESS-HINT` - Datagram sockets honor host read
  readiness hints in `poll_oneoff(fd_read)`.
  - Scope: native/browser shared Preview1 socket poll readiness for host-backed
    datagram descriptors.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "poll_oneoff reports host socket readiness hints" --reporter=compact`
    failed before the fix because a datagram socket with `readReadyBytes=5`
    produced `nevents=0` instead of a fd_read event.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "poll_oneoff reports host socket readiness hints" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff reports host socket readiness hints" --reporter=compact`;
    `dart test test/wasi_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` now
    includes datagram host hints in `socket_poll_readiness`, with baseline
    `operations=22000`, `per_operation_us=0.4178636363636364`, and
    socket-heavy `operations=88000`, `per_operation_us=0.07564772727272727`.
  - Done when: queued datagram messages still provide their exact message
    length, positive host readiness hints produce a fd_read event when no
    message has materialized, zero hints remain not-ready, and native/browser
    focused gates agree.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete the parent row or any `SUPPORT-P1`/`SUPPORT-P2`/`SUPPORT-P3`
    gate.
- [x] `CM-VARIANT-PAYLOAD-STORE-VALIDATION` - Canonical variant store validates
  payload shape before writing guest memory.
  - Scope: Canonical ABI value-memory store behavior for variant, option, and
    result-style payload cases used by Preview2/Preview3 adapters.
  - Edit targets: `lib/src/wasi/component/value_memory.dart`,
    `test/wasi_component_value_memory_test.dart`,
    `tool/wasi_resource_table_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_value_memory_test.dart --name "rejects invalid variant payloads before writing memory" --reporter=compact`
    failed before the fix because a payloadless variant case carrying an
    associated payload returned successfully instead of throwing, and the same
    path could write the discriminant before detecting invalid payload shape.
  - Implementation gate:
    `dart test test/wasi_component_value_memory_test.dart --name "rejects invalid variant payloads before writing memory" --reporter=compact`;
    `dart test test/wasi_component_value_memory_test.dart --reporter=compact`;
    `dart test test/wasi_component_async_host_test.dart --reporter=compact`;
    `dart test test/wasi_component_host_test.dart --reporter=compact`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `canonical_variant_store.operations=4000` and
    `canonical_variant_store.per_operation_us=0.26275`.
  - Done when: payloadless cases reject associated values before memory writes,
    payload-bearing cases reject missing or invalid payloads before writing the
    discriminant, valid variant stores still write aligned payloads, and
    component host async/value-memory suites keep passing.
  - Evidence update: this checked row, the `CM-VALUE-VALIDATION` checked-child
    list, the verification matrix, and the resource benchmark payload.
  - Claim impact: reduces P2/P3 Canonical ABI value validation risk; does not
    complete `CM-VALUE-VALIDATION`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-FDFLAGS-RIGHTS-PREFLIGHT` - Socket-unsupported
  `fd_fdstat_set_flags` flags are rejected before descriptor rights.
  - Scope: native/browser shared Preview1 `fd_fdstat_set_flags` errno ordering
    for socket descriptors.
  - Edit targets: `lib/src/wasi/preview1/common/fd_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags" --reporter=compact`
    failed before the fix because a rightless socket returned
    `ENOTCAPABLE` (`76`) for the file-only `APPEND` fdflag instead of
    classifying the socket-unsupported flag as `NOTSUP` (`58`).
  - Implementation gate:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags" --reporter=compact`;
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags|sock_accept|datagram sockets do not expose accept rights|default socket rights expose socket-specific operations only" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags|sock_accept|datagram sockets do not expose accept rights|default socket rights expose socket-specific operations only" --reporter=compact`;
    `dart test test/wasi_test.dart --reporter=compact`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=socket-heavy --iterations=1000`
    reported `socket fdflag preflight.operations=4000` and
    `socket fdflag preflight.per_operation_us=0.11875`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`
    reported `socket_fdflag_preflight.operations=8000` and
    `socket_fdflag_preflight.per_operation_us=0.21875` for the baseline
    distribution, plus `socket_fdflag_preflight.operations=32000` and
    `socket_fdflag_preflight.per_operation_us=0.05709375` for the socket-heavy
    distribution.
  - Done when: unknown fdflag bits still return `EINVAL`,
    socket-unsupported known fdflags return `NOTSUP` even without descriptor
    mutation rights, supported `NONBLOCK` still requires `FD_FDSTAT_SET_FLAGS`,
    successful socket flag mutation remains supported, and native/browser hosts
    share the same implementation.
  - Evidence update: this checked row, the detailed backlog child row, the
    verification matrix, and the socket benchmark payload.
  - Claim impact: closes one Preview1 socket fdflag conformance gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-CONNECTED-ACCEPT-CAPABILITY` - Stream sockets can opt out of
  listener accept capability.
  - Scope: native/browser shared Preview1 socket descriptor rights and
    `sock_accept` classification for host-injected connected streams.
  - Edit targets: `lib/src/wasi/preview1/socket.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/common/socket_syscalls.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "connected stream sockets can opt out of accept capability" --reporter=compact`
    failed before the fix because `WASIPreview1Socket` had no `canAccept`
    named parameter, so every injected stream descriptor was modeled as
    listener-capable.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "connected stream sockets can opt out of accept capability" --reporter=compact`;
    `dart test test/wasi_test.dart --name "connected stream sockets can opt out of accept capability|accepted sockets do not inherit listener accept rights by default|sock_accept returns queued preview1 stream sockets with inherited rights|default socket rights expose socket-specific operations only|socket descriptor flags reject file-only flags|datagram sockets do not expose accept rights" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "connected stream sockets can opt out of accept capability|accepted sockets do not inherit listener accept rights by default|sock_accept returns queued preview1 stream sockets with inherited rights|default socket rights expose socket-specific operations only|socket descriptor flags reject file-only flags|datagram sockets do not expose accept rights" --reporter=compact`;
    `dart test test/wasi_test.dart --reporter=compact`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_connected_rights.operations=6000` and
    `socket_connected_rights.per_operation_us=0.06766666666666667` for the
    baseline distribution, plus `socket_connected_rights.operations=24000` and
    `socket_connected_rights.per_operation_us=0.015833333333333335` for the
    socket-heavy distribution.
  - Done when: host code can create `WASIPreview1Socket(canAccept: false)`,
    the descriptor exposes stream send/recv/shutdown rights without
    `SOCK_ACCEPT`, `sock_accept` preserves the output fd pointer and reports
    `ENOTCAPABLE`, listener streams keep existing `sock_accept` behavior, and
    accepted sockets still do not inherit listener accept rights.
  - Evidence update: this checked row, the detailed backlog child row, the
    verification matrix, and the socket benchmark payload.
  - Claim impact: closes one Preview1 socket capability-model gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P3-ASYNC-CHAR-SCALAR` - Reject non-scalar `future<char>` values before
  canonical memory copies.
  - Scope: internal Preview3 async future value validation plus shared
    Canonical ABI char scalar handling in value-memory and adapter direct paths.
  - Edit targets: `lib/src/wasi/component/unicode_scalar.dart`,
    `lib/src/wasi/component/async_host.dart`,
    `lib/src/wasi/component/value_memory.dart`,
    `lib/src/wasi/component/adapter_host.dart`,
    `test/wasi_component_async_host_test.dart`,
    `test/wasi_component_value_memory_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_async_host_test.dart --name "rejects non-scalar char future values before memory copies"`
    failed before the fix because `String.fromCharCode(0xd800)` was accepted as
    a `future<char>` value and `future.write` returned `null`.
  - Implementation gate:
    `dart test test/wasi_component_async_host_test.dart --name "rejects non-scalar char future values before memory copies"`;
    `dart test test/wasi_component_value_memory_test.dart --name "rejects non-scalar char stores"`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart test test/wasi_component_value_memory_test.dart`;
    `dart test test/wasi_component_adapter_plan_test.dart`;
    `dart test test/wasi_component_host_test.dart`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`
    reported `future_memory_copy.operations=8000` and
    `future_memory_copy.per_operation_us=0.165125`. The implementation is a
    constant-time scalar predicate shared by existing validation paths and adds
    no loop, allocation, or table mutation to copy hot paths.
  - Done when: non-scalar Dart strings fail before being written into a
    `future<char>` endpoint, legal scalar values still copy to canonical memory,
    value-memory store rejects non-scalar char without changing guest memory,
    and adapter direct char conversion uses the same scalar predicate.
  - Evidence update: this checked row, the detailed backlog child row, the
    current execution board checked-child list, and the verification matrix.
  - Claim impact: closes one Preview3 async Canonical ABI value-boundary gap;
    does not complete `P3-ASYNC-COPY-GAPS`, `CM-VALUE-VALIDATION`,
    `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `CM-RESOURCE-REPRESENTATION-VALIDATION` - Enforce `i32` component
  resource representations and reject other core value type encodings.
  - Scope: component-model resource type validation before P2/P3 resource host
    binding and canonical resource operations.
  - Edit targets: `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart --name "reports invalid component resource type indexes"`
    first failed because a resource type with representation byte `0x00`
    validated with no diagnostic; this correction then failed because
    single-byte `externref` validated cleanly and a validly encoded `(ref eq)`
    representation threw `FormatException: Unsupported Wasm component optional
    index tag: 0x6d` before validation could report the unsupported
    representation.
  - Implementation gate:
    `dart test test/component_test.dart --name "reports invalid component resource type indexes"`;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart analyze`;
    `dart test`.
  - Performance gate: N/A; this is a constant-time validation check over a
    decoded resource type and does not touch adapter execution, async copy, or
    resource-table hot paths.
  - Done when: `i32` resource representations validate; non-`i32`
    representations such as `externref`, `(ref eq)`, and malformed `0x00`
    encodings produce structured validation diagnostics before resource host
    binding; and typed-reference representation payload bytes are consumed by
    the decoder instead of being misread as destructor/callback option tags.
  - Evidence update: this checked row, the detailed backlog child row, and the
    current execution board checked-child list.
  - Claim impact: reduces P2/P3 resource validation risk; does not complete
    `CM-VALIDATION-GAPS`, `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-SHUTDOWN-HOW-PREFLIGHT` - `sock_shutdown` validates `how`
  before descriptor/socket/right state.
  - Scope: native/browser shared Preview1 `sock_shutdown` ABI validation
    ordering and socket state preservation on invalid shutdown flags.
  - Edit targets: `lib/src/wasi/preview1/common/socket_syscalls.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_shutdown validates how before descriptor state"`
    failed before the fix with `Expected: <28>` and `Actual: <8>`, proving an
    invalid `how` value was hidden behind unknown-fd `BADF` classification.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_shutdown validates how before descriptor state"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_shutdown validates how before descriptor state"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_shutdown_preflight.operations=10000` and
    `socket_shutdown_preflight.per_operation_us=0.0972` for the baseline
    distribution, plus `socket_shutdown_preflight.operations=40000` and
    `socket_shutdown_preflight.per_operation_us=0.02065` for the socket-heavy
    distribution. The implementation moves one constant-time bitmask check
    before descriptor lookup and adds no allocation, loop, or VFS mutation.
  - Done when: invalid `sock_shutdown` `how` values return `EINVAL` before
    bad-fd, non-socket, or rights errors, and do not change socket receive/send
    shutdown state.
  - Evidence update: this checked row, the detailed backlog child row, the
    verification matrix, and the current baseline.
  - Claim impact: closes one Preview1 socket ABI-validation ordering gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-FD-IOV-SNAPSHOT-PREFLIGHT` - Virtual-file `fd_read`/`fd_pread`
  snapshots overlapping iovec tables and `fd_write`/`fd_pwrite` validates all
  iovecs before mutating files.
  - Scope: native/browser Preview1 virtual-file `fd_read`, `fd_pread`,
    `fd_write`, and `fd_pwrite` iovec aliasing and all-or-error validation
    semantics.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes"`
    failed before the fix with `Expected: 'ok!'` and `Actual: '___'`, proving
    the first file read buffer could overwrite the next iovec descriptor before
    the host used it.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes"`;
    `dart test -p chrome test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes"`;
    `dart test test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes|fd_pwrite validates all iovs before mutating virtual files"`;
    `dart test -p chrome test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes|fd_pwrite validates all iovs before mutating virtual files"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `file_fd_read_write.operations=4000` and
    `file_fd_read_write.per_operation_us=0.3525` for the baseline distribution,
    plus `file_fd_read_write.operations=16000` and
    `file_fd_read_write.per_operation_us=0.0370625` for the socket-heavy
    distribution. The read path snapshots only when output buffers overlap the
    iovec table, and the write path preflights all descriptors without snapshot
    allocation before mutating file bytes.
  - Done when: native and browser virtual-file reads use the syscall-start iovec
    descriptors even when read buffers alias the descriptor table, and virtual
    file writes reject any invalid iovec before changing file contents or the
    result count pointer.
  - Evidence update: this checked row, the detailed backlog child row, the
    verification matrix, and the current baseline.
  - Claim impact: closes one Preview1 virtual-file fd iovec conformance gap for
    native/browser hosts; does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P1-SOCKET-SEND-IOV-SNAPSHOT` - Stream `sock_send` snapshots overlapping
  iovec tables before host send callbacks can mutate guest memory.
  - Scope: native/browser shared Preview1 stream `sock_send` iovec aliasing
    semantics in the VFS socket send helper.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs"`
    failed before the fix with `Expected: [65, 111, 107, 33]` and
    `Actual: [65, 98, 97, 100]`, proving a mutating host send callback could
    corrupt the next iovec descriptor and redirect the second send segment.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs"`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs"`;
    `dart test test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs|virtual socket send handlers stop after partial writes|virtual socket host send handlers reject invalid write counts|sock_recv|sock_send"`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs|virtual socket send handlers stop after partial writes|virtual socket host send handlers reject invalid write counts|sock_recv|sock_send"`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_send_recv.operations=56000`,
    `socket_send_recv.per_operation_us=0.22196428571428573`,
    `socket_send_error_preflight.operations=48000`,
    `socket_send_error_preflight.per_operation_us=0.00975`,
    `socket_fd_read_write.operations=32000`, and
    `socket_fd_read_write.per_operation_us=0.2335` for the socket-heavy
    distribution. The implementation allocates an iov snapshot only when stream
    send buffers overlap the iovec table; ordinary non-overlapping stream sends
    and datagram sends remain no-snapshot for this guard.
  - Done when: stream `sock_send` uses the iovec descriptors as they existed
    before host callbacks run, even when a send buffer overlaps the iovec table
    and the host callback mutates guest memory.
  - Evidence update: this checked row, the detailed backlog child row, the
    verification matrix, and the current baseline.
  - Claim impact: closes one Preview1 socket memory-aliasing conformance gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-ACCEPT-FLAG-PREFLIGHT` - `sock_accept` validates
  socket-unsupported fdflags before accept rights.
  - Scope: native/browser shared Preview1 stream `sock_accept` descriptor flag
    validation ordering after fd/socket classification and before rights or
    queue mutation.
  - Edit targets: `lib/src/wasi/preview1/common/socket_syscalls.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`
    failed before the fix with `Expected: <58>` and `Actual: <76>`, proving a
    socket-unsupported `APPEND` flag was hidden behind missing `SOCK_ACCEPT`
    rights.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`;
    `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`;
    `dart test test/wasi_test.dart --name "sock_accept|socket descriptor flags|socket syscalls return notsock|datagram sockets do not expose accept rights"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_accept|socket descriptor flags|socket syscalls return notsock|datagram sockets do not expose accept rights"`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_accept_inheritance.operations=16000`,
    `socket_accept_inheritance.per_operation_us=0.0898125`,
    `socket_accept_receive_shutdown.operations=16000`,
    `socket_accept_receive_shutdown.per_operation_us=0.0215625`,
    `socket_poll_readiness.operations=80000`, and
    `socket_poll_readiness.per_operation_us=0.074125` for the socket-heavy
    distribution. The implementation only moves an existing constant-time
    fdflag mask check earlier after socket classification; successful accept
    hot paths add no allocation or loops.
  - Done when: `sock_accept(APPEND)` on a socket returns `NOTSUP` before rights
    failures, preserves the output fd pointer, and leaves the queued accepted
    socket available.
  - Evidence update: this checked row, the detailed backlog child row, the
    verification matrix, and the current baseline.
  - Claim impact: closes one Preview1 socket accept flag-ordering conformance
    gap for native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-FLAG-PREFLIGHT` - `sock_recv` and `sock_send` validate ABI
  flags before descriptor/socket/right state.
  - Scope: native/browser shared Preview1 stream and datagram `sock_recv` and
    `sock_send` flag validation ordering.
  - Edit targets: `lib/src/wasi/preview1/common/socket_syscalls.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_recv and sock_send validate flags before descriptor rights"`
    failed before the fix with `Expected: <28>` and `Actual: <76>`, proving
    invalid flags were hidden behind `NOTCAPABLE` descriptor-right checks.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_recv and sock_send validate flags before descriptor rights"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv and sock_send validate flags before descriptor rights"`;
    `dart test test/wasi_test.dart --name "sock_recv|sock_send"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv|sock_send"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_recv_peek.operations=8000`,
    `socket_recv_peek.per_operation_us=0.146`,
    `socket_recv_waitall.operations=24000`,
    `socket_recv_waitall.per_operation_us=0.48625`,
    `socket_send_recv.operations=56000`,
    `socket_send_recv.per_operation_us=0.20760714285714285`,
    `socket_send_error_preflight.operations=48000`,
    `socket_send_error_preflight.per_operation_us=0.009395833333333334`,
    `socket_fd_read_write.operations=32000`, and
    `socket_fd_read_write.per_operation_us=0.2274375` for the socket-heavy
    distribution. The implementation only moves constant-time flag checks ahead
    of descriptor lookup and right checks; success hot paths add no allocation
    or loops.
  - Done when: invalid `sock_recv`/`sock_send` flags return `EINVAL` without
    mutating output pointers, consuming receive data, or recording sent bytes,
    even when descriptor rights are absent.
  - Evidence update: this checked row, the detailed backlog child row, the
    verification matrix, and the current baseline.
  - Claim impact: closes one Preview1 socket ABI-validation ordering gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-RECV-IOV-SNAPSHOT` - `sock_recv` snapshots overlapping iovec
  tables before writing receive buffers.
  - Scope: native/browser shared Preview1 stream and datagram `sock_recv` iovec
    aliasing semantics in the VFS socket receive helper.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_recv snapshots iovs before writing receive buffers"`
    failed before the fix with a `RangeError` after the first receive buffer
    overwrote the second iovec table entry and the host re-read the corrupted
    pointer.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_recv snapshots iovs before writing receive buffers"`;
    `dart test test/wasi_test.dart --name "sock_recv"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_recv_peek.operations=8000`,
    `socket_recv_peek.per_operation_us=0.14575`,
    `socket_recv_waitall.operations=24000`,
    `socket_recv_waitall.per_operation_us=0.4800833333333333`,
    `socket_send_recv.operations=56000`,
    `socket_send_recv.per_operation_us=0.20007142857142857`,
    `socket_fd_read_write.operations=32000`, and
    `socket_fd_read_write.per_operation_us=0.22259375` for the socket-heavy
    distribution. The implementation allocates a flat iov snapshot only when a
    receive buffer overlaps the iovec table; ordinary non-overlapping recv paths
    remain no-snapshot.
  - Done when: stream and datagram `sock_recv` use the iovec descriptors as they
    existed before any receive buffer writes, while non-overlapping hot paths
    avoid per-call snapshot allocation.
  - Evidence update: this checked row, the detailed backlog child row, the
    verification matrix, and the current baseline.
  - Claim impact: closes one Preview1 socket memory-aliasing conformance gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-FD-COUNT-PTR-ZERO` - Preview1 fd count outputs may target memory
  address zero.
  - Scope: native/browser Preview1 stdio and virtual-file `fd_read`,
    `fd_write`, `fd_pread`, and `fd_pwrite` result count pointers.
  - Edit targets: `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "fd read and write counts can target memory zero"`
    failed before the fix because `fd_write` returned success but left the
    count pointer at address `0` unchanged.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd read and write counts can target memory zero"`;
    `dart test -p chrome test/wasi_test.dart --name "fd read and write counts can target memory zero"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_fd_read_write.operations=32000`,
    `socket_fd_read_write.per_operation_us=0.237125`,
    `socket_poll_readiness.operations=80000`, and
    `socket_poll_readiness.per_operation_us=0.0749` for the socket-heavy
    distribution. The implementation adds one constant-time result-pointer
    preflight before the iovec loop and does not add per-iovec allocation.
  - Done when: native and browser hosts treat guest memory address `0` as a valid
    result count pointer for stdio and virtual-file read/write syscalls, and
    invalid result pointers are rejected before host IO side effects.
  - Evidence update: this checked row, the detailed backlog child row, the
    verification matrix, and the current baseline.
  - Claim impact: closes one Preview1 fd ABI gap for native/browser hosts; does
    not complete `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-POLL-CLOCK-VALIDATION` - `poll_oneoff` reports invalid clock
  subscriptions as event errors.
  - Scope: native/browser Preview1 `poll_oneoff` clock subscription validation.
  - Edit targets: `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "poll_oneoff reports invalid clock subscriptions as event errors"`
    failed before the fix because unsupported clock ids produced a success event
    with event errno `0`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "poll_oneoff reports invalid clock subscriptions as event errors"`;
    `dart test test/wasi_test.dart --name "poll_oneoff"`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff"`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_poll_readiness.operations=80000` and
    `socket_poll_readiness.per_operation_us=0.07295` for the socket-heavy
    distribution.
  - Done when: unsupported clock ids and unknown clock flags write a clock event
    with `EINVAL`, while valid pending clock subscriptions still defer to the
    existing wait-time calculation.
  - Evidence update: this checked row plus the verification matrix row.
  - Claim impact: closes one Preview1 poll/clock validation gap for
    native/browser hosts; does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P1-CLOCK-TIME-INVALID-ID` - `clock_time_get` rejects unsupported
  Preview1 clock ids without mutating guest output.
  - Scope: native/browser Preview1 `clock_time_get` syscall validation.
  - Edit targets: `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "clock_time_get returns inval for unsupported clock ids"`
    failed before the fix because `clock_time_get(99, ...)` returned success and
    wrote a timestamp.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "clock_time_get returns inval for unsupported clock ids"`;
    `dart test test/wasi_test.dart --name "clock_time_get"`;
    `dart test -p chrome test/wasi_test.dart --name "clock_time_get"`.
  - Performance gate: N/A; this adds one constant-time supported-clock check to an
    existing syscall boundary and does not add a loop, allocation, or runtime hot
    path.
  - Done when: unsupported clock ids return `EINVAL`, preserve the output memory,
    and supported clock ids still write timestamps on native and browser hosts.
  - Evidence update: this checked row plus the verification matrix row.
  - Claim impact: closes one Preview1 clock syscall validation gap for
    native/browser hosts; does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `CM-CANONICAL-COPY-OPTION-PLACEMENT` - Stream/future canonical copy
  definitions reject non-copy options during validation.
  - Scope: component-model canonical validation for decoded `stream.read`,
    `stream.write`, `future.read`, and `future.write` definitions before async
    host binding.
  - Edit targets: `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart --name "reports invalid canonical option placements"`
    failed before the fix because `canon stream.read` with an `async` option
    validated without a diagnostic rejecting that option placement.
  - Implementation gate:
    `dart test test/component_test.dart --name "reports invalid canonical option placements"`;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`.
  - Performance gate: N/A; this tightens an existing validation-time
    `O(option count)` scan and does not add a runtime host or copy hot path.
  - Done when: stream/future copy definitions only accept string encoding,
    memory, and realloc canonical options, and invalid options fail validation
    before any async host state can be bound.
  - Evidence update: this checked row plus the detailed backlog child row.
  - Claim impact: reduces P2/P3 component validation risk; does not complete
    `CM-VALIDATION-GAPS`, `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P3-ASYNC-ERROR-CONTEXT-COPY` - `stream<error-context>` and
  `future<error-context>` payloads copy through canonical memory.
  - Scope: internal Preview3 async value copy path over real error-context host
    handles in a shared component resource table.
  - Edit targets: `lib/src/wasi/component/async_host.dart`,
    `test/wasi_component_async_host_test.dart`, and
    `tool/wasi_component_async_benchmark.dart`.
  - Red test:
    `dart test test/wasi_component_async_host_test.dart --name "copies error-context"`
    failed before the fix because `_asyncValueValidatorForElementType` rejected
    error-context stream/future element values with an `UnsupportedError`.
  - Implementation gate:
    `dart test test/wasi_component_async_host_test.dart --name "copies error-context"`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart test test/wasi_component_value_memory_test.dart`;
    `dart test test/wasi_component_host_test.dart`.
  - Performance gate:
    `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`
    reported `stream_error_context_memory_copy.operations=64000`,
    `stream_error_context_memory_copy.per_operation_us=0.044671875`,
    `future_error_context_memory_copy.operations=8000`, and
    `future_error_context_memory_copy.per_operation_us=0.1365`;
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_adapter_error_context_memory_invoke.operations=4000`,
    `component_adapter_error_context_memory_invoke.per_operation_us=0.18925`,
    `error_context_memory.operations=14000`, and
    `error_context_memory.per_operation_us=0.06535714285714286`.
  - Done when: decoded error-context stream and future element types accept real
    error-context handles, copy them through guest memory, preserve the debug
    message resource, drop async endpoints without dropping the payload handle,
    and include dedicated benchmark metrics.
  - Evidence update: this checked row plus the detailed backlog child row.
  - Claim impact: closes one Preview3 async error-context copy gap; does not
    complete `P3-ASYNC-COPY-GAPS`, `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `CM-VALUE-DEFINITION-TYPE-VALIDATION` - Value definitions validate their
  component value type indexes before becoming value entries.
  - Evidence:
    `dart test test/component_test.dart --name "reports invalid component value definition type indexes"`
    failed before the fix because a value definition whose type index referenced
    a function type threw a decode-time `FormatException` before validator
    diagnostics, then passed after the fix;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`; `dart analyze`;
    `dart test`.
  - Claim impact: moves one P2/P3 component-model value definition index-space
    error from decode-time exception to deterministic validation; does not
    complete `CM-VALIDATION-GAPS`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-POLL-WRITE-HANGUP` - `poll_oneoff(fd_write)` reports hangup
  after send-side socket shutdown.
  - Evidence:
    `dart test test/wasi_test.dart --name "poll_oneoff reports socket write readiness and rights errors"`
    failed before the fix because the fd_write subscription produced
    `nevents=0` after `sock_shutdown(SD_WR)`, then passed after the fix;
    `dart test test/wasi_test.dart --name "poll_oneoff reports socket write readiness and rights errors|poll_oneoff reports host socket readiness hints|sock_send reports pipe after write-side shutdown"`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff reports socket write readiness and rights errors|poll_oneoff reports host socket readiness hints|sock_send reports pipe after write-side shutdown"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_poll_readiness.operations=80000` and
    `socket_poll_readiness.per_operation_us=0.073925` for the socket-heavy
    distribution.
  - Spec reference: Preview1 fd-readwrite poll events carry the same
    `FD_READWRITE_HANGUP` flag for `fd_read` and `fd_write` subscriptions;
    send-side shutdown must be observable instead of silently looking
    not-ready.
  - Claim impact: closes one Preview1 socket poll/shutdown consistency gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-SEND-ERROR-PREFLIGHT` - Socket send iovec validation wins over
  shutdown and write-ready error states.
  - Evidence:
    the focused red test initially named
    `sock_send validates iovs before send-side shutdown state` failed before the
    fix because `sock_send` returned `EPIPE` before checking the invalid iov;
    after adding blocked-stream coverage, the final executable gates passed:
    `dart test test/wasi_test.dart --name "sock_send validates iovs before socket send error states"`;
    `dart test test/wasi_test.dart --name "sock_send validates iovs before socket send error states|sock_send reports pipe after write-side shutdown|sock_recv and sock_send validate stream iovs before side effects"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_send validates iovs before socket send error states|sock_send reports pipe after write-side shutdown|sock_recv and sock_send validate stream iovs before side effects"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_send_error_preflight.operations=48000` and
    `socket_send_error_preflight.per_operation_us=0.011375` for the socket-heavy
    distribution.
  - Spec reference: Preview1 socket writes are guest-memory iovec operations;
    invalid iovs must not be hidden by socket shutdown or would-block state, and
    error paths must leave `nwritten` and host send queues unchanged.
  - Claim impact: closes one Preview1 socket error-ordering gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-DATAGRAM-RIGHTS-NARROW` - Datagram sockets do not expose
  listener-only `SOCK_ACCEPT` capability.
  - Evidence:
    `dart test test/wasi_test.dart --name "datagram sockets do not expose accept rights"`
    failed before the fix because datagram `fd_fdstat_get` exposed
    `SOCK_ACCEPT`, then passed after the fix;
    `dart test test/wasi_test.dart --name "datagram sockets do not expose accept rights|sock_accept returns queued preview1 stream sockets with inherited rights|default socket rights expose socket-specific operations only|sock_recv reports truncation for datagram sockets|sock_recv peek preserves datagram messages and sock_send records datagrams|fd_read and fd_write operate on preview1 socket descriptors"`;
    `dart test -p chrome test/wasi_test.dart --name "datagram sockets do not expose accept rights|sock_accept returns queued preview1 stream sockets with inherited rights|default socket rights expose socket-specific operations only|sock_recv reports truncation for datagram sockets|sock_recv peek preserves datagram messages and sock_send records datagrams|fd_read and fd_write operate on preview1 socket descriptors"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_datagram_rights.operations=16000` and
    `socket_datagram_rights.per_operation_us=0.019875` for the socket-heavy
    distribution.
  - Spec reference: Preview1 `SOCK_ACCEPT` is a listener operation; datagram
    descriptors can still read, write, poll, and shut down but must not expose
    accept as a grantable default right.
  - Claim impact: closes one Preview1 socket capability-surface gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-ACCEPT-RECEIVE-SHUTDOWN` - Listener receive shutdown terminates
  pending accepts without fd side effects.
  - Evidence:
    `dart test test/wasi_test.dart --name "sock_accept stops after listener receive shutdown without fd side effects"`
    failed before the fix because `sock_accept` returned `SUCCESS` after
    `sock_shutdown(SD_RD)`, then passed after the fix;
    `dart test test/wasi_test.dart --name "sock_accept stops after listener receive shutdown without fd side effects|poll_oneoff reports queued socket accepts as readable|sock_accept returns queued preview1 stream sockets with inherited rights|sock_shutdown and descriptor rights are enforced for preview1 sockets|poll_oneoff reports preview1 socket read readiness and hangup"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_accept stops after listener receive shutdown without fd side effects|poll_oneoff reports queued socket accepts as readable|sock_accept returns queued preview1 stream sockets with inherited rights|sock_shutdown and descriptor rights are enforced for preview1 sockets|poll_oneoff reports preview1 socket read readiness and hangup"`;
    `dart test test/wasi_test.dart`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_accept_receive_shutdown.operations=16000` and
    `socket_accept_receive_shutdown.per_operation_us=0.043625` for the
    socket-heavy distribution.
  - Spec reference: Preview1 `sock_shutdown(SD_RD)` terminates receive-side
    operations; queued accepts are modeled as socket read readiness and must not
    remain separately consumable after receive shutdown reports hangup.
  - Claim impact: closes one Preview1 socket shutdown/accept consistency gap;
    does not complete `P1-SOCKET-CONFORMANCE`, `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P2-P3-ADAPTERS` - Preview2 and Preview3 fixed-version wrappers execute
  canonical primitive lift/lower adapters through the shared versioned host.
  - Evidence:
    `dart test test/wasi_component_versioned_host_test.dart --name "Preview2 and Preview3 wrappers execute primitive adapters"`
    failed before the fix because the fixed-version wrappers did not expose a
    `bindAdapters` path, then passed after the fix;
    `dart test test/wasi_component_versioned_host_test.dart`;
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_versioned_adapter_program_invoke.operations=8000` and
    `component_versioned_adapter_program_invoke.per_operation_us=0.192`;
    `dart analyze`.
  - Spec reference: Preview2 and Preview3 component hosts use Component Model
    canonical `lift`/`lower` adapter generation; this row routes that executable
    adapter path through the version profile instead of through Preview1 imports
    or direct low-level adapter-host access.
  - Claim impact: starts concrete Preview2/Preview3 adapter execution evidence;
    does not complete `SUPPORT-P2` or `SUPPORT-P3`.
- [x] `CM-EXTERN-NAME-CASE-FOLDING` - Component import/export name validation
  rejects case/acronym-folded collisions.
  - Evidence:
    `dart test test/component_test.dart --name "reports duplicate component import names"`;
    `dart test test/component_test.dart --name "validates component export sort indexes in definition order"`;
    `dart test test/component_test.dart --name "reports duplicate component type import names|validates function type indexes introduced by exports"`
    failed before the fix because `foo-bar` and `foo-BAR` validated cleanly
    for top-level imports, top-level exports, component/instance type imports,
    and component/instance type exports, then passed after the fix;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart test test/wasi_component_versioned_host_test.dart`; `dart analyze`.
  - Spec reference: Component Model strongly-unique import/export names compare
    lowercased acronym letters. This row closes the case-folding subset; the
    version-suffix and structured-name subset is covered by
    `CM-EXTERN-NAME-STRUCTURED-UNIQUE`.
  - Claim impact: reduces Preview2/Preview3 adapter interface ambiguity before
    binding; does not complete `CM-VALIDATION-GAPS`, `SUPPORT-P1`,
    `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `CM-EXTERN-NAME-STRUCTURED-UNIQUE` - Component extern name validation
  applies the structured strong-unique rules.
  - Evidence:
    `dart test test/component_test.dart --name "reports duplicate component import names|reports duplicate component type import names|validates function type indexes introduced by exports|validates component export sort indexes in definition order"`
    failed before the fix because top-level and type-declaration imports/exports
    accepted duplicate raw names with different version suffixes and accepted
    `foo` with `[method]foo.foo`, then passed after the fix;
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments"`
    failed before the fix because inline component instance exports accepted the
    same version-suffix and structured-name collisions, then passed after the
    fix; `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart test test/wasi_component_versioned_host_test.dart`.
  - Spec reference: Component Model import/export names use strong uniqueness:
    version suffixes do not distinguish validation names, bracketed annotations
    are stripped for folded-name comparison, `l` and `[constructor]l` are the
    special allowed pair, and `l` conflicts with `[*]l.l`.
  - Claim impact: closes the structured extern-name subset of
    `CM-VALIDATION-GAPS` and reduces Preview2/Preview3 adapter interface
    ambiguity before binding; does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `CM-EXPORT-DUPLICATE-NAMES` - Top-level component exports reject duplicate
  names during validation.
  - Evidence:
    `dart test test/component_test.dart --name "validates component export sort indexes in definition order"`
    failed before the fix because duplicate top-level component export names
    validated cleanly, then passed after the fix;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart test test/wasi_component_versioned_host_test.dart`; `dart analyze`.
  - Spec reference: Component Model import and export definitions require all
    export names to be strongly unique; this row closes the exact duplicate-name
    subset before adapter binding.
  - Claim impact: removes one component-model export-map ambiguity before
    Preview2/Preview3 adapter execution; does not complete
    `CM-VALIDATION-GAPS`, `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-POLL-ZERO-SUBSCRIPTIONS` - `poll_oneoff` rejects zero subscriptions
  without writing guest memory.
  - Evidence:
    `dart test test/wasi_test.dart --name "poll_oneoff rejects zero subscriptions without memory side effects"`
    failed before the fix because native `poll_oneoff` returned success; then
    passed after the fix;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff rejects zero subscriptions without memory side effects"`;
    `dart test test/wasi_test.dart --name "poll_oneoff"`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff"`;
    `dart test test/wasi_test.dart`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_poll_readiness.operations=72000` for the socket-heavy distribution.
  - Spec reference: WASI Preview1 `poll_oneoff` returns `errno::inval` when
    `nsubscriptions` is `0`.
  - Claim impact: closes one Preview1 syscall ABI and guest-memory side-effect
    gap for native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-FD-READ-WRITE` - Configured Preview1 socket descriptors work
  through generic `fd_read` and `fd_write`.
  - Evidence:
    `dart test test/wasi_test.dart --name "fd_read and fd_write operate on preview1 socket descriptors"`
    failed before the fix because `fd_read` returned `BADF(8)` for a socket fd,
    then passed after the fix;
    `dart test -p chrome test/wasi_test.dart --name "fd_read and fd_write operate on preview1 socket descriptors"`;
    `dart test test/wasi_test.dart`;
    `dart test test/readme_snippets_test.dart test/readme_commands_test.dart`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_fd_read_write.operations=32000` for the socket-heavy distribution;
    `dart analyze`.
  - Spec reference: WASI Preview1 `rights::fd_read` grants `fd_read` and
    `sock_recv`; `rights::fd_write` grants `fd_write` and `sock_send`.
  - Claim impact: closes one Preview1 socket descriptor compatibility gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-RIGHTS-NARROW` - Default Preview1 socket descriptors expose only
  socket-specific rights.
  - Evidence:
    `dart test test/wasi_test.dart --name "default socket rights expose socket-specific operations only"`
    failed before the fix because default socket fdstat rights were `rightsAll`;
    then passed after the fix;
    `dart test -p chrome test/wasi_test.dart --name "default socket rights expose socket-specific operations only|fd_read and fd_write operate on preview1 socket descriptors|sock_recv and sock_send use configured preview1 stream sockets|sock_accept returns queued preview1 stream sockets with inherited rights|sock_shutdown and descriptor rights are enforced for preview1 sockets"`;
    `dart test test/wasi_test.dart --name "socket"`;
    `dart test test/wasi_test.dart`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `rights_checks.operations=4096000` and
    `socket_fd_read_write.operations=32000` for the socket-heavy distribution;
    `dart analyze`.
  - Spec reference: WASI Preview1 rights separate socket IO/shutdown/accept/poll
    rights from file-only sync, advice, allocation, seek, and timestamp rights.
  - Claim impact: closes one Preview1 socket capability-boundary gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-ACCEPT-INHERITING-RIGHTS` - Accepted sockets do not inherit
  listener-only accept capability by default.
  - Evidence:
    `dart test test/wasi_test.dart --name "accepted sockets do not inherit listener accept rights by default"`
    failed before the fix because the accepted socket inherited `SOCK_ACCEPT` in
    its base rights, then passed after the fix;
    `dart test -p chrome test/wasi_test.dart --name "accepted sockets do not inherit listener accept rights by default|default socket rights expose socket-specific operations only|sock_accept returns queued preview1 stream sockets with inherited rights|poll_oneoff reports queued socket accepts as readable|poll_oneoff gates queued socket accepts on sock_accept rights"`;
    `dart test test/wasi_test.dart`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_accept_inheritance.operations=16000` for the socket-heavy
    distribution; `dart analyze`.
  - Spec reference: WASI Preview1 `fdstat` carries separate base and inheriting
    rights; accepted descriptors are derived from the listener's inheriting
    rights, so default listener-only `SOCK_ACCEPT` should not propagate to a
    connection descriptor.
  - Claim impact: closes one Preview1 socket capability propagation gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-POLL-ZERO-HINT` - Stream socket `readReadyBytes: 0` does not
  produce a false `poll_oneoff(fd_read)` readiness event.
  - Evidence:
    `dart test test/wasi_test.dart --name "virtual socket poll honors host readiness hints"`
    failed before the fix because shared VFS treated a zero-byte hint as ready;
    `dart test test/wasi_test.dart --name "poll_oneoff ignores zero-byte stream readiness hints"`
    failed before the fix because runtime `poll_oneoff` wrote both the false
    fd-read event and the fallback clock event, then both focused tests passed
    after the fix;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff ignores zero-byte stream readiness hints"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`
    reported `socket_poll_readiness.operations=72000` for the socket-heavy
    distribution with the zero-hint non-ready branch covered;
    `dart analyze`.
  - Claim impact: closes one Preview1 socket busy-poll conformance and
    performance gap for native/browser hosts; does not complete
    `P1-SOCKET-CONFORMANCE`, `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-POLL-PROVIDER-READINESS` - `poll_oneoff(fd_read)` observes
  host-backed stream providers when no explicit readiness hint is set.
  - Evidence:
    `dart test test/wasi_test.dart --name "poll_oneoff pulls host-backed stream provider readiness"`
    failed before the fix because the provider-backed stream returned
    `nevents=0`, then passed after the fix;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff pulls host-backed stream provider readiness"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`
    reported `socket_poll_readiness` with provider-backed stream polling in each
    distribution; `dart analyze`.
  - Claim impact: closes one Preview1 host-backed stream poll conformance gap
    for native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `CM-INLINE-INSTANCE-DUPLICATE-EXPORTS` - Component and core inline
  instance export names reject duplicates during validation.
  - Evidence:
    `dart test test/component_test.dart -n "validates component instantiation indexes and value arguments|validates core instance indexes in definition order"`
    failed before the fix because duplicate component/core inline export names
    validated cleanly, then passed after the fix;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`; `dart analyze`.
  - Claim impact: removes one component-model ambiguity before P2/P3 adapter
    binding or host mutation; does not complete `CM-VALIDATION-GAPS`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-POLL-ACCEPT-RIGHTS` - `poll_oneoff(fd_read)` uses
  `SOCK_ACCEPT` rights for queued accept readiness.
  - Evidence:
    `dart test test/wasi_test.dart --name "poll_oneoff gates queued socket accepts on sock_accept rights"`
    failed before the fix because a listener with `POLL_FD_READWRITE |
    SOCK_ACCEPT` but no `FD_READ` reported `ENOTCAPABLE(76)`, then passed after
    the fix;
    `dart test test/wasi_test.dart --name "poll_oneoff"`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`;
    `dart analyze`.
  - Claim impact: closes one Preview1 socket poll-rights conformance gap for
    native/browser hosts; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-PATH-OPEN-OFLAGS` - `path_open` implements Preview1 create,
  exclusive-create, and truncate semantics over the shared native/browser VFS.
  - Evidence:
    `dart test test/wasi_test.dart --name "path_open creates, exclusively opens, and truncates virtual files"`
    failed before the fix because `O_CREAT` on a missing file returned
    `ENOENT(44)`, then passed after the fix;
    `dart test test/wasi_test.dart --name "path_open"`;
    `dart test -p chrome test/wasi_test.dart --name "path_open"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Claim impact: closes one Preview1 file-system conformance gap for
    native/browser hosts; does not complete `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P1-SOCKET-ADAPTER-BOUNDARY` - Native and browser socket imports share one
  Preview1 adapter boundary.
  - Evidence:
    `dart test test/wasi_test.dart --name "socket syscalls return notsock for non-socket descriptors"`;
    `dart test test/wasi_test.dart --name "sock_shutdown and descriptor rights are enforced for preview1 sockets"`;
    `dart test -p chrome test/wasi_test.dart --name "socket syscalls return notsock for non-socket descriptors"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_shutdown and descriptor rights are enforced for preview1 sockets"`;
    `dart test test/wasi_test.dart`; `dart analyze`.
  - Claim impact: reduces native/browser Preview1 socket drift risk; does not
    complete `P1-SOCKET-CONFORMANCE`, `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `CM-INSTANTIATION-DUPLICATE-ARGS` - Component and core instantiation
  argument names reject duplicates during validation.
  - Evidence:
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments"`
    failed before the fix because duplicate component instantiation argument
    names validated cleanly, then passed after the fix;
    `dart test test/component_test.dart --name "validates core instance indexes in definition order"`
    failed before the fix because duplicate core instantiation argument names
    validated cleanly, then passed after the fix;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`; `dart analyze`.
  - Claim impact: reduces P2/P3 component validation ambiguity before adapter
    binding or host mutation; does not complete `CM-VALIDATION-GAPS`,
    `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-DATAGRAM-PARTIAL-SEND-INVALID` - Host-backed datagram send
  handlers must accept a whole message or fail validation.
  - Evidence:
    `dart test test/wasi_test.dart --name "sock_send rejects partial host-backed datagram writes"`
    failed before the fix because partial datagram writes returned success, then
    passed after the fix;
    `dart test test/wasi_test.dart --name "virtual socket host send handlers reject invalid write counts"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_send rejects partial host-backed datagram writes"`.
  - Claim impact: tightens native/browser Preview1 host-backed datagram send
    semantics and preserves `nwritten` on invalid host callback results; does
    not complete the parent `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-FDFLAGS-SUPPORTED` - Socket descriptors reject file-only
  descriptor flags while preserving `NONBLOCK`.
  - Evidence:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`
    failed before the fix because `sock_accept` accepted `APPEND`, then passed
    after the fix;
    `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`.
  - Claim impact: tightens native/browser Preview1 socket fdflag semantics and
    preserves accept queue/output state on unsupported flag errors; does not
    complete the parent `P1-SOCKET-CONFORMANCE` row.
- [x] `CM-INSTANCE-CORE-SORT-VALIDATION` - Component instance arguments reject
  missing core sort indexes during validation.
  - Evidence:
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments"`
    failed before the fix because an instance argument referencing an undefined
    core memory validated cleanly, then passed after the fix.
  - Claim impact: moves one component-model index-space error from accepted
    input to deterministic validation before any host binding; does not complete
    `CM-VALIDATION-GAPS`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-DATAGRAM-ACCEPT-NOTSUP` - `sock_accept` reports `NOTSUP` for
  datagram sockets instead of treating the descriptor as an invalid argument.
  - Evidence:
    `dart test test/wasi_test.dart --name "sock_accept rejects datagram sockets"`
    failed before the fix because datagram sockets returned `EINVAL`, then
    passed after the fix;
    `dart test -p chrome test/wasi_test.dart --name "sock_accept rejects datagram sockets"`.
  - Claim impact: tightens native/browser Preview1 socket errno classification
    for operations unsupported by a valid socket type. This historical row is
    narrowed further by `P1-SOCKET-DATAGRAM-RIGHTS-NARROW`, where default
    datagram descriptors no longer expose `SOCK_ACCEPT` and now fail the
    capability check first; it does not complete the parent
    `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-NONSOCKET-ERRNO` - Socket syscalls report `NOTSOCK` for
  descriptors that exist but are not sockets.
  - Evidence:
    `dart test test/wasi_test.dart --name "socket syscalls return notsock for non-socket descriptors"`
    failed before the fix because `sock_accept`, `sock_recv`, `sock_send`, and
    `sock_shutdown` returned `BADF` for the configured preopen fd, then passed
    after the fix;
    `dart test -p chrome test/wasi_test.dart --name "socket syscalls return notsock for non-socket descriptors"`.
  - Claim impact: tightens native/browser Preview1 socket errno classification
    and preserves output pointer state on non-socket descriptor errors; does not
    complete the parent `P1-SOCKET-CONFORMANCE` row.
- [x] `CM-NESTED-ASYNC-VALUE-VALIDATION` - Component validation rejects nested
  stream/future element shapes before async host binding.
  - Evidence:
    `dart test test/component_test.dart --name "reports nested stream and future element types"`
    failed before the fix because `stream<stream<string>>` and
    `future<stream<string>>` validated cleanly, then passed after the fix;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart --name "validates indexed nested async stream element types before binding"`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart test test/wasi_component_host_test.dart --name "validates nested async stream bindings before binding"`.
  - Claim impact: moves one unsupported P3 async payload shape from host-time
    failure to deterministic component validation; does not complete
    `CM-VALIDATION-GAPS`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-SOCKET-HOST-RECV-PROVIDER-CAP` - Host-backed stream receive providers
  are capped to the requested byte count before buffering.
  - Evidence:
    `dart test test/wasi_test.dart --name "virtual socket receive providers are capped to requested bytes"`
    failed before the fix because oversized provider chunks were buffered past
    the guest request, then passed after the fix;
    `dart test test/wasi_test.dart --name "sock_recv waitall drains chunked host stream providers"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket receive providers are capped to requested bytes"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`;
    `dart analyze`.
  - Claim impact: tightens the host-backed Preview1 stream provider API and
    prevents oversized provider returns from expanding buffered socket memory;
    does not complete the parent `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-HOST-STREAM-WAITALL-CHUNKS` - Host-backed stream
  `RECV_WAITALL` drains chunked providers until the request is satisfied or the
  provider reports no data.
  - Evidence:
    `dart test test/wasi_test.dart --name "sock_recv waitall drains chunked host stream providers"`
    failed before the fix with `_errnoAgain`, then passed after the fix;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv waitall drains chunked host stream providers"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`;
    `dart analyze`.
  - Claim impact: improves host-backed Preview1 stream socket behavior and keeps
    the waitall path visible in `socket_recv_waitall`; does not complete the
    parent `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-DESCRIPTOR-NAMESPACE` - Initial descriptors reject fd namespace
  collisions and invalid virtual allocator starts.
  - Evidence:
    `dart test test/wasi_test.dart --name "virtual socket descriptors reject initial fd collisions"`
    failed on the negative `firstVirtualFd` case before this fix, then passed
    after the fix;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket descriptors reject initial fd collisions"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv and sock_send use configured preview1 stream sockets"`;
    `dart test -p chrome test/wasi_test.dart --name "fd_prestat_get and fd_prestat_dir_name expose configured preopen"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`;
    `dart analyze`.
  - Claim impact: prevents inconsistent Preview1 descriptor kind/rights state
    and negative virtual descriptor allocation in `SUPPORT-P1`; does not
    complete the parent
    `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-RECEIVE-SHUTDOWN-DROPS-BUFFERS` - Receive-side shutdown drops
  unread receive buffers and later host-injected data.
  - Evidence:
    `dart test test/wasi_test.dart --name "virtual socket receive shutdown remains terminal"`
    failed before the fix, then passed after the fix;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket receive shutdown remains terminal"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_shutdown and descriptor rights are enforced for preview1 sockets"`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`;
    `dart analyze`.
  - Claim impact: tightens shared Preview1 stream/datagram shutdown memory and
    receive semantics for `SUPPORT-P1`; does not complete the parent
    `P1-SOCKET-CONFORMANCE` row.
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
  - Required rows: checked spec-runner coverage rows for every remaining
    standardized core feature failure, plus `PERFORMANCE-GATES` for hot compile
    and instantiate paths.
  - Implementation gate:
    `tool/ensure_toolchains.sh --check`;
    `dart run tool/spec_testsuite_runner.dart --suite=core --output-json=.dart_tool/spec_runner/core.json --output-md=.dart_tool/spec_runner/core.md --prepare-root=.dart_tool/spec_runner/core_bundle --conversion-cache-dir=.dart_tool/spec_runner/conversion_cache`;
    `dart test test/wasm_test.dart test/wasm_predecode_test.dart`.
  - Performance gate:
    `dart run tool/doom_instantiate_profile.dart --compile-breakdown --json`;
    `dart run tool/doom_instantiate_profile.dart --instantiate-breakdown --json`.
  - Done when: the core spec runner has no untriaged standardized-feature
    failures, every skipped or failing feature has a linked unchecked row, and
    the compile/instantiate profiles show no unresolved memory or duration
    blocker.
  - Evidence update: verification matrix, detailed backlog, and README support
    wording if public claims change.
- [ ] `SUPPORT-P1` - Full WASI Preview1 support.
  - Current: `WASI(...)` provides a real Preview1 host surface, and the current
    official `WebAssembly/wasi-testsuite` `prod/testsuite-base` run reports
    `PASS: 72 tests passed (41 skipped)`. Keep this row unchecked until the
    package-level Preview1 support claim is reconciled across VM, browser,
    Node delegation, README/API wording, and any non-testsuite Preview1 gaps.
  - Required rows: every Preview1 descriptor, filesystem, stdio, clock, random,
    poll, and socket row checked, including `P1-PATH-OPEN-OFLAGS`,
    `P1-SOCKET-CONFORMANCE` child rows, `P1-OFFICIAL-TESTSUITE-ADAPTER`,
    `P1-OFFICIAL-FS-CONFORMANCE` child rows, and future official testsuite gap
    rows not yet represented by a narrower ID.
  - Implementation gate:
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`;
    `dart test -p node test/wasi_test.dart`;
    `python3 -m py_compile tool/wasi_testsuite_wasd_adapter.py`;
    after cloning `WebAssembly/wasi-testsuite` `prod/testsuite-base`,
    run its `./run-tests --runtime-adapter <wasd>/tool/wasi_testsuite_wasd_adapter.py`
    and record pass/fail deltas as executable rows.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: native, browser, and Node-relevant Preview1 gates pass with
    conformance-shaped coverage, error paths preserve guest memory/output
    pointers, and benchmarks cover descriptor and socket hot paths.
  - Evidence update: verification matrix, detailed backlog, README support
    matrix, and README command/snippet tests when docs or API examples change.
- [ ] `SUPPORT-P2` - Full WASI 0.2 / Preview2 support.
  - Current: the public factory rejects Preview2; internal versioned component
    gates and local synchronous primitive plus `option`/`result` and
    `list`/`tuple` WIT world adapters exist.
  - Required rows: `P2-P3-ADAPTERS`, `WIT-INGESTION`, `CM-VALUE-VALIDATION`,
    resource lifetime rows, and adapter-specific Preview2 interface rows.
  - Implementation gate:
    `dart test test/wasi_component_versioned_host_test.dart`;
    `dart test test/wasi_component_wit_test.dart`;
    every adapter-specific Preview2 test command recorded by the required rows.
    `SUPPORT-P2` cannot be checked until those row-level commands exist and pass.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`;
    add adapter benchmarks for any repeated host-call or value-copy path exposed
    by the required rows.
  - Done when: real Preview2 components bind and execute through versioned
    adapters, WIT/interface ingestion feeds those adapters, public docs/API
    expose only verified behavior, and no Preview1 import path is used as P2
    proof.
  - Evidence update: verification matrix, completion checklist, README support
    matrix, and README snippet/command tests when public API claims change.
- [ ] `SUPPORT-P3` - Full WASI 0.3 / Preview3 support.
  - Current: the public factory rejects Preview3; internal P3 resources, async
    primitives, waitables, tasks, context, thread identity, and copy paths are
    partially executable, and local synchronous primitive plus
    `option`/`result` and `list`/`tuple` WIT world adapters now execute through
    the Preview3 versioned host.
  - Required rows: `P3-VERSIONED-RUN`, `P3-RESOURCE-LIFETIME`,
    `P3-STREAM-FUTURE-SHAPES`, `P3-ASYNC-COPY-GAPS`,
    `P3-TASK-CONTEXT-THREAD`, `PUBLIC-API-DOCS`, `VERSION-GATES`,
    `PERFORMANCE-GATES`, and `FULL-VERIFY`.
  - Implementation gate:
    `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_host_test.dart test/wasi_component_async_host_test.dart test/wasi_component_waitable_set_test.dart test/wasi_component_task_test.dart test/wasi_component_thread_test.dart test/wasi_component_value_memory_test.dart`;
    every adapter-specific Preview3 component execution command recorded by the
    required rows. `SUPPORT-P3` cannot be checked until those row-level commands
    exist and pass.
  - Performance gate:
    `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`;
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`;
    `dart run tool/component_benchmark.dart --json`.
  - Done when: real Preview3 components execute through a versioned host with
    resources, streams, futures, waitables, tasks, async behavior, cancellation,
    and benchmark evidence; helper-only tests are not counted as support proof.
  - Evidence update: verification matrix, completion checklist, README support
    matrix, and README snippet/command tests when public API claims change.

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
| [x] | Preview1 native/browser VFS descriptor subset | `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | `path_open` create/exclusive/truncate is covered; full Preview1 conformance still needs broader syscall/spec-suite gates and remaining socket edges. |
| [x] | Preview1 native/browser fd count-pointer ABI | `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "fd read and write counts can target memory zero"`; `dart test -p chrome test/wasi_test.dart --name "fd read and write counts can target memory zero"`; `dart test test/wasi_test.dart`; `dart test -p chrome test/wasi_test.dart`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Result count pointers at guest memory address `0` now write correctly for stdio and virtual-file fd read/write syscalls; full Preview1 still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser virtual-file fd iovec aliasing and preflight | `lib/src/wasi/preview1/common/vfs.dart`, `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes|fd_pwrite validates all iovs before mutating virtual files"`; `dart test -p chrome test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes|fd_pwrite validates all iovs before mutating virtual files"`; `dart test test/wasi_test.dart`; `dart test -p chrome test/wasi_test.dart`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Virtual-file fd reads now snapshot overlapping iovec tables before guest-memory writes, and virtual-file fd writes preflight every iovec before mutating file bytes; Node still delegates Preview1 to `node:wasi`, and full Preview1 still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser clock and poll-clock validation | `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "clock_time_get"`; `dart test -p chrome test/wasi_test.dart --name "clock_time_get"`; `dart test test/wasi_test.dart --name "poll_oneoff"`; `dart test -p chrome test/wasi_test.dart --name "poll_oneoff"`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Unsupported `clock_time_get` ids now preserve output memory and return `EINVAL`; invalid `poll_oneoff` clock subscriptions now report event `EINVAL`; full Preview1 still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser socket flag preflight | `lib/src/wasi/preview1/common/socket_syscalls.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "sock_recv and sock_send validate flags before descriptor rights"`; `dart test -p chrome test/wasi_test.dart --name "sock_recv and sock_send validate flags before descriptor rights"`; `dart test test/wasi_test.dart --name "sock_recv|sock_send"`; `dart test -p chrome test/wasi_test.dart --name "sock_recv|sock_send"`; `dart test test/wasi_test.dart`; `dart test -p chrome test/wasi_test.dart`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Invalid `sock_recv`/`sock_send` flags now return `EINVAL` before descriptor-right failures and without socket/output side effects; full Preview1 socket conformance still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser socket shutdown `how` preflight | `lib/src/wasi/preview1/common/socket_syscalls.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "sock_shutdown validates how before descriptor state"`; `dart test -p chrome test/wasi_test.dart --name "sock_shutdown validates how before descriptor state"`; `dart test test/wasi_test.dart`; `dart test -p chrome test/wasi_test.dart`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Invalid `sock_shutdown` `how` values now return `EINVAL` before bad-fd, non-socket, or rights errors without mutating socket state; full Preview1 socket conformance still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser socket accept flag preflight | `lib/src/wasi/preview1/common/socket_syscalls.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`; `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`; `dart test test/wasi_test.dart --name "sock_accept|socket descriptor flags|socket syscalls return notsock|datagram sockets do not expose accept rights"`; `dart test -p chrome test/wasi_test.dart --name "sock_accept|socket descriptor flags|socket syscalls return notsock|datagram sockets do not expose accept rights"`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Socket-unsupported `sock_accept` fdflags now return `NOTSUP` before accept-right failures while preserving non-socket/bad-fd errno order and queued accepted sockets; full Preview1 socket conformance still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser socket fdstat flag preflight | `lib/src/wasi/preview1/common/fd_syscalls.dart`, `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags" --reporter=compact`; `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags" --reporter=compact`; `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags|sock_accept|datagram sockets do not expose accept rights|default socket rights expose socket-specific operations only" --reporter=compact`; `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags|sock_accept|datagram sockets do not expose accept rights|default socket rights expose socket-specific operations only" --reporter=compact`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Socket-unsupported `fd_fdstat_set_flags(APPEND)` now returns `NOTSUP` before descriptor-right failures while unknown bits still return `EINVAL` and supported `NONBLOCK` still respects rights; full Preview1 socket conformance still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser socket file-right preflight | `lib/src/wasi/preview1/common/fd_syscalls.dart`, `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "default socket rights expose socket-specific operations only" --reporter=compact`; `dart test -p chrome test/wasi_test.dart --name "default socket rights expose socket-specific operations only" --reporter=compact`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | `fd_allocate` and `fd_filestat_set_size` on default sockets now return `ENOTCAPABLE` through the shared native/browser fd helper before any file lookup; full Preview1 socket conformance still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser socket positioned-right preflight | `lib/src/wasi/preview1/common/fd_syscalls.dart`, `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "positioned fd descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_fdstat_set_rights persists and enforces descriptor rights|path_open creates, exclusively opens, and truncates virtual files|path_open create and truncate require directory rights|fd_pread, fd_pwrite, and fd_write update virtual files|fd_tell, fd_filestat_set_size, and fd_allocate update file size" --reporter=compact`; `dart test -p chrome test/wasi_test.dart --name "positioned fd descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_fdstat_set_rights persists and enforces descriptor rights|path_open creates, exclusively opens, and truncates virtual files|path_open create and truncate require directory rights|fd_pread, fd_pwrite, and fd_write update virtual files|fd_tell, fd_filestat_set_size, and fd_allocate update file size" --reporter=compact`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | `fd_pread`, `fd_pwrite`, `fd_seek`, and `fd_tell` on default sockets now return `ENOTCAPABLE` before file lookup and preserve output pointers; positioned file IO now requires `FD_SEEK` with read/write rights; full Preview1 socket conformance still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser socket filestat-right preflight | `lib/src/wasi/preview1/common/constants.dart`, `lib/src/wasi/preview1/common/fd_syscalls.dart`, `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "fd_filestat_get descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_tell, fd_filestat_set_size, and fd_allocate update file size|fd_filestat_set_times and path_filestat_set_times persist virtual timestamps" --reporter=compact`; `dart test -p chrome test/wasi_test.dart --name "fd_filestat_get descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_tell, fd_filestat_set_size, and fd_allocate update file size|fd_filestat_set_times and path_filestat_set_times persist virtual timestamps" --reporter=compact`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | `fd_filestat_get` now returns `BADF`/`ENOTCAPABLE` before guest-memory validation for unknown or rightless descriptors, preserves filestat output memory on those errors, and shares native/browser filestat layout/write logic; full Preview1 socket conformance still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser stream socket zero-byte send | `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "sock_send and fd_write treat zero-byte stream writes as no-ops" --reporter=compact`; `dart test -p chrome test/wasi_test.dart --name "sock_send and fd_write treat zero-byte stream writes as no-ops" --reporter=compact`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Byte-stream zero-capacity `sock_send` and socket-backed `fd_write` now write `nwritten=0` without being blocked by `writeReady=false`; datagram zero-length messages still take the datagram path, and full Preview1 socket conformance still needs broader gates. |
| [x] | Preview1 native/browser connected stream accept capability | `lib/src/wasi/preview1/socket.dart`, `lib/src/wasi/preview1/common/vfs.dart`, `lib/src/wasi/preview1/common/socket_syscalls.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "connected stream sockets can opt out of accept capability"`; `dart test -p chrome test/wasi_test.dart --name "connected stream sockets can opt out of accept capability|accepted sockets do not inherit listener accept rights by default|sock_accept returns queued preview1 stream sockets with inherited rights|default socket rights expose socket-specific operations only|socket descriptor flags reject file-only flags|datagram sockets do not expose accept rights"`; `dart test test/wasi_test.dart`; `dart test --reporter=compact --concurrency=1`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; `dart analyze` | `WASIPreview1Socket(canAccept: false)` now models connected stream endpoints without `SOCK_ACCEPT`, preserves accept output state on rejected `sock_accept`, and is covered by `socket_connected_rights`; full Preview1 socket conformance still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser stream socket send iovec aliasing | `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs"`; `dart test -p chrome test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs"`; `dart test test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs|virtual socket send handlers stop after partial writes|virtual socket host send handlers reject invalid write counts|sock_recv|sock_send"`; `dart test -p chrome test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs|virtual socket send handlers stop after partial writes|virtual socket host send handlers reject invalid write counts|sock_recv|sock_send"`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Stream `sock_send` now snapshots overlapping iovec tables before host callbacks can mutate guest memory; full Preview1 socket conformance still needs broader syscall/spec-suite gates. |
| [x] | Preview1 native/browser socket recv iovec aliasing | `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart` | `dart test test/wasi_test.dart --name "sock_recv snapshots iovs before writing receive buffers"`; `dart test test/wasi_test.dart --name "sock_recv"`; `dart test -p chrome test/wasi_test.dart --name "sock_recv"`; `dart test test/wasi_test.dart`; `dart test -p chrome test/wasi_test.dart`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` | Stream and datagram `sock_recv` now snapshot overlapping iovec tables before receive-buffer writes; full Preview1 socket conformance still needs broader syscall/spec-suite gates. |
| [x] | Official WASI testsuite adapter for Preview1 command modules | `tool/wasi_testsuite_preview1_runner.dart`, `tool/wasi_testsuite_wasd_adapter.py`, `test/wasi_testsuite_runner_test.dart`, `test/support/wasm_fixtures.dart` | `dart test test/wasi_testsuite_runner_test.dart --reporter=compact`; `dart run tool/wasi_testsuite_preview1_runner.dart --version`; `python3 -m py_compile tool/wasi_testsuite_wasd_adapter.py` | wasd can now be invoked by the official `wasi-testsuite` runner for `wasm32-wasip1` `wasi:cli/command` tests, with `--dir HOST::GUEST` roots snapshotted into the virtual VFS and observed by a real `path_open`/`fd_read` command module; full Preview1 still requires running the external suite and turning failures into checked implementation rows. |
| [x] | Preview1 `fd_renumber` target descriptor preflight | `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "fd_renumber" --reporter=compact`; `dart test -p chrome test/wasi_test.dart --name "fd_renumber" --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/renumber.wasm` | `fd_renumber` now returns `BADF` when the destination descriptor is not open and preserves the source descriptor; the official Preview1 suite dropped from `20/72` failures to `19/72`, so broader filesystem/symlink/directory/inode gaps remain. |
| [x] | Preview1 `fd_close` preopen descriptor close | `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "fd_close closes preopen descriptors without closing opened directories" --reporter=compact`; `dart test -p chrome test/wasi_test.dart --name "fd_close closes preopen descriptors without closing opened directories" --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/close_preopen.wasm` | `fd_close` now closes preopen descriptors through the shared descriptor table while preserving child directory descriptors opened from that preopen; the official Preview1 suite dropped from `19/72` failures to `18/72`, so broader filesystem/symlink/directory/inode gaps remain. |
| [x] | Preview1 `path_open` non-directory base fd preflight | `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "path_open rejects file descriptors as directory bases" --reporter=compact`; `dart test -p chrome test/wasi_test.dart --name "path_open rejects file descriptors as directory bases" --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_open_dirfd_not_dir.wasm` | `path_open` and shared path resolution now distinguish missing descriptors from live non-directory descriptors, returning `BADF` only for the former and `NOTDIR` for the latter; the official Preview1 suite dropped from `18/72` failures to `17/72`, so broader filesystem/symlink/directory/inode gaps remain. |
| [x] | Preview1 directory fd seek-right masking | `lib/src/wasi/preview1/common/constants.dart`, `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "path_open does not grant fd_seek rights to directories" --reporter=compact`; `dart test -p chrome test/wasi_test.dart --name "path_open does not grant fd_seek rights to directories" --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/directory_seek.wasm` | Directory descriptors now mask `FD_SEEK` from base rights at descriptor construction while preserving inheriting rights for child opens; the official Preview1 suite dropped from `17/72` failures to `16/72`, so broader filesystem/symlink/directory/inode gaps remain. |
| [x] | Preview1 virtual file identity and `fd_readdir` paging | `lib/src/wasi/preview1/common/constants.dart`, `lib/src/wasi/preview1/common/vfs.dart`, `lib/src/wasi/preview1/common/fd_syscalls.dart`, `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "filestat and readdir report stable virtual node identities" --reporter=expanded`; `dart test test/wasi_test.dart --name "fd_readdir keeps buffer full while directory entries remain" --reporter=expanded`; `dart test test/wasi_test.dart --reporter=compact`; `dart test -p chrome test/wasi_test.dart --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/stat-dev-ino.wasm`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/fdopendir-with-access.wasm`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fd_readdir.wasm`; `.dart_tool/wasi-testsuite/.venv/bin/python run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_inode_readdir.json --disable-colors`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; `dart test --reporter=compact --concurrency=1`; `dart analyze` | VFS metadata now carries stable `dev`/`ino`/link count, `filestat` and `dirent.d_ino` share that identity, hard links share inode identity, and `fd_readdir` reports a full buffer while more entries remain; the official Preview1 suite dropped from `16/72` failures to `13/72`, so symlink/path edge cases remain. |
| [x] | Preview1 VFS node filestat timestamps | `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "new virtual nodes start with non-zero filestat timestamps" --reporter=expanded`; `dart test test/wasi_test.dart --reporter=compact`; `dart test -p chrome test/wasi_test.dart --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_filestat.wasm`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/symlink_filestat.wasm`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fd_filestat_set.wasm`; `.dart_tool/wasi-testsuite/.venv/bin/python run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_filestat_timestamps.json --disable-colors`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; `dart test --reporter=compact --concurrency=1`; `dart analyze` | Fresh VFS nodes now report non-zero access and modification timestamps through filestat using a single wall-clock seed plus monotonic virtual increments, preserving explicit timestamp setters and dropping the official Preview1 suite from `13/72` failures to `10/72`. |
| [x] | Preview1 trailing-slash path mutation errno | `lib/src/wasi/preview1/common/vfs.dart`, `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "path mutation preserves trailing slash errors" --reporter=expanded`; `dart test test/wasi_test.dart --reporter=compact`; `dart test -p chrome test/wasi_test.dart --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/unlink_file_trailing_slashes.wasm`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_symlink_trailing_slashes.wasm`; `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_trailing_slash.json --disable-colors`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; `dart test --reporter=compact --concurrency=1`; `dart analyze` | `path_unlink_file` and `path_symlink` now preserve the decoded guest trailing-slash bit through native/browser syscall adapters and shared VFS mutation helpers, returning Preview1 `NOTDIR`/`ISDIR`/`NOENT`/`EXIST` without deleting the wrong node; the official Preview1 suite dropped from `10/72` failures to `8/72`. |
| [x] | Preview1 guest path capability boundary and `path_open` slash semantics | `lib/src/wasi/preview1/common/vfs.dart`, `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "path_open rejects absolute, escaping, nul, and file-slash paths" --reporter=expanded`; `dart test -p chrome test/wasi_test.dart --name "path_open rejects absolute, escaping, nul, and file-slash paths" --reporter=expanded`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/interesting_paths.wasm`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/symlink_create.wasm`; `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_decode.json --disable-colors`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; `dart test test/wasi_test.dart --reporter=compact`; `dart test -p chrome test/wasi_test.dart --reporter=compact`; `dart test --reporter=compact --concurrency=1`; `dart analyze` | Guest path decoding now rejects absolute paths and paths that escape the preopen with `NOTCAPABLE`, rejects NUL-containing paths with `INVAL`, keeps file trailing-slash `path_open` failures as `NOTDIR`, allows directory trailing slashes, and rejects absolute symlink targets; the official Preview1 suite dropped from `8/72` failures to `6/72`. |
| [x] | Preview1 `path_link` hard-link and symlink edge semantics | `lib/src/wasi/preview1/common/constants.dart`, `lib/src/wasi/preview1/common/vfs.dart`, `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "path_link handles directory" --reporter=compact`; `dart test test/wasi_test.dart --name "path_symlink and path_readlink preserve" --reporter=compact`; `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`; `dart test -p chrome test/wasi_test.dart --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_link.wasm`; `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_link.json --disable-colors`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_path_link.json` | `path_link` now hard-links regular files and symbolic links without following symlink sources, rejects `LOOKUPFLAGS_SYMLINK_FOLLOW` with `INVAL`, returns `PERM` for directory sources, preserves missing trailing-slash targets as `NOENT`, and drops the official Preview1 suite from `6/72` failures to `5/72`; remaining failures are `nofollow_errors.wasm`, `path_rename.wasm`, `dangling_symlink.wasm`, `symlink_loop.wasm`, and `path_open_preopen.wasm`. |
| [x] | Preview1 no-follow symlink `path_open` loop errno | `lib/src/wasi/preview1/common/constants.dart`, `lib/src/wasi/preview1/common/vfs.dart`, `lib/src/wasi/preview1/native/wasi.dart`, `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "path_open rejects nofollow symlinks" --reporter=compact`; `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`; `dart test -p chrome test/wasi_test.dart --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/nofollow_errors.wasm`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/dangling_symlink.wasm`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/symlink_loop.wasm`; `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_symlink_nofollow.json --disable-colors`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_symlink_nofollow.json` | `path_open` now treats an existing symlink as a symlink node when `LOOKUPFLAGS_SYMLINK_FOLLOW` is absent, returning `LOOP` instead of falling through to `NOENT`; the official Preview1 suite dropped from `5/72` failures to `2/72`, leaving only `path_rename.wasm` and `path_open_preopen.wasm`. |
| [x] | Preview1 `path_rename` directory target semantics | `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "path_rename replaces empty directories" --reporter=compact`; `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`; `dart test -p chrome test/wasi_test.dart --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_rename.wasm`; `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_rename.json --disable-colors`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_path_rename.json` | Directory `path_rename` now replaces empty target directories, rejects non-empty target directories with `NOTEMPTY`, rejects non-directory targets with `NOTDIR`, and drops the official Preview1 suite from `2/72` failures to `1/72`; the only remaining Preview1 failure is `path_open_preopen.wasm`. |
| [x] | Preview1 `path_open` preopen directory rights semantics | `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart` | `dart test test/wasi_test.dart --name "path_open rejects directory read-write" --reporter=compact`; `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`; `dart test -p chrome test/wasi_test.dart --reporter=compact`; `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_open_preopen.wasm`; `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_open_preopen.json --disable-colors`; `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_path_open_preopen.json` | `O_DIRECTORY` opens of preopen directories now allow empty, read-only, and full directory rights while rejecting pure `FD_READ|FD_WRITE` file rights with `ISDIR`; the official Preview1 suite now reports `PASS: 72 tests passed (41 skipped)`. |
| [x] | Component decoder, canonical validation base, canonical option placement, and strong-unique extern names | `lib/src/wasm/backend/native/interpreter/component.dart`, `test/component_test.dart` | `dart test test/component_test.dart` | WIT/world ingestion, structured annotation resource/type rules, and broader official component suite coverage. |
| [x] | Component instantiation import matching for known local child components | `lib/src/wasm/backend/native/interpreter/component.dart`, `test/component_test.dart`, `tool/component_benchmark.dart` | `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments" --reporter=compact`; `dart test test/component_test.dart --reporter=compact`; `dart test test/wasi_component_host_test.dart test/wasi_component_versioned_host_test.dart --reporter=compact`; `dart run tool/component_benchmark.dart --json`; `dart test --reporter=compact --concurrency=1`; `dart analyze` | Known local child component instantiation now rejects unknown argument names, missing required imports, and wrong argument sorts before adapter binding; imported/aliased component targets, cross-component type equivalence, generated worlds, and official suite coverage remain open. |
| [x] | Component task-return borrow validation | `lib/src/wasm/backend/native/interpreter/component.dart`, `test/component_test.dart`, `tool/component_benchmark.dart` | `dart test test/component_test.dart --name "reports task.return result types containing borrow|reports missing canonical option requirements|reports invalid canonical result value type indexes" --reporter=compact`; `dart run tool/component_benchmark.dart --json` | Borrowed canonical `task.return` results are now rejected during validation; broader borrow, stream, future, nested-shape, generated-world, and component-suite coverage remains. |
| [x] | Resource table plus decoded `resource.*` host binding | `lib/src/wasi/component/resource_table.dart`, `lib/src/wasi/component/resource_host.dart`, `test/wasi_component_resource_table_test.dart`, `test/wasi_component_resource_host_test.dart` | `dart test test/wasi_component_resource_table_test.dart test/wasi_component_resource_host_test.dart` | Full Canonical ABI ownership/drop integration across generated adapters. |
| [x] | Versioned Preview2/Preview3 capability gates | `lib/src/wasi/component/versioned_host.dart`, `lib/src/wasi/preview2/component_host.dart`, `lib/src/wasi/preview3/component_host.dart`, `test/wasi_component_versioned_host_test.dart` | `dart test test/wasi_component_versioned_host_test.dart` | Concrete P2/P3 interface adapter modules instead of generic facade binding. |
| [x] | Internal P3 async endpoints, waitables, tasks, context, thread identity | `lib/src/wasi/component/async_host.dart`, `lib/src/wasi/component/waitable_set.dart`, `lib/src/wasi/component/task.dart`, `lib/src/wasi/component/thread.dart`, `test/wasi_component_async_host_test.dart` | `dart test test/wasi_component_async_host_test.dart test/wasi_component_waitable_set_test.dart test/wasi_component_task_test.dart test/wasi_component_thread_test.dart` | Full async lowering, task spawning, scheduler-owned thread switch/suspend/resume. |
| [x] | Owned-resource stream/future copy buffers, pending copy events, and cancel-copy events through async, component, and versioned Preview3 hosts | `lib/src/wasi/component/value_memory.dart`, `test/wasi_component_async_host_test.dart`, `test/wasi_component_host_test.dart`, `test/wasi_component_versioned_host_test.dart`, `test/support/component_fixtures.dart` | `dart test test/wasi_component_host_test.dart test/wasi_component_versioned_host_test.dart test/wasi_component_async_host_test.dart test/wasi_component_value_memory_test.dart`; `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`; `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json` | Borrowed payload lifetimes, broader composite async payload execution, and public P3 API claims remain unsupported. |
| [x] | P3 flags stream canonical memory copy and host value validation | `lib/src/wasi/component/value_memory.dart`, `test/wasi_component_value_memory_test.dart`, `test/wasi_component_async_host_test.dart`, `tool/wasi_component_async_benchmark.dart` | `dart test test/wasi_component_value_memory_test.dart test/wasi_component_async_host_test.dart --name "rejects duplicate flag labels before writing memory|copies decoded flags stream values through canonical memory" --reporter=compact`; `dart test test/wasi_component_value_memory_test.dart --reporter=compact`; `dart test test/wasi_component_async_host_test.dart --reporter=compact`; `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json` | Decoded `stream<flags>` now round-trips through canonical memory and duplicate host-side flag labels fail before memory writes/enqueues; broader composite stream/future shapes, waitable coverage for this shape, generated-world binding, and public P3 support remain incomplete. |
| [x] | Canonical variant/option/result selector consistency through P3 option stream copy | `lib/src/wasi/component/value_memory.dart`, `test/wasi_component_value_memory_test.dart`, `test/wasi_component_async_host_test.dart`, `tool/wasi_component_async_benchmark.dart` | `dart test test/wasi_component_value_memory_test.dart test/wasi_component_async_host_test.dart --name "rejects conflicting variant case selectors before writing memory|rejects conflicting option stream value selectors" --reporter=compact`; `dart test test/wasi_component_value_memory_test.dart --reporter=compact`; `dart test test/wasi_component_async_host_test.dart --reporter=compact`; `dart test test/wasi_component_host_test.dart --reporter=compact`; `dart test test/wasi_component_versioned_host_test.dart --reporter=compact`; `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json` | Conflicting selector fields now fail before canonical memory writes or stream endpoint mutation, and valid `stream<option<u32>>` values copy through canonical memory with a dedicated benchmark; full P2/P3 support still needs generated world binding, official-style component runs, and broader async/value shapes. |
| [x] | P3 future char Unicode-scalar validation before canonical memory copy | `lib/src/wasi/component/unicode_scalar.dart`, `lib/src/wasi/component/async_host.dart`, `lib/src/wasi/component/value_memory.dart`, `lib/src/wasi/component/adapter_host.dart`, `test/wasi_component_async_host_test.dart`, `test/wasi_component_value_memory_test.dart` | `dart test test/wasi_component_async_host_test.dart --name "rejects non-scalar char future values before memory copies"`; `dart test test/wasi_component_value_memory_test.dart --name "rejects non-scalar char stores"`; `dart test test/wasi_component_async_host_test.dart`; `dart test test/wasi_component_value_memory_test.dart`; `dart test test/wasi_component_adapter_plan_test.dart`; `dart test test/wasi_component_host_test.dart`; `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`; `dart analyze` | Full Preview3 still needs generated world/interface ingestion, official component-suite style runs, and broader async shape coverage. |
| [x] | Canonical variant/option/result payload validation before value-memory writes | `lib/src/wasi/component/value_memory.dart`, `test/wasi_component_value_memory_test.dart`, `tool/wasi_resource_table_benchmark.dart` | `dart test test/wasi_component_value_memory_test.dart --name "rejects invalid variant payloads before writing memory" --reporter=compact`; `dart test test/wasi_component_value_memory_test.dart --reporter=compact`; `dart test test/wasi_component_async_host_test.dart --reporter=compact`; `dart test test/wasi_component_host_test.dart --reporter=compact`; `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`; `dart analyze` | Invalid payloadless or missing-payload variant stores now fail before discriminant writes, and valid variant stores are measured by `canonical_variant_store`; full P2/P3 support still needs WIT ingestion, generated world binding, and broader component-suite runs. |
| [x] | Canonical lift/lower adapter planning and internal callback invocation | `lib/src/wasi/component/adapter_plan.dart`, `lib/src/wasi/component/adapter_host.dart`, `test/wasi_component_adapter_plan_test.dart` | `dart test test/wasi_component_adapter_plan_test.dart`; `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json` | Automatic binding of decoded lift/lower definitions to instantiated core/component functions. |
| [ ] | Preview1 full socket conformance | Add focused regressions under `test/wasi_test.dart` and VFS/socket benchmarks | `dart test test/wasi_test.dart`; `dart run tool/wasi_vfs_benchmark.dart --json` | Native adapter boundaries and broader socket conformance remain incomplete. |
| [x] | WIT package/interface/world boundary parser | `lib/src/wasi/component/wit_document.dart`, `test/wasi_component_wit_test.dart` | `dart test test/wasi_component_wit_test.dart`; `dart analyze` | Parser evidence alone does not unlock P2/P3 support; it only feeds adapter binding. |
| [x] | P2/P3 WIT world version-profile ingestion | `lib/src/wasi/component/wit_document.dart`, `lib/src/wasi/component/versioned_host.dart`, `lib/src/wasi/preview2/component_host.dart`, `lib/src/wasi/preview3/component_host.dart`, `test/wasi_component_wit_test.dart`, `test/wasi_component_versioned_host_test.dart` | `dart test test/wasi_component_wit_test.dart test/wasi_component_versioned_host_test.dart --name "parses annotated|ingest WIT worlds" --reporter=expanded`; `dart test test/wasi_component_wit_test.dart test/wasi_component_versioned_host_test.dart test/wasi_component_host_test.dart --reporter=compact`; `dart run tool/component_benchmark.dart --json > .dart_tool/component_benchmark_after_wit_ingestion.json` | Annotated Preview3 WIT function/import/include boundaries, including nested resource methods, now feed a fixed P2/P3 version-profile preflight: Preview2 rejects P3 async functions, streams, futures, and `@0.3.0` includes, while Preview3 accepts the same world for adapter binding preflight. Generated multi-package world binding and executable interface adapters remain open. Component benchmark stayed at `57.325us/iter` decode and `112.59us/iter` validate. |
| [x] | P2/P3 primitive WIT world adapter binding | `lib/src/wasi/component/versioned_host.dart`, `lib/src/wasi/component/wit_adapter.dart`, `test/wasi_component_versioned_host_test.dart`, `tool/wasi_resource_table_benchmark.dart` | `dart test test/wasi_component_versioned_host_test.dart --name "WIT world adapters" --reporter=expanded`; `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`; `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json` | Local synchronous primitive WIT import/export functions now expand once during planning and execute through Preview2/Preview3 adapter callbacks with primitive value validation. Generated multi-package worlds, complex Canonical ABI shapes, and async WIT adapters remain open. |
| [x] | P2/P3 composite WIT world adapter binding | `lib/src/wasi/component/wit_adapter.dart`, `test/wasi_component_versioned_host_test.dart`, `tool/wasi_resource_table_benchmark.dart` | `dart test test/wasi_component_versioned_host_test.dart --name "composite WIT values" --reporter=expanded`; `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`; `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json` | Local synchronous `option<T>` and `result<T, E>` WIT values now bind through Preview2/Preview3 adapter callbacks over existing `WasmComponentValueData` trees with selector and payload-kind validation before callbacks run. Generated multi-package worlds, records/lists/variants/resources, and async WIT adapters remain open. |
| [x] | P2/P3 list/tuple WIT world adapter binding | `lib/src/wasi/component/wit_adapter.dart`, `test/wasi_component_versioned_host_test.dart`, `tool/wasi_resource_table_benchmark.dart` | `dart test test/wasi_component_versioned_host_test.dart --name "list and tuple WIT values" --reporter=expanded`; `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json` | Local synchronous `list<T>` and `tuple<T...>` WIT values now bind through Preview2/Preview3 adapter callbacks over existing `WasmComponentValueData` trees with recursive element/field validation and tuple arity checks. Generated multi-package worlds, cross-interface records, variants/resources, and async WIT adapters remain open. |
| [x] | P2/P3 named record WIT world adapter binding | `lib/src/wasi/component/wit_document.dart`, `lib/src/wasi/component/wit_adapter.dart`, `test/wasi_component_wit_test.dart`, `test/wasi_component_versioned_host_test.dart`, `tool/wasi_resource_table_benchmark.dart` | `dart test test/wasi_component_wit_test.dart --name "local record" --reporter=expanded`; `dart test test/wasi_component_versioned_host_test.dart --name "named WIT record" --reporter=expanded`; `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`; `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json` | Local same-interface WIT `record` declarations now parse and resolve by name in synchronous Preview2/Preview3 adapter signatures, with recursive field validation over supported payload types and record arity checks. Generated multi-package worlds, cross-interface type resolution, variants/resources, and async WIT adapters remain open. |
| [ ] | P2/P3 generated multi-package/async world adapter binding | Bind imported/generated WIT worlds through executable Preview2/Preview3 adapters, including complex value shapes and Preview3 async WIT functions | Future gate: generated WIT fixtures plus component-host binding/execution tests | No public claim until generated/imported worlds bind to executable adapters through versioned hosts, and async worlds execute through the P3 scheduler path. |
| [ ] | Full WASI 0.3 support | Real P3 components through versioned host with resources, streams, futures, waitables, tasks, and async behavior | Future gate: wasi-testsuite-style component runs plus performance gates | Current work is internal capability coverage, not full P3 support. |

## Current wasd Baseline

This is the implementation state as of 2026-06-23 on `main`.

- Preview 1 is real but still incomplete. Native and browser hosts share
  `lib/src/wasi/preview1/common/vfs.dart` for virtual files, directories,
  readdir state, hard links, symlinks/readlink, configured stream/datagram
  sockets, descriptor flags, descriptor rights, descriptor times, descriptor
  sync/advice validation, clock/file/socket polling readiness including
  host-supplied socket readiness hints, `clock_time_get` unsupported-id
  validation, `poll_oneoff` clock subscription validation, fd read/write count
  outputs at guest memory address zero, virtual-file fd read/write iovec
  preflight and aliasing protection, positioned file IO requiring `FD_SEEK`
  with read/write capability, socket descriptor file-only and positioned-fd
  capability preflight before file lookup, socket syscall invalid/unsupported
  flag and shutdown `how` preflight before descriptor/right checks, `sock_recv`
  and stream `sock_send` iovec aliasing protection, host-backed
  stream/datagram receive/send handlers, accept queue preservation on
  unsupported descriptor flags, and descriptor renumbering.
  Node still delegates Preview 1 behavior to `node:wasi`.
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
  socket send paths preflight the complete iovec array before mutating guest
  memory, consuming receive data, recording sent bytes, or reporting
  shutdown/write-ready socket state. `sock_shutdown` validates its ABI `how`
  bitmask before descriptor lookup, so invalid shutdown flags do not leak fd
  existence, socket type, rights, or shutdown side effects. Virtual-file fd
  reads now share the same iovec validation/snapshot discipline, and
  virtual-file fd writes preflight all iovecs before mutating file bytes.
  `sock_recv` and virtual-file fd reads snapshot iovec descriptors only when
  output buffers overlap the iovec table, preserving syscall-start iov semantics
  without adding allocation to ordinary non-overlapping reads. This matches the
  datagram path's all-or-error validation boundary. `fd_pread`, `fd_pwrite`,
  `fd_seek`, and `fd_tell` now run through a shared native/browser positioned-fd
  helper, so valid socket descriptors without positioned-file rights report
  `ENOTCAPABLE` and preserve output pointers instead of being misclassified as
  bad file descriptors. `fd_filestat_get` now shares descriptor/capability
  preflight and filestat layout writes across native/browser hosts, so unknown
  descriptors and rightless sockets report `BADF`/`ENOTCAPABLE` before guest
  memory validation and leave output memory untouched on those errors.
- Preview 1 `path_open` now honors `O_CREAT`, `O_CREAT|O_EXCL`, and `O_TRUNC`
  over shared native/browser VFS state. File creation updates the same path
  indexes and directory child maps as rename/link/unlink, exclusive create
  leaves the output-fd pointer untouched on `EEXIST`, and create/truncate check
  the directory descriptor's path rights before mutating VFS state.
- Preview 1 directory entries are indexed through per-directory child maps so
  common path/link/symlink mutation paths rebuild only affected directories.
  File lookup fallback indexes are also maintained as ordered path buckets, so
  hard-link, rename, and unlink mutations update only touched lower-path and
  basename keys instead of rebuilding every file lookup index. Empty-directory
  removal uses the same child map instead of scanning every virtual path.
  The benchmark entrypoint is
  `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; it reports
  baseline, directory-heavy, descriptor-heavy, and socket-heavy distributions.
  It also covers virtual-file fd read/write iovec loops, socket multi-iov
  peek/waitall, datagram truncation, socket send/recv including host-backed
  stream/datagram handlers and write-side and read-side would-block behavior,
  socket shutdown preflight, socket positioned-right preflight, socket filestat
  right preflight, socket polling readiness including zero-length datagram
  readiness, queued accepts, externally backed read/write readiness hints, and
  socket renumber/close descriptor paths.
  Stream socket sends are recorded as owned byte chunks, and long receive
  streams compact consumed prefixes in larger batches so socket-heavy reads do
  not repeatedly shift the backing buffer. Default datagram socket sends now
  transfer the VFS-owned message buffer into the socket record path instead of
  copying it a second time, while caller-owned `writeMessage` lists still keep
  defensive copy semantics. The owned-buffer hook is hidden from the public
  `package:wasd/wasi.dart` export so the user-facing socket API stays small.
- The repository now includes `tool/wasi_testsuite_wasd_adapter.py` and
  `tool/wasi_testsuite_preview1_runner.dart`, allowing the upstream
  `WebAssembly/wasi-testsuite` runner to invoke wasd for `wasm32-wasip1`
  `wasi:cli/command` modules. The runner maps testsuite env/argv inputs into
  `WASI`, snapshots `--dir HOST::GUEST` host roots into the in-memory Preview1
  VFS, and returns the module's `proc_exit` code. Its regression fixture opens
  and reads a snapshotted file through `path_open`/`fd_read`, so this is a real
  command-module entry point rather than an empty adapter shell. This is still a
  conformance entry point only; full Preview1 support requires running the
  external suite and converting failures into checked implementation rows.
- The official `WebAssembly/wasi-testsuite` `prod/testsuite-base` run now
  reports `PASS: 72 tests passed (41 skipped)`. Passing former failures now
  include `renumber.wasm`,
  `close_preopen.wasm`, `path_open_dirfd_not_dir.wasm`,
  `directory_seek.wasm`, `fd_readdir.wasm`, `stat-dev-ino.wasm`,
  `fdopendir-with-access.wasm`, `path_filestat.wasm`,
  `symlink_filestat.wasm`, `fd_filestat_set.wasm`,
  `unlink_file_trailing_slashes.wasm`,
  `path_symlink_trailing_slashes.wasm`, `interesting_paths.wasm`,
  `symlink_create.wasm`, `path_link.wasm`, `nofollow_errors.wasm`,
  `dangling_symlink.wasm`, `symlink_loop.wasm`, `path_rename.wasm`, and
  `path_open_preopen.wasm`; no Preview1 failures remain in this official
  command-module gate. The Preview3
  skips are a real unsupported-state signal, not a pass result or a support
  claim.
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
  signatures and argument value types. Component validation also tracks the
  component index space with nullable local component entries, so instantiating
  a known local child component now rejects unknown import argument names,
  missing required imports, and argument sort mismatches without misidentifying
  imported or aliased component indexes as local definitions. The resource host
  can bind those imported or aliased abstract resources with an unconstrained
  host representation.
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
  being approximated. Host-side decoded variant, option, and result values must
  use internally consistent selectors before canonical memory writes or async
  endpoint enqueues; conflicting fields fail instead of being silently
  prioritized. Future P3 adapters can route stream/future
  memory lowering through this shared codec without re-deriving byte widths,
  alignments, padding, or dynamic payload allocation separately from the
  executable copy path.
  An internal WIT document boundary parser now normalizes package, interface,
  world, import, and export declarations into structured objects with
  line/column diagnostics for duplicate names and unresolved local world
  references. This is a parser/input boundary for future Preview2/Preview3
  adapter binding, not WIT-generated execution or a public P2/P3 support claim.
  Versioned WIT world adapter plans can now execute local synchronous primitive
  functions plus `option<T>`, `result<T, E>`, `list<T>`, `tuple<T...>`, and
  same-interface named `record` value trees through Preview2 and Preview3
  callbacks over `WasmComponentValueData`; selector conflicts, tuple arity
  mismatches, record arity mismatches, and nested primitive payload-kind
  mismatches fail at the adapter boundary. Generated multi-package WIT,
  cross-interface named type resolution, variants/resources, and async WIT
  execution remain future work.
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

1. `SUPPORT-P1`
   - Why: the official Preview1 command-module gate is now green, but the
     package-level support claim still needs a VM/browser/Node, README/API, and
     non-testsuite gap audit before it can be checked honestly.
   - Do not: let the green Preview1 filesystem gate imply Preview2 or Preview3
     support, and do not count skipped Preview3 tests as support.
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

- [x] `P1-SOCKET-SEND-IOV-SNAPSHOT` - Stream `sock_send` snapshots overlapping
  iovec tables before host send callbacks can mutate guest memory.
  - Scope: native/browser shared Preview1 stream socket send iovec aliasing in
    `lib/src/wasi/preview1/common/vfs.dart`.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs"`
    failed before the fix with `Actual: [65, 98, 97, 100]` instead of
    `Expected: [65, 111, 107, 33]` after the first host callback mutated a
    send buffer overlapping the next iovec descriptor.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs"`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs"`;
    `dart test test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs|virtual socket send handlers stop after partial writes|virtual socket host send handlers reject invalid write counts|sock_recv|sock_send"`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket stream send snapshots overlapping iovs|virtual socket send handlers stop after partial writes|virtual socket host send handlers reject invalid write counts|sock_recv|sock_send"`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_send_recv.operations=56000`,
    `socket_send_recv.per_operation_us=0.22196428571428573`,
    `socket_send_error_preflight.operations=48000`,
    `socket_send_error_preflight.per_operation_us=0.00975`,
    `socket_fd_read_write.operations=32000`, and
    `socket_fd_read_write.per_operation_us=0.2335` for the socket-heavy
    distribution.
  - Done when: mutating host stream send callbacks cannot corrupt later iovec
    descriptors, while non-overlapping stream sends and datagram sends avoid
    snapshot allocation for this guard.
  - Evidence update: this checked row plus `Current Execution Board`,
    `Verification Matrix`, and `Current wasd Baseline`.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete Preview1 full support or any P2/P3 support gate.
- [x] `P1-SOCKET-ACCEPT-FLAG-PREFLIGHT` - `sock_accept` validates
  socket-unsupported fdflags before accept rights.
  - Scope: native/browser shared Preview1 stream socket accept validation in
    `lib/src/wasi/preview1/common/socket_syscalls.dart`.
  - Edit targets: `lib/src/wasi/preview1/common/socket_syscalls.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`
    failed before the fix with `Actual: <76>` instead of `Expected: <58>` after
    accept rights were stripped.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`;
    `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`;
    `dart test test/wasi_test.dart --name "sock_accept|socket descriptor flags|socket syscalls return notsock|datagram sockets do not expose accept rights"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_accept|socket descriptor flags|socket syscalls return notsock|datagram sockets do not expose accept rights"`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_accept_inheritance.operations=16000`,
    `socket_accept_inheritance.per_operation_us=0.0898125`,
    `socket_accept_receive_shutdown.operations=16000`,
    `socket_accept_receive_shutdown.per_operation_us=0.0215625`,
    `socket_poll_readiness.operations=80000`, and
    `socket_poll_readiness.per_operation_us=0.074125` for the socket-heavy
    distribution.
  - Done when: unsupported accept fdflags return `NOTSUP` before
    descriptor-right errors while preserving output pointer and queued accepted
    socket state.
  - Evidence update: this checked row plus `Current Execution Board`,
    `Verification Matrix`, and `Current wasd Baseline`.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete Preview1 full support or any P2/P3 support gate.
- [x] `P1-SOCKET-FLAG-PREFLIGHT` - `sock_recv` and `sock_send` validate ABI
  flags before descriptor/socket/right state.
  - Scope: native/browser shared Preview1 stream and datagram socket syscall
    validation in `lib/src/wasi/preview1/common/socket_syscalls.dart`.
  - Edit targets: `lib/src/wasi/preview1/common/socket_syscalls.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_recv and sock_send validate flags before descriptor rights"`
    failed before the fix with `Actual: <76>` instead of `Expected: <28>`
    after descriptor rights were stripped.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_recv and sock_send validate flags before descriptor rights"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv and sock_send validate flags before descriptor rights"`;
    `dart test test/wasi_test.dart --name "sock_recv|sock_send"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv|sock_send"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_recv_peek.operations=8000`,
    `socket_recv_peek.per_operation_us=0.146`,
    `socket_recv_waitall.operations=24000`,
    `socket_recv_waitall.per_operation_us=0.48625`,
    `socket_send_recv.operations=56000`,
    `socket_send_recv.per_operation_us=0.20760714285714285`,
    `socket_send_error_preflight.operations=48000`,
    `socket_send_error_preflight.per_operation_us=0.009395833333333334`,
    `socket_fd_read_write.operations=32000`, and
    `socket_fd_read_write.per_operation_us=0.2274375` for the socket-heavy
    distribution.
  - Done when: invalid flags return `EINVAL` before descriptor/right errors and
    before any socket data or output pointer side effects.
  - Evidence update: this checked row plus `Current Execution Board`,
    `Verification Matrix`, and `Current wasd Baseline`.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete Preview1 full support or any P2/P3 support gate.
- [x] `P1-SOCKET-SHUTDOWN-HOW-PREFLIGHT` - `sock_shutdown` validates `how`
  before descriptor/socket/right state.
  - Scope: native/browser shared Preview1 `sock_shutdown` ABI validation
    ordering and receive/send shutdown side effects.
  - Edit targets: `lib/src/wasi/preview1/common/socket_syscalls.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_shutdown validates how before descriptor state"`
    failed before the fix with `Expected: <28>` and `Actual: <8>` when an
    unknown fd was passed with an invalid `how` bitmask.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_shutdown validates how before descriptor state"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_shutdown validates how before descriptor state"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_shutdown_preflight.operations=10000`,
    `socket_shutdown_preflight.per_operation_us=0.0972`,
    `socket_shutdown_preflight.operations=40000`, and
    `socket_shutdown_preflight.per_operation_us=0.02065` for the baseline and
    socket-heavy distributions respectively. The implementation is a
    constant-time bitmask check before descriptor lookup.
  - Done when: invalid `how` returns `EINVAL` before fd/socket/right errors and
    leaves valid socket receive/send shutdown state unchanged.
  - Evidence update: this checked row plus `Current Execution Board`,
    `Verification Matrix`, and `Current wasd Baseline`.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete Preview1 full support or any P2/P3 support gate.
- [x] `P1-SOCKET-RECV-IOV-SNAPSHOT` - `sock_recv` snapshots overlapping iovec
  tables before writing receive buffers.
  - Scope: native/browser shared Preview1 stream and datagram `sock_recv` iovec
    aliasing semantics in `lib/src/wasi/preview1/common/vfs.dart`.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_recv snapshots iovs before writing receive buffers"`
    failed before the fix with a `RangeError` when the first receive buffer
    overlapped and corrupted the second iovec table entry.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_recv snapshots iovs before writing receive buffers"`;
    `dart test test/wasi_test.dart --name "sock_recv"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_recv_peek.operations=8000`,
    `socket_recv_peek.per_operation_us=0.14575`,
    `socket_recv_waitall.operations=24000`,
    `socket_recv_waitall.per_operation_us=0.4800833333333333`,
    `socket_send_recv.operations=56000`,
    `socket_send_recv.per_operation_us=0.20007142857142857`,
    `socket_fd_read_write.operations=32000`, and
    `socket_fd_read_write.per_operation_us=0.22259375` for the socket-heavy
    distribution. Snapshot allocation is conditional on receive-buffer/iovec-table
    overlap, so the common non-overlapping socket recv path remains allocation-free
    for this guard.
  - Done when: stream and datagram socket receives both preserve the original
    iovec descriptors even when receive buffers overlap the iovec table, and the
    benchmark keeps socket recv hot paths visible.
  - Evidence update: this checked row plus `Current Execution Board`,
    `Verification Matrix`, and `Current wasd Baseline`.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete Preview1 full support or any P2/P3 support gate.
- [x] `P1-FD-COUNT-PTR-ZERO` - Preview1 fd count outputs may target memory
  address zero.
  - Scope: native/browser Preview1 stdio and virtual-file `fd_read`,
    `fd_write`, `fd_pread`, and `fd_pwrite` result count pointers.
  - Edit targets: `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "fd read and write counts can target memory zero"`
    failed before the fix because a successful stdio `fd_write` skipped writing
    the count when `nwritten` was address `0`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd read and write counts can target memory zero"`;
    `dart test -p chrome test/wasi_test.dart --name "fd read and write counts can target memory zero"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_fd_read_write.operations=32000`,
    `socket_fd_read_write.per_operation_us=0.237125`,
    `socket_poll_readiness.operations=80000`, and
    `socket_poll_readiness.per_operation_us=0.0749` for the socket-heavy
    distribution. The change removes the false optional-pointer branch and keeps
    the result pointer check constant-time before the iovec loop.
  - Done when: address `0` is a valid count-output pointer for stdio and
    virtual-file fd read/write syscalls on native and browser hosts, and invalid
    count pointers fail before host IO side effects.
  - Evidence update: this checked row plus `Current Execution Board`,
    `Verification Matrix`, and `Current wasd Baseline`.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-FD-IOV-SNAPSHOT-PREFLIGHT` - Virtual-file fd read/write iovec
  descriptors are validated before side effects and snapshotted when read
  buffers overlap the iovec table.
  - Scope: native/browser Preview1 virtual-file `fd_read`, `fd_pread`,
    `fd_write`, and `fd_pwrite` iovec validation and memory-aliasing semantics.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes"`
    failed before the fix with `Expected: 'ok!'` and `Actual: '___'`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes"`;
    `dart test -p chrome test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes"`;
    `dart test test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes|fd_pwrite validates all iovs before mutating virtual files"`;
    `dart test -p chrome test/wasi_test.dart --name "fd_pread snapshots overlapping iovs before writing file bytes|fd_pwrite validates all iovs before mutating virtual files"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `file_fd_read_write.operations=4000` and
    `file_fd_read_write.per_operation_us=0.3525` for baseline, and
    `file_fd_read_write.operations=16000` and
    `file_fd_read_write.per_operation_us=0.0370625` for socket-heavy. The fix
    allocates an iovec snapshot only on read aliasing and keeps writes on a
    validation-only path before file mutation.
  - Done when: overlapping read buffers cannot redirect later virtual-file read
    segments, and invalid later write iovecs cannot leave partially mutated
    virtual-file contents or result counts.
  - Evidence update: this checked row plus `Current Execution Board`,
    `Verification Matrix`, and `Current wasd Baseline`.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-POLL-ZERO-SUBSCRIPTIONS` - `poll_oneoff` reports `EINVAL` for an empty
  subscription set.
  - Scope: native/browser Preview1 `poll_oneoff` ABI validation and guest-memory
    side effects when `nsubscriptions == 0`.
  - Edit targets: `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "poll_oneoff rejects zero subscriptions without memory side effects"`
    failed before the fix because `poll_oneoff` returned success and wrote
    `nevents=0`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "poll_oneoff rejects zero subscriptions without memory side effects"`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff rejects zero subscriptions without memory side effects"`;
    `dart test test/wasi_test.dart --name "poll_oneoff"`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff"`;
    `dart test test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; the
    branch is an early ABI validation check before the poll event loop and does
    not add work to non-empty poll or socket readiness paths.
  - Done when: native and browser shims both return `EINVAL` for zero
    subscriptions, leave `nevents` and the event buffer unchanged, and still pass
    the existing poll/socket readiness regressions.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-SOCKET-DGRAM-READINESS-HINT` - Datagram sockets honor host read
  readiness hints in `poll_oneoff(fd_read)`.
  - Scope: shared Preview1 native/browser socket poll readiness and the
    host-facing `WASIPreview1Socket.datagram(readReadyBytes: ...)` API.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "poll_oneoff reports host socket readiness hints" --reporter=compact`
    failed before the fix because a datagram socket with `readReadyBytes=5`
    left `nevents=0`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "poll_oneoff reports host socket readiness hints" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff reports host socket readiness hints" --reporter=compact`;
    `dart test test/wasi_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_poll_readiness.operations=22000`,
    `socket_poll_readiness.per_operation_us=0.4178636363636364` on the
    baseline distribution and `socket_poll_readiness.operations=88000`,
    `socket_poll_readiness.per_operation_us=0.07564772727272727` on the
    socket-heavy distribution.
  - Done when: queued datagram messages still win over readiness hints, positive
    host hints produce fd_read readiness when no message is materialized, zero
    hints remain not-ready, and focused VM/Chrome tests agree.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete the parent `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-FILE-RIGHTS-PREFLIGHT` - File-only fd mutation syscalls on
  socket descriptors fail as capability errors before file lookup.
  - Scope: shared Preview1 native/browser descriptor errno ordering for
    `fd_allocate` and `fd_filestat_set_size` on configured socket descriptors.
  - Edit targets: `lib/src/wasi/preview1/common/fd_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "default socket rights expose socket-specific operations only" --reporter=compact`
    failed before the fix because `fd_allocate` returned `BADF(8)` for a valid
    socket descriptor that lacked `FD_ALLOCATE` rights.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "default socket rights expose socket-specific operations only" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "default socket rights expose socket-specific operations only" --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_file_rights_preflight.operations=4000` and
    `socket_file_rights_preflight.per_operation_us=0.10475` on the baseline
    distribution, plus `socket_file_rights_preflight.operations=16000` and
    `socket_file_rights_preflight.per_operation_us=0.0638125` on the
    socket-heavy distribution.
  - Done when: default sockets return `ENOTCAPABLE` for `fd_allocate` and
    `fd_filestat_set_size`, the same helper still returns `BADF` for unknown
    descriptors, real files still allocate/truncate through the same shared
    helper, and VM/Chrome focused gates agree.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry and the verification matrix.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete the parent `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-STREAM-ZERO-SEND` - Zero-byte stream socket writes bypass
  write-readiness state as no-ops.
  - Scope: shared Preview1 native/browser byte-stream `sock_send` and
    socket-backed `fd_write` zero-capacity writes.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_send and fd_write treat zero-byte stream writes as no-ops" --reporter=compact`
    failed before the fix because a valid zero-length iovec on a blocked stream
    returned `EAGAIN(6)` instead of `SUCCESS` with `nwritten=0`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_send and fd_write treat zero-byte stream writes as no-ops" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "sock_send and fd_write treat zero-byte stream writes as no-ops" --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_stream_zero_send.operations=2000` and
    `socket_stream_zero_send.per_operation_us=0.0665` on the baseline
    distribution, plus `socket_stream_zero_send.operations=8000` and
    `socket_stream_zero_send.per_operation_us=0.023375` on the socket-heavy
    distribution.
  - Done when: zero-capacity byte-stream writes still validate the iovec table
    and output pointer, preserve send-side shutdown errors, bypass
    `writeReady=false`, write `nwritten=0`, and leave sent byte buffers empty.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry and the verification matrix.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete the parent `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-POSITIONED-RIGHTS-PREFLIGHT` - Positioned fd operations on
  socket descriptors fail as capability errors before file lookup.
  - Scope: shared Preview1 native/browser `fd_pread`, `fd_pwrite`, `fd_seek`,
    and `fd_tell` descriptor/right/file preflight.
  - Edit targets: `lib/src/wasi/preview1/common/fd_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "default socket rights expose socket-specific operations only" --reporter=compact`
    failed before the fix because `fd_pread` on a valid socket returned
    `BADF(8)` instead of `ENOTCAPABLE(76)`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "positioned fd descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_fdstat_set_rights persists and enforces descriptor rights|path_open creates, exclusively opens, and truncates virtual files|path_open create and truncate require directory rights|fd_pread, fd_pwrite, and fd_write update virtual files|fd_tell, fd_filestat_set_size, and fd_allocate update file size" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "positioned fd descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_fdstat_set_rights persists and enforces descriptor rights|path_open creates, exclusively opens, and truncates virtual files|path_open create and truncate require directory rights|fd_pread, fd_pwrite, and fd_write update virtual files|fd_tell, fd_filestat_set_size, and fd_allocate update file size" --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_positioned_rights_preflight.operations=8000` and
    `socket_positioned_rights_preflight.per_operation_us=0.5745` on the
    baseline distribution, plus
    `socket_positioned_rights_preflight.operations=32000` and
    `socket_positioned_rights_preflight.per_operation_us=0.07315625` on the
    socket-heavy distribution.
  - Done when: valid sockets report `ENOTCAPABLE` for positioned fd operations,
    output pointers stay untouched on those errors, unknown descriptors still
    report `BADF`, real file positioned IO requires `FD_SEEK` alongside
    read/write capability, and native/browser imports share the same helper.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, the verification matrix, and the benchmark
    metric.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete the parent `P1-SOCKET-CONFORMANCE` row.
- [x] `P1-SOCKET-FILESTAT-RIGHTS-PREFLIGHT` - `fd_filestat_get` descriptor and
  capability errors preflight guest-memory validation.
  - Scope: shared Preview1 native/browser `fd_filestat_get` descriptor,
    capability, memory, filetype, size, and timestamp ordering.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/fd_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "fd_filestat_get descriptor errors do not require bound memory" --reporter=compact`
    failed before the fix because an unknown descriptor with no bound memory
    returned `EINVAL(28)` instead of `BADF(8)`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd_filestat_get descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_tell, fd_filestat_set_size, and fd_allocate update file size|fd_filestat_set_times and path_filestat_set_times persist virtual timestamps" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "fd_filestat_get descriptor errors do not require bound memory|default socket rights expose socket-specific operations only|fd_tell, fd_filestat_set_size, and fd_allocate update file size|fd_filestat_set_times and path_filestat_set_times persist virtual timestamps" --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `socket_filestat_rights_preflight.operations=4000` and
    `socket_filestat_rights_preflight.per_operation_us=0.73825` on the baseline
    distribution, plus
    `socket_filestat_rights_preflight.operations=16000` and
    `socket_filestat_rights_preflight.per_operation_us=0.1220625` on the
    socket-heavy distribution.
  - Done when: unknown descriptors return `BADF` before memory lookup, valid
    descriptors lacking `FD_FILESTAT_GET` return `ENOTCAPABLE` before output
    pointer validation, filestat output remains unchanged on those errors,
    successful socket filestat writes still expose socket filetypes, existing
    file size/timestamp filestat tests still pass, and native/browser imports
    share the same helper.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, the verification matrix, and the benchmark
    metric.
  - Claim impact: contributes to `P1-SOCKET-CONFORMANCE` and `SUPPORT-P1`; does
    not complete the parent `P1-SOCKET-CONFORMANCE` row or any
    `SUPPORT-P1`/`SUPPORT-P2`/`SUPPORT-P3` gate.
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
- [x] `P1-OFFICIAL-TESTSUITE-ADAPTER` - Add a wasd runtime adapter for the
  official WASI testsuite Preview1 command runner.
  - Scope: subprocess conformance entrypoint for `wasm32-wasip1`
    `wasi:cli/command` modules using wasd's native Preview1 host.
  - Edit targets: `tool/wasi_testsuite_preview1_runner.dart`,
    `tool/wasi_testsuite_wasd_adapter.py`,
    `test/wasi_testsuite_runner_test.dart`, `test/support/wasm_fixtures.dart`,
    and this roadmap.
  - Red test: before this row there was no testsuite-compatible adapter or
    runner that accepted testsuite `args/env/root` inputs and invoked
    `WASI.start` on a command module.
  - Implementation gate:
    `dart test test/wasi_testsuite_runner_test.dart --reporter=compact`;
    `dart run tool/wasi_testsuite_preview1_runner.dart --version`;
    `python3 -m py_compile tool/wasi_testsuite_wasd_adapter.py`;
    manual smoke
    `dart run tool/wasi_testsuite_preview1_runner.dart /tmp/wasd-wasi-exit7.wasm`
    returned process exit code `7` for a generated `_start -> proc_exit(7)`
    module; the checked regression now uses a command module that reads
    `/input.txt` through `path_open`/`fd_read` and exits `0` only after seeing
    the expected bytes.
  - Performance gate: N/A; this is a conformance harness entrypoint. The
    runner snapshots `--dir HOST::GUEST` files once per subprocess before
    instantiation and does not alter VFS syscall hot paths.
  - Done when: the Python adapter exposes `get_name`, `get_version`,
    `get_wasi_versions`, `get_wasi_worlds`, and `compute_argv`; it declares only
    `wasm32-wasip1` and `wasi:cli/command`; the Dart runner executes a real
    WASI command module with env, argv, and preopened virtual files; and the
    repository has a regression test for the runner subprocess.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, `SUPPORT-P1`, verification matrix, and current
    baseline.
  - Claim impact: creates the official Preview1 testsuite gate needed to expose
    real conformance failures; does not complete `P1-SOCKET-CONFORMANCE`,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P1-GUEST-PATH-CAPABILITY-BOUNDARY` - Preserve the Preview1 guest path
  sandbox boundary during path decoding and `path_open`.
  - Scope: native/browser shared Preview1 guest path decode for path syscalls,
    trailing slash behavior for `path_open`, and absolute symlink target
    rejection.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open rejects absolute, escaping, nul, and file-slash paths" --reporter=expanded`
    failed before the fix because absolute guest paths were normalized under
    the preopen and opened successfully.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open rejects absolute, escaping, nul, and file-slash paths" --reporter=expanded`;
    `dart test -p chrome test/wasi_test.dart --name "path_open rejects absolute, escaping, nul, and file-slash paths" --reporter=expanded`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/interesting_paths.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/symlink_create.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_decode.json --disable-colors`
    reported `6/72` Preview1 failures after the fix, down from `8/72`;
    `dart test test/wasi_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `path_open_close` at `1.3065us/op` baseline, `0.6965us/op`
    directory-heavy, `0.692us/op` descriptor-heavy, and `0.697625us/op`
    socket-heavy. The implementation computes all guest-path flags during the
    existing decode pass and does not add directory traversal.
  - Done when: path syscalls reject absolute and preopen-escaping paths with
    `NOTCAPABLE`, reject NUL-containing paths with `INVAL`, preserve output fd
    pointers on failures, allow directory trailing slashes, reject file trailing
    slashes with `NOTDIR`, and reject absolute symlink targets.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, and current baseline.
  - Claim impact: closes two official Preview1 testsuite failures for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-SYMLINK-NOFOLLOW-OPEN-LOOP` - Return `LOOP` when `path_open`
  sees a symlink without follow lookup flags.
  - Scope: native/browser shared Preview1 `path_open` errno behavior for
    symlink, dangling symlink, and self-referential symlink nodes when
    `LOOKUPFLAGS_SYMLINK_FOLLOW` is absent.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open rejects nofollow symlinks" --reporter=compact`
    failed before the fix with `Expected: <32> Actual: <44>` because symlink
    nodes fell through to the missing-path case.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open rejects nofollow symlinks" --reporter=compact`;
    `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/nofollow_errors.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/dangling_symlink.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/symlink_loop.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_symlink_nofollow.json --disable-colors`
    reported `2/72` Preview1 failures after the fix, down from `5/72`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_symlink_nofollow.json`
    reported `path_open_close` at `1.422us/op` baseline, `0.7265us/op`
    directory-heavy, `0.708us/op` descriptor-heavy, and `0.76525us/op`
    socket-heavy.
  - Done when: no-follow `path_open` on directory symlink, dangling symlink,
    and self-loop symlink returns `LOOP`; symlink-follow directory opens still
    succeed; and the three official modules pass.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, `SUPPORT-P1`, ordered
    execution queue, and current baseline.
  - Claim impact: closes three official Preview1 testsuite failures for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-PATH-OPEN-PREOPEN-DIRECTORY-RIGHTS` - Match Preview1
  `path_open` preopen directory read/write rights semantics.
  - Scope: native/browser shared Preview1 VFS `path_open`, especially
    `O_DIRECTORY` opens of preopen directories with empty, read-only, full
    directory, and pure file read/write rights.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open rejects directory read-write" --reporter=expanded`
    failed before the fix with `Expected: <31> Actual: <0>` because pure
    `FD_READ|FD_WRITE` rights opened a directory successfully instead of
    returning `ISDIR`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open rejects directory read-write" --reporter=compact`;
    `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_open_preopen.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_open_preopen.json --disable-colors`
    reported `PASS: 72 tests passed (41 skipped)`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_path_open_preopen.json`
    reported `path_open_close` at `1.398us/op` baseline, `0.775us/op`
    directory-heavy, `0.703us/op` descriptor-heavy, and `0.903us/op`
    socket-heavy.
  - Done when: empty, read-only, and full directory rights still open
    preopened directories with `O_DIRECTORY`; pure `FD_READ|FD_WRITE` file
    rights return `ISDIR`; and the official `path_open_preopen.wasm` module
    passes.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, `SUPPORT-P1`, ordered
    execution queue, and current baseline.
  - Claim impact: closes the last official Preview1 testsuite failure for the
    command-module gate; does not complete Preview2 or Preview3 support.
- [x] `P1-PATH-RENAME-DIRECTORY-TARGETS` - Match Preview1 `path_rename`
  directory target replacement semantics.
  - Scope: native/browser shared Preview1 VFS `path_rename`, especially
    directory source replacement of missing, empty-directory, non-empty
    directory, and non-directory targets.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_rename replaces empty directories" --reporter=compact`
    failed before the fix with `Expected: <0> Actual: <20>` because directory
    renames treated existing empty directory targets as `EXIST`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_rename replaces empty directories" --reporter=compact`;
    `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_rename.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_rename.json --disable-colors`
    reported `1/72` Preview1 failures after the fix, down from `2/72`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_path_rename.json`
    reported mutation cost at `8.854us/op` baseline, `12.546us/op`
    directory-heavy, `5.875us/op` descriptor-heavy, and `5.524us/op`
    socket-heavy.
  - Done when: empty target directories are replaced, non-empty target
    directories return `NOTEMPTY`, non-directory targets return `NOTDIR`, and
    the official `path_rename.wasm` module passes.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, `SUPPORT-P1`, ordered
    execution queue, and current baseline.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-PATH-LINK-EDGE-SEMANTICS` - Match Preview1 `path_link` official
  hard-link and symlink edge semantics.
  - Scope: native/browser shared Preview1 `path_link` syscall behavior,
    regular-file hard links, symlink hard links without source following,
    directory-source errno, trailing-slash target errno, and symlink metadata
    link-count release on unlink.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_link handles directory" --reporter=compact`
    failed before the fix with `Expected: <63> Actual: <31>` because directory
    sources returned `ISDIR` instead of `PERM`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_link handles directory" --reporter=compact`;
    `dart test test/wasi_test.dart --name "path_symlink and path_readlink preserve" --reporter=compact`;
    `dart test test/wasi_test.dart test/wasm_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_link.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_path_link.json --disable-colors`
    reported `5/72` Preview1 failures after the fix, down from `6/72`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json > .dart_tool/wasi_vfs_benchmark_after_path_link.json`
    reported `mutations_benchmark` at `7.893571428571429us/op` baseline,
    `9.092857142857143us/op` directory-heavy, `5.385us/op`
    descriptor-heavy, and `5.177142857142857us/op` socket-heavy.
  - Done when: the official `path_link.wasm` module passes; `path_link`
    rejects `LOOKUPFLAGS_SYMLINK_FOLLOW` with `INVAL`; hard-linking a symlink
    creates another symlink directory entry with shared metadata; directory
    sources return `PERM`; missing trailing-slash targets return `NOENT`; and
    native/browser hosts share the same mapping.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, `SUPPORT-P1`, ordered
    execution queue, and current baseline.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-TRAILING-SLASH-PATH-MUTATIONS` - Preserve trailing slash errors for
  Preview1 path mutation syscalls.
  - Scope: native/browser shared Preview1 guest path decoding and VFS mutation
    semantics for `path_unlink_file` and `path_symlink`.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path mutation preserves trailing slash errors" --reporter=expanded`
    failed before the fix because `path_unlink_file("file.txt/")` returned
    success and removed the file instead of returning `NOTDIR`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path mutation preserves trailing slash errors" --reporter=expanded`;
    `dart test test/wasi_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/unlink_file_trailing_slashes.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_symlink_trailing_slashes.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python .dart_tool/wasi-testsuite/run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_trailing_slash.json --disable-colors`
    reported `8/72` Preview1 failures after the fix, down from `10/72`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `mutations_benchmark` at `9.469285714285714us/op` baseline,
    `13.462857142857143us/op` directory-heavy,
    `6.211428571428572us/op` descriptor-heavy, and
    `5.648571428571429us/op` socket-heavy. The trailing separator is decoded
    once at the syscall boundary and passed as a bit to VFS mutation helpers.
  - Done when: trailing slash on a file path returns `NOTDIR` without deleting
    the file, trailing slash on a directory returns the operation-specific
    directory/exists errno, missing trailing-slash link paths return `NOENT`,
    and official `unlink_file_trailing_slashes.wasm` plus
    `path_symlink_trailing_slashes.wasm` pass.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, and current baseline.
  - Claim impact: closes two official Preview1 testsuite failures for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-NODE-METADATA-TIMESTAMPS` - Fresh VFS nodes report non-zero access
  and modification times.
  - Scope: VFS metadata creation for snapshotted files, newly created files,
    directories, and symlinks, as observed through Preview1 `filestat`.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "new virtual nodes start with non-zero filestat timestamps" --reporter=expanded`
    failed before the fix because fresh VFS nodes reported zero atime/mtime and
    official Rust tests underflowed when subtracting from `mtim`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "new virtual nodes start with non-zero filestat timestamps" --reporter=expanded`;
    `dart test test/wasi_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_filestat.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/symlink_filestat.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fd_filestat_set.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_filestat_timestamps.json --disable-colors`
    reported `10/72` Preview1 failures after the fix, down from `13/72`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `readdir` at `0.489us/op` baseline, `0.3215us/op` directory-heavy,
    `0.276us/op` descriptor-heavy, and `0.30625us/op` socket-heavy. The
    timestamp allocator uses one wall-clock seed and cheap increments instead
    of per-node system clock calls.
  - Done when: all fresh VFS node kinds report non-zero atime/mtime, explicit
    `fd_filestat_set_times` and `path_filestat_set_times` continue to persist
    exact requested values, and the three official filestat timestamp modules
    pass.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, and current baseline.
  - Claim impact: closes three official Preview1 testsuite failures for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-FILE-IDENTITY-AND-READDIR-PAGING` - Add stable virtual node identity
  and non-EOF `fd_readdir` paging.
  - Scope: native/browser shared Preview1 VFS node metadata, hard-link identity,
    directory-entry inode cache, `fd_filestat_get`, `path_filestat_get`, and
    `fd_readdir` buffer semantics.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/common/fd_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red tests:
    `dart test test/wasi_test.dart --name "filestat and readdir report stable virtual node identities" --reporter=expanded`
    failed before the fix because directory `fd_filestat_get` reported inode
    `0`; `dart test test/wasi_test.dart --name "fd_readdir keeps buffer full while directory entries remain" --reporter=expanded`
    failed before the fix with `8` entries instead of `102`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "filestat and readdir report stable virtual node identities" --reporter=expanded`;
    `dart test test/wasi_test.dart --name "fd_readdir keeps buffer full while directory entries remain" --reporter=expanded`;
    `dart test test/wasi_test.dart --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/stat-dev-ino.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/c/testsuite/wasm32-wasip1/fdopendir-with-access.wasm`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fd_readdir.wasm`;
    `.dart_tool/wasi-testsuite/.venv/bin/python run-tests --runtime-adapter /Users/seven/workspace/wasd/tool/wasi_testsuite_wasd_adapter.py --json-output-location /Users/seven/workspace/wasd/.dart_tool/wasi_testsuite_wasd_p1_after_inode_readdir.json --disable-colors`
    reported `13/72` Preview1 failures after the fix, down from `16/72`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` reported
    `readdir` at `0.4415us/op` baseline, `0.3085us/op` directory-heavy,
    `0.297us/op` descriptor-heavy, and `0.292375us/op` socket-heavy. The
    implementation assigns identity at node creation/mutation and caches inode
    on directory entries, avoiding per-`fd_readdir` path lookup.
  - Done when: `filestat.dev` and `filestat.ino` are stable and non-zero for
    VFS nodes, separate files have separate inodes, hard links share inode and
    link count, `dirent.d_ino` matches `filestat.ino`, and `fd_readdir`
    returns `bufused == bufferLength` while entries remain.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, and current baseline.
  - Claim impact: closes three official Preview1 testsuite failures for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-FD-RENUMBER-TARGET-PREFLIGHT` - `fd_renumber` requires an open
  destination descriptor.
  - Scope: native/browser shared Preview1 descriptor table behavior in
    `Preview1VirtualFileSystem.renumberDescriptor`.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test: update the existing `fd_renumber` regression that previously
    allowed renumbering a virtual file descriptor into a closed destination fd;
    the official `renumber.wasm` failure reported
    `fd_renumber should not allow renumbering to invalid destination file descriptors`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd_renumber" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "fd_renumber" --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/renumber.wasm`;
    upstream `wasi-testsuite` rerun with the wasd adapter reported `19/72`
    Preview1 failures after the fix, down from `20/72`.
  - Performance gate: N/A; descriptor existence preflight is constant-time and
    not on the fd IO hot path.
  - Done when: invalid destination fds return `BADF` without closing or moving
    the source descriptor, valid destination fds still get replaced, and
    `from == to` remains success for an open descriptor.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, and current baseline.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-FD-CLOSE-PREOPEN` - `fd_close` closes preopen directory descriptors.
  - Scope: native/browser shared Preview1 descriptor table behavior in
    `Preview1VirtualFileSystem.close`.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "fd_close closes preopen descriptors without closing opened directories" --reporter=compact`
    failed before the fix because `fd_close(3)` returned `BADF` for the
    configured preopen descriptor even after a child directory descriptor opened
    from that preopen remained valid.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd_close closes preopen descriptors without closing opened directories" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "fd_close closes preopen descriptors without closing opened directories" --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/close_preopen.wasm`;
    upstream `wasi-testsuite` rerun with the wasd adapter reported `18/72`
    Preview1 failures after the fix, down from `19/72`.
  - Performance gate: N/A; `close` now uses the existing constant-time
    descriptor presence and cleanup helpers instead of separate cleanup
    branches.
  - Done when: closing a preopen fd succeeds, later `fd_fdstat_get` and
    `fd_prestat_get` on that fd return `BADF`, and an opened directory fd
    derived from that preopen still reports `FILETYPE_DIRECTORY`.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, and current baseline.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-PATH-OPEN-DIRFD-NOT-DIR` - `path_open` distinguishes missing fds from
  non-directory base fds.
  - Scope: native/browser shared Preview1 path syscall descriptor preflight for
    `dirfd` arguments.
  - Edit targets: `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open rejects file descriptors as directory bases" --reporter=compact`
    failed before the fix with `BADF` for a live regular-file descriptor used
    as `path_open`'s directory base.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open rejects file descriptors as directory bases" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "path_open rejects file descriptors as directory bases" --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/path_open_dirfd_not_dir.wasm`;
    upstream `wasi-testsuite` rerun with the wasd adapter reported `17/72`
    Preview1 failures after the fix, down from `18/72`.
  - Performance gate: N/A; this adds one descriptor-kind lookup before path
    resolution and does not alter directory traversal or path lookup indexing.
  - Done when: nonexistent `dirfd` values return `BADF`, file/socket/stdio
    descriptors return `NOTDIR`, directory and preopen descriptors continue
    through normal right and memory preflight, and failed `path_open` preserves
    the output fd pointer.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, and current baseline.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-DIRECTORY-NO-SEEK-RIGHT` - Directory descriptors mask `FD_SEEK` from
  base rights.
  - Scope: shared Preview1 VFS directory descriptor capability modeling for
    native/browser hosts.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open does not grant fd_seek rights to directories" --reporter=compact`
    failed before the fix because a directory opened with requested
    `FD_SEEK` exposed that bit in `fd_fdstat_get`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open does not grant fd_seek rights to directories" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "path_open does not grant fd_seek rights to directories" --reporter=compact`;
    `dart tool/wasi_testsuite_preview1_runner.dart --dir .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/fs-tests.dir::/ .dart_tool/wasi-testsuite/tests/rust/testsuite/wasm32-wasip1/directory_seek.wasm`;
    upstream `wasi-testsuite` rerun with the wasd adapter reported `16/72`
    Preview1 failures after the fix, down from `17/72`.
  - Performance gate: N/A; the change is a descriptor-construction mask and
    does not add repeated syscall work.
  - Done when: directory fdstat base rights exclude `FD_SEEK`, `fd_seek` on the
    descriptor returns `ENOTCAPABLE` before output mutation, and inheriting
    rights remain available for later child opens.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry, verification matrix, and current baseline.
  - Claim impact: closes one official Preview1 testsuite failure for
    `SUPPORT-P1`; does not complete Preview1 full support or any P2/P3 gate.
- [x] `P1-SOCKET-CONNECTED-ACCEPT-CAPABILITY` - Connected stream sockets do not
  expose listener accept capability.
  - Scope: native/browser shared Preview1 `WASIPreview1Socket` host API,
    descriptor rights, and `sock_accept` behavior for stream descriptors that
    are connected endpoints rather than listeners.
  - Evidence:
    `dart test test/wasi_test.dart --name "connected stream sockets can opt out of accept capability" --reporter=compact`
    failed before the fix because the stream socket constructor had no
    `canAccept` capability switch; after the fix, focused VM and Chrome
    accept/right tests passed, `dart test test/wasi_test.dart --reporter=compact`
    and `dart test --reporter=compact --concurrency=1` passed, and
    `dart analyze` reported no issues.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json` now
    includes `socket_connected_rights`, with baseline
    `operations=6000`, `per_operation_us=0.06766666666666667`, and socket-heavy
    `operations=24000`, `per_operation_us=0.015833333333333335`.
  - Done when: `WASIPreview1Socket(canAccept: false)` creates a stream
    descriptor without `SOCK_ACCEPT`, cannot gain `SOCK_ACCEPT` through
    `fd_fdstat_set_rights`, rejects queued accepts on the host object, preserves
    the accepted-fd output pointer on `sock_accept`, and listener streams retain
    their existing accept/inheritance behavior.
  - Claim impact: tightens the Preview1 socket capability model for connected
    stream descriptors; it does not complete the parent
    `P1-SOCKET-CONFORMANCE` row or any `SUPPORT-P1`/`SUPPORT-P2`/`SUPPORT-P3`
    gate.
- [x] `P1-SOCKET-POLL-WRITE-HANGUP` - `poll_oneoff(fd_write)` reports hangup
  after send-side socket shutdown.
  - Scope: shared Preview1 native/browser socket write readiness, send-side
    shutdown state, and poll fd-write event flags.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "poll_oneoff reports socket write readiness and rights errors"`
    failed before the fix because the send-shutdown fd_write subscription wrote
    `nevents=0` instead of an fd_write event with `FD_READWRITE_HANGUP`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "poll_oneoff reports socket write readiness and rights errors"`;
    `dart test test/wasi_test.dart --name "poll_oneoff reports socket write readiness and rights errors|poll_oneoff reports host socket readiness hints|sock_send reports pipe after write-side shutdown"`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff reports socket write readiness and rights errors|poll_oneoff reports host socket readiness hints|sock_send reports pipe after write-side shutdown"`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; the
    socket-heavy distribution reported `socket_poll_readiness.operations=80000`
    and `socket_poll_readiness.per_operation_us=0.073925`.
  - Done when: `sock_shutdown(SD_WR)` makes `poll_oneoff(fd_write)` produce a
    ready fd_write event with zero bytes and `FD_READWRITE_HANGUP`,
    `writeReady=false` remains a would-block not-ready state, and the shared
    socket poll benchmark names the affected readiness path.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-SOCKET-SEND-ERROR-PREFLIGHT` - Socket send iovec validation wins over
  shutdown and write-ready error states.
  - Scope: shared Preview1 native/browser `sock_send` and VFS socket write error
    ordering for stream and datagram descriptors.
  - Edit targets: `lib/src/wasi/preview1/common/socket_syscalls.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    focused test initially named
    `sock_send validates iovs before send-side shutdown state` failed before the
    fix because send-side shutdown returned `EPIPE` before the invalid iov was
    checked; the final checked test is named
    `sock_send validates iovs before socket send error states`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_send validates iovs before socket send error states"`;
    `dart test test/wasi_test.dart --name "sock_send validates iovs before socket send error states|sock_send reports pipe after write-side shutdown|sock_recv and sock_send validate stream iovs before side effects"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_send validates iovs before socket send error states|sock_send reports pipe after write-side shutdown|sock_recv and sock_send validate stream iovs before side effects"`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; the
    socket-heavy distribution reported
    `socket_send_error_preflight.operations=48000` and
    `socket_send_error_preflight.per_operation_us=0.011375`.
  - Done when: invalid send iovs return `EINVAL` before shutdown or would-block
    state, valid iovs still report `EPIPE`/`EAGAIN`, `nwritten` remains
    unchanged, no stream/datagram send queues are mutated, and the benchmark
    names this error preflight path.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-SOCKET-ACCEPT-RECEIVE-SHUTDOWN` - Listener receive shutdown terminates
  pending accepts without fd side effects.
  - Scope: shared Preview1 stream listener shutdown state, `sock_accept`,
    `poll_oneoff(fd_read)`, and VFS accept queue behavior.
  - Edit targets: `lib/src/wasi/preview1/socket.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_accept stops after listener receive shutdown without fd side effects"`
    failed before the fix because `sock_accept` returned `SUCCESS` after
    `sock_shutdown(SD_RD)` and allocated an accepted fd.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_accept stops after listener receive shutdown without fd side effects"`;
    `dart test test/wasi_test.dart --name "sock_accept stops after listener receive shutdown without fd side effects|poll_oneoff reports queued socket accepts as readable|sock_accept returns queued preview1 stream sockets with inherited rights|sock_shutdown and descriptor rights are enforced for preview1 sockets|poll_oneoff reports preview1 socket read readiness and hangup"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_accept stops after listener receive shutdown without fd side effects|poll_oneoff reports queued socket accepts as readable|sock_accept returns queued preview1 stream sockets with inherited rights|sock_shutdown and descriptor rights are enforced for preview1 sockets|poll_oneoff reports preview1 socket read readiness and hangup"`;
    `dart test test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; the
    socket-heavy distribution reported
    `socket_accept_receive_shutdown.operations=16000` and
    `socket_accept_receive_shutdown.per_operation_us=0.043625`.
  - Done when: receive shutdown clears queued accepts, `poll_oneoff(fd_read)`
    reports hangup, `sock_accept` returns `EAGAIN` without changing the output
    fd pointer, and no accepted fd is allocated.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-SOCKET-DATAGRAM-RIGHTS-NARROW` - Datagram sockets do not expose
  listener-only `SOCK_ACCEPT` capability.
  - Scope: shared Preview1 VFS default socket rights for injected datagram
    descriptors and native/browser fdstat-visible capability behavior.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "datagram sockets do not expose accept rights"`
    failed before the fix because datagram fdstat base rights included
    `SOCK_ACCEPT`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "datagram sockets do not expose accept rights"`;
    `dart test test/wasi_test.dart --name "datagram sockets do not expose accept rights|sock_accept returns queued preview1 stream sockets with inherited rights|default socket rights expose socket-specific operations only|sock_recv reports truncation for datagram sockets|sock_recv peek preserves datagram messages and sock_send records datagrams|fd_read and fd_write operate on preview1 socket descriptors"`;
    `dart test -p chrome test/wasi_test.dart --name "datagram sockets do not expose accept rights|sock_accept returns queued preview1 stream sockets with inherited rights|default socket rights expose socket-specific operations only|sock_recv reports truncation for datagram sockets|sock_recv peek preserves datagram messages and sock_send records datagrams|fd_read and fd_write operate on preview1 socket descriptors"`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; the
    socket-heavy distribution reported `socket_datagram_rights.operations=16000`
    and `socket_datagram_rights.per_operation_us=0.019875`.
  - Done when: default datagram socket base rights equal connection rights
    without `SOCK_ACCEPT`, inheriting rights are zero, attempts to grant
    `SOCK_ACCEPT` fail with `ENOTCAPABLE`, and stream listener accept rights
    still work.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-SOCKET-FD-READ-WRITE` - Generic fd IO works on injected Preview1
  socket descriptors.
  - Scope: native/browser `fd_read` and `fd_write` dispatch for configured
    stream/datagram `WASIPreview1Socket` descriptors, including would-block output
    pointer side effects and the fd-style socket read path with no `roflags`
    result pointer.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, `README.md`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "fd_read and fd_write operate on preview1 socket descriptors"`
    failed before the fix because `fd_read` returned `BADF(8)` for a configured
    socket descriptor.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "fd_read and fd_write operate on preview1 socket descriptors"`;
    `dart test -p chrome test/wasi_test.dart --name "fd_read and fd_write operate on preview1 socket descriptors"`;
    `dart test test/wasi_test.dart`;
    `dart test test/readme_snippets_test.dart test/readme_commands_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; the
    socket-heavy distribution reported `socket_fd_read_write.operations=32000`.
  - Done when: stream and datagram sockets can be read/written through generic fd
    IO, would-block reads/writes leave output counters unchanged, browser and
    native shims share the same VFS socket helpers, and README support wording
    names socket `fd_read`/`fd_write`.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-SOCKET-RIGHTS-NARROW` - Default injected socket descriptors do not grant
  file-only rights.
  - Scope: shared Preview1 VFS default rights for configured stream/datagram
    socket descriptors and native/browser fdstat-visible capability behavior.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "default socket rights expose socket-specific operations only"`
    failed before the fix because `fd_fdstat_get` exposed `rightsAll` for an
    injected socket descriptor.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "default socket rights expose socket-specific operations only"`;
    `dart test -p chrome test/wasi_test.dart --name "default socket rights expose socket-specific operations only|fd_read and fd_write operate on preview1 socket descriptors|sock_recv and sock_send use configured preview1 stream sockets|sock_accept returns queued preview1 stream sockets with inherited rights|sock_shutdown and descriptor rights are enforced for preview1 sockets"`;
    `dart test test/wasi_test.dart --name "socket"`;
    `dart test test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; the
    socket-heavy distribution reported `rights_checks.operations=4096000` and
    `socket_fd_read_write.operations=32000`.
  - Done when: default socket fdstat rights contain fd read/write, fdstat set
    flags/get, poll, shutdown, and accept rights; file-only sync/advice/timestamp
    rights are absent; `fd_advise`, `fd_datasync`, `fd_sync`, and
    `fd_filestat_set_times` return `ENOTCAPABLE` on default sockets; native and
    browser socket IO/shutdown/accept regressions still pass.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-SOCKET-ACCEPT-INHERITING-RIGHTS` - Accepted socket descriptors inherit
  connection rights, not listener rights.
  - Scope: shared Preview1 VFS default socket inheriting rights and
    native/browser `sock_accept` capability propagation.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "accepted sockets do not inherit listener accept rights by default"`
    failed before the fix because the accepted socket fdstat base rights included
    `SOCK_ACCEPT`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "accepted sockets do not inherit listener accept rights by default"`;
    `dart test -p chrome test/wasi_test.dart --name "accepted sockets do not inherit listener accept rights by default|default socket rights expose socket-specific operations only|sock_accept returns queued preview1 stream sockets with inherited rights|poll_oneoff reports queued socket accepts as readable|poll_oneoff gates queued socket accepts on sock_accept rights"`;
    `dart test test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`; the
    socket-heavy distribution reported
    `socket_accept_inheritance.operations=16000`.
  - Done when: default listener sockets keep `SOCK_ACCEPT` in base rights, remove
    it from inheriting rights, accepted sockets can still read their queued data,
    accepted fdstat inheriting rights are zero, and `sock_accept` on an accepted
    socket fails with `ENOTCAPABLE` without mutating the output pointer.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-SOCKET-ADAPTER-BOUNDARY` - Native and browser socket imports share one
  Preview1 adapter boundary.
  - Scope: native/browser `sock_accept`, `sock_recv`, `sock_send`, and
    `sock_shutdown` import adapters over shared Preview1 socket/VFS semantics.
  - Edit targets:
    `lib/src/wasi/preview1/common/socket_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, and this roadmap.
  - Red test: N/A for this behavior-preserving adapter extraction; existing
    native and Chrome socket regressions guard the preserved error ordering and
    output-pointer behavior.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "socket syscalls return notsock for non-socket descriptors"`;
    `dart test test/wasi_test.dart --name "sock_shutdown and descriptor rights are enforced for preview1 sockets"`;
    `dart test -p chrome test/wasi_test.dart --name "socket syscalls return notsock for non-socket descriptors"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_shutdown and descriptor rights are enforced for preview1 sockets"`;
    `dart test test/wasi_test.dart`; `dart analyze`.
  - Performance gate: N/A; this moves existing branch logic into one shared
    adapter helper and does not add loops, allocation, or socket hot-path work.
  - Done when: native and browser socket imports both delegate to the shared
    helper, existing native/browser socket regressions pass, and no public API
    or support claim changes.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: reduces Preview1 adapter drift risk; no direct support gate.
- [x] `P1-PATH-OPEN-OFLAGS` - `path_open` implements Preview1 file creation,
  exclusive create, and truncation over shared native/browser VFS state.
  - Scope: native/browser Preview1 `path_open` handling for `O_CREAT`,
    `O_EXCL`, and `O_TRUNC`, including output-fd side effects and directory
    rights.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/common/vfs.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `README.md`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "path_open creates, exclusively opens, and truncates virtual files"`
    failed before the fix because `O_CREAT` returned `ENOENT(44)` for a
    missing file.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "path_open"`;
    `dart test -p chrome test/wasi_test.dart --name "path_open"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`;
    creation/truncation updates the existing VFS maps and per-directory child
    indexes without adding broad scans.
  - Done when: `O_CREAT` creates an in-memory file, `O_CREAT|O_EXCL` rejects an
    existing file without changing the output fd pointer, `O_TRUNC` clears an
    existing file, and create/truncate fail with `ENOTCAPABLE` when the
    directory descriptor lacks the required path rights.
  - Evidence update: this checked row, the `Current Execution Board`
    `Recently Checked` entry, README support wording, and the verification
    matrix.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    support or any P2/P3 support gate.
- [x] `P1-SOCKET-POLL-ACCEPT-RIGHTS` - Socket accept readiness is gated by
  `SOCK_ACCEPT`, not generic `FD_READ`.
  - Scope: native/browser shared Preview1 `poll_oneoff(fd_read)` readiness for
    stream sockets with queued accepts.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "poll_oneoff gates queued socket accepts on sock_accept rights"`
    failed before the fix because a listener descriptor with
    `POLL_FD_READWRITE | SOCK_ACCEPT` but no `FD_READ` reported
    `ENOTCAPABLE(76)`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "poll_oneoff"`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: queued accept readiness reports ready when the descriptor has
    `POLL_FD_READWRITE | SOCK_ACCEPT`, reports `ENOTCAPABLE` when the descriptor
    only has `POLL_FD_READWRITE | FD_READ`, and ordinary stream/datagram read
    readiness continues to use `FD_READ`.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
- [x] `P1-SOCKET-POLL-PROVIDER-READINESS` - Host-backed stream providers feed
  `poll_oneoff(fd_read)` readiness without a separate readiness hint.
  - Scope: native/browser shared Preview1 `poll_oneoff(fd_read)` readiness for
    stream sockets that can synchronously pull data from a
    `WASIPreview1SocketReceiveDataProvider`.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart`,
    `test/wasi_test.dart`, `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "poll_oneoff pulls host-backed stream provider readiness"`
    failed before the fix because a provider-backed stream with no
    `readReadyBytes` hint produced zero poll events even though `sock_recv`
    could synchronously pull bytes.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "poll_oneoff pulls host-backed stream provider readiness"`;
    `dart test -p chrome test/wasi_test.dart --name "poll_oneoff pulls host-backed stream provider readiness"`;
    `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`;
    `socket_poll_readiness` now drains one provider-backed stream byte per
    iteration and reported `per_operation_us=0.075890625` for the socket-heavy
    distribution in the recorded run.
  - Done when: a provider-backed stream with no buffered data and no
    `readReadyBytes` hint reports one readable poll event, preserves the pulled
    byte for the next `sock_recv`, does not call the provider without `FD_READ`,
    and the benchmark covers the provider-poll path.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete Preview1 full
    socket conformance or any P2/P3 support gate.
- [x] `P1-SOCKET-DATAGRAM-PARTIAL-SEND-INVALID` - Host-backed datagram sends
  reject partial message acceptance.
  - Scope: shared Preview1 `WASIPreview1Socket.datagram` send handler results
    through both direct VFS calls and native/browser `sock_send`.
  - Edit targets: `lib/src/wasi/preview1/socket.dart`, `test/wasi_test.dart`,
    and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_send rejects partial host-backed datagram writes"`
    failed before the fix because a host datagram send handler returning
    `message.length - 1` produced `SUCCESS` and wrote a short `nwritten` value.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "virtual socket host send handlers reject invalid write counts"`;
    `dart test test/wasi_test.dart --name "sock_send rejects partial host-backed datagram writes"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_send rejects partial host-backed datagram writes"`;
    `dart test test/wasi_test.dart`; `dart analyze`.
  - Performance gate: N/A; this adds one constant-time equality check to an
    invalid host callback branch and does not allocate or copy on successful
    datagram sends.
  - Done when: datagram send handlers returning less or more than the message
    length are rejected with `EINVAL`, `nwritten` remains unchanged, default
    datagram sends still record the full message, and stream host handlers keep
    their existing partial-write behavior.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
- [x] `P1-SOCKET-FDFLAGS-SUPPORTED` - Socket descriptors reject file-only
  descriptor flags.
  - Scope: native/browser Preview1 socket fdflag validation for `sock_accept`
    and `fd_fdstat_set_flags`.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`
    failed before the fix because a stream listener accepted `APPEND`, consumed
    its queued accepted socket, and exposed a file-only flag on the accepted
    socket descriptor.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`;
    `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags"`;
    `dart test test/wasi_test.dart`; `dart analyze`.
  - Performance gate: N/A; this only adds constant-time descriptor flag
    validation before existing socket accept/fdstat mutation paths.
  - Done when: unknown fdflag bits still return `EINVAL`, known file-only
    fdflags keep `NOTSOCK`/`BADF` descriptor errors for non-socket descriptors,
    return `NOTSUP` for socket descriptors, `NONBLOCK` remains accepted, failed
    `sock_accept` leaves the accepted-fd output pointer unchanged, and the
    pending accepted socket is still available afterward.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
- [x] `P1-SOCKET-FDFLAGS-RIGHTS-PREFLIGHT` - Socket descriptor flag validation
  classifies socket-unsupported flags before checking descriptor mutation
  rights.
  - Scope: native/browser shared Preview1 `fd_fdstat_set_flags` errno ordering
    for socket descriptors.
  - Edit targets: `lib/src/wasi/preview1/common/fd_syscalls.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`,
    `tool/wasi_vfs_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags" --reporter=compact`
    failed before the fix because a socket descriptor with no rights returned
    `ENOTCAPABLE` for `APPEND`; the expected Preview1 socket classification is
    `NOTSUP` for the known but file-only fdflag.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags" --reporter=compact`;
    `dart test test/wasi_test.dart --name "socket descriptor flags reject file-only flags|sock_accept|datagram sockets do not expose accept rights|default socket rights expose socket-specific operations only" --reporter=compact`;
    `dart test -p chrome test/wasi_test.dart --name "socket descriptor flags reject file-only flags|sock_accept|datagram sockets do not expose accept rights|default socket rights expose socket-specific operations only" --reporter=compact`;
    `dart test test/wasi_test.dart --reporter=compact`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=socket-heavy --iterations=1000`
    reported `socket fdflag preflight.operations=4000` and
    `socket fdflag preflight.per_operation_us=0.11875`;
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`
    reported `socket_fdflag_preflight.operations=8000` and
    `socket_fdflag_preflight.per_operation_us=0.21875` for the baseline
    distribution, plus `socket_fdflag_preflight.operations=32000` and
    `socket_fdflag_preflight.per_operation_us=0.05709375` for the socket-heavy
    distribution.
  - Done when: unknown fdflag bits return `EINVAL`, known socket-unsupported
    fdflags return `NOTSUP` before `FD_FDSTAT_SET_FLAGS` rights checks, known
    socket-supported flags still require rights, successful socket `NONBLOCK`
    mutation is preserved, and native/browser imports route through the same
    helper.
  - Evidence update: this checked row, the `Current Execution Board`
    `Recently Checked` entry, the verification matrix, and the benchmark
    payload.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row or any P2/P3 support gate.
- [x] `P1-SOCKET-DATAGRAM-ACCEPT-NOTSUP` - `sock_accept` reports `NOTSUP` for
  datagram sockets.
  - Scope: native/browser Preview1 `sock_accept` errno classification for a
    valid socket descriptor whose type cannot support accept.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_accept rejects datagram sockets"`
    failed before the fix because the datagram socket path returned `EINVAL`
    instead of `NOTSUP`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "sock_accept rejects datagram sockets"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_accept rejects datagram sockets"`;
    `dart analyze`.
  - Performance gate: N/A; this only changes the existing rejected datagram
    socket branch and does not alter successful socket hot paths.
  - Done when: datagram sockets with explicit `sock_accept` rights return
    `NOTSUP`, preserve the accepted-fd output pointer, and native/browser
    behavior agrees. Default datagram descriptors are narrowed further by
    `P1-SOCKET-DATAGRAM-RIGHTS-NARROW`, so ordinary injected datagrams now fail
    `sock_accept` with `ENOTCAPABLE` before this unsupported-operation branch.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
- [x] `P1-SOCKET-NONSOCKET-ERRNO` - Socket syscalls report `NOTSOCK` for
  non-socket descriptors.
  - Scope: native/browser Preview1 `sock_accept`, `sock_recv`, `sock_send`, and
    `sock_shutdown` errno classification before memory or socket state mutation.
  - Edit targets: `lib/src/wasi/preview1/common/constants.dart`,
    `lib/src/wasi/preview1/native/wasi.dart`,
    `lib/src/wasi/preview1/js/web/wasi.dart`, `test/wasi_test.dart`, and this
    roadmap.
  - Red test:
    `dart test test/wasi_test.dart --name "socket syscalls return notsock for non-socket descriptors"`
    failed before the fix because a valid preopen fd returned `BADF` instead of
    `NOTSOCK`.
  - Implementation gate:
    `dart test test/wasi_test.dart --name "socket syscalls return notsock for non-socket descriptors"`;
    `dart test -p chrome test/wasi_test.dart --name "socket syscalls return notsock for non-socket descriptors"`;
    `dart analyze`.
  - Performance gate: N/A; this only changes the existing error branch after a
    failed socket descriptor lookup and does not alter successful socket hot
    paths.
  - Done when: known non-socket descriptors return `NOTSOCK`, unknown
    descriptors still return `BADF`, output pointers remain unchanged on the
    error path, and native/browser behavior agrees.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
- [x] `P1-SOCKET-HOST-STREAM-WAITALL-CHUNKS` - Host-backed stream
  `RECV_WAITALL` drains chunked providers.
  - Scope: native/browser shared Preview1 stream sockets backed by
    `WASIPreview1SocketReceiveDataProvider`.
  - Edit targets: `lib/src/wasi/preview1/socket.dart`,
    `test/wasi_test.dart`, and `tool/wasi_vfs_benchmark.dart`.
  - Red test:
    `dart test test/wasi_test.dart --name "sock_recv waitall drains chunked host stream providers"`
    failed before the fix because `ensureReceiveData` pulled the provider only
    once and returned `_errnoAgain` even though later provider calls could
    satisfy the full `RECV_WAITALL` request.
  - Implementation gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv waitall drains chunked host stream providers"`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: `RECV_WAITALL` explicitly asks `ensureReceiveData` to keep
    pulling non-empty provider chunks until the requested unread byte count is
    available or the provider returns empty, ordinary receive keeps the one-pull
    default, shutdown mutation cannot cause an unbounded loop, and
    `socket_recv_waitall` benchmark output includes the host chunked path.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
- [x] `P1-SOCKET-HOST-RECV-PROVIDER-CAP` - Host-backed stream receive providers
  are capped to the requested byte count.
  - Scope: native/browser shared Preview1 stream sockets backed by
    `WASIPreview1SocketReceiveDataProvider`.
  - Edit targets: `lib/src/wasi/preview1/socket.dart` and
    `test/wasi_test.dart`.
  - Red test:
    `dart test test/wasi_test.dart --name "virtual socket receive providers are capped to requested bytes"`
    failed before the fix because a provider returning more than `maxBytes`
    left the extra bytes buffered and made a later read succeed unexpectedly.
  - Implementation gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket receive providers are capped to requested bytes"`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
    This keeps the normal host receive and `RECV_WAITALL` paths covered; the cap
    branch is a defensive contract path for invalid host callbacks.
  - Done when: provider returns larger than `maxBytes` are clipped before
    buffering, ordinary and waitall host receive semantics still pass, output
    pointers remain unchanged on the follow-up `EAGAIN`, and benchmark output
    still covers host receive paths.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
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
- [x] `P1-SOCKET-RECEIVE-SHUTDOWN-DROPS-BUFFERS` - Receive-side shutdown drops
  unread receive buffers.
  - Scope: native/browser shared Preview1 socket memory and host-injection
    behavior for stream and datagram receive buffers after
    `sock_shutdown(..., RD)`.
  - Edit targets: `lib/src/wasi/preview1/socket.dart` and `test/wasi_test.dart`.
  - Red test:
    `dart test test/wasi_test.dart --name "virtual socket receive shutdown remains terminal"`
    failed before the fix because unread receive bytes/messages remained buffered
    after receive-side shutdown.
  - Implementation gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket receive shutdown remains terminal"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_shutdown and descriptor rights are enforced for preview1 sockets"`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: receive-side shutdown clears unread stream bytes, clears queued
    datagrams, clears read-readiness hints, and later `addReceiveData` calls do
    not allocate or queue unreachable receive data.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: contributes to `SUPPORT-P1`; does not complete the parent
    socket conformance row.
- [x] `P1-SOCKET-DESCRIPTOR-NAMESPACE` - Initial descriptors reject fd namespace
  collisions and invalid virtual allocator starts.
  - Scope: native/browser shared Preview1 VFS construction for configured stdio,
    preopen, injected socket descriptor numbers, and the first virtual
    descriptor allocation number.
  - Edit targets: `lib/src/wasi/preview1/common/vfs.dart` and
    `test/wasi_test.dart`.
  - Red test:
    `dart test test/wasi_test.dart --name "virtual socket descriptors reject initial fd collisions"`
    failed across the namespace fixes while a negative `firstVirtualFd`,
    negative socket fds, stdio/socket collisions, preopen/socket collisions,
    stdio/preopen collisions, and duplicate stdio fds were silently accepted.
  - Implementation gate: `dart test test/wasi_test.dart`;
    `dart test -p chrome test/wasi_test.dart --name "virtual socket descriptors reject initial fd collisions"`;
    `dart test -p chrome test/wasi_test.dart --name "sock_recv and sock_send use configured preview1 stream sockets"`;
    `dart test -p chrome test/wasi_test.dart --name "fd_prestat_get and fd_prestat_dir_name expose configured preopen"`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`.
  - Done when: the first virtual fd allocation number is nonnegative, initial
    stdio fds are nonnegative and unique, preopen fds cannot share fd numbers
    with stdio descriptors, socket fds are nonnegative, sockets cannot share fd
    numbers with stdio/preopen descriptors, and normal high-numbered socket
    injection plus preopen discovery still work.
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
- [x] `CM-TASK-RETURN-BORROW-VALIDATION` - Reject borrowed canonical
  `task.return` results before Preview3 task host binding.
  - Scope: local component validation for canonical definitions, using the same
    borrow traversal applied to function result types.
  - Evidence: `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`.
  - Red test:
    `dart test test/component_test.dart --name "reports task.return result types containing borrow" --reporter=compact`
    initially failed because the validator accepted a `task.return` result type
    resolving to `borrow<resource>`.
  - Gate:
    - `dart test test/component_test.dart --name "reports task.return result types containing borrow|reports missing canonical option requirements|reports invalid canonical result value type indexes" --reporter=compact`
    - `dart run tool/component_benchmark.dart --json`
  - Done when: invalid borrowed task-return result shapes fail validation with a
    `task.return result type` diagnostic and no host execution path observes the
    invalid result.
  - Claim impact: closes one deterministic component validation gap; broader
    borrow, stream, future, nested-shape, generated-world, and conformance-suite
    work remains.
- [x] `CM-RESOURCE-REPRESENTATION-VALIDATION` - Enforce `i32` component
  resource representations and reject other core value type encodings.
  - Scope: component-model resource type validation before P2/P3 resource host
    binding and canonical resource operations.
  - Edit targets: `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart --name "reports invalid component resource type indexes"`
    first failed because a resource type with representation byte `0x00`
    validated with no diagnostic; this correction then failed because
    single-byte `externref` validated cleanly and a validly encoded `(ref eq)`
    representation threw `FormatException: Unsupported Wasm component optional
    index tag: 0x6d` before validation could report the unsupported
    representation.
  - Implementation gate:
    `dart test test/component_test.dart --name "reports invalid component resource type indexes"`;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart analyze`;
    `dart test`.
  - Performance gate: N/A; this is a constant-time validation check over a
    decoded resource type and does not touch adapter execution, async copy, or
    resource-table hot paths.
  - Done when: `i32` resource representations validate; non-`i32`
    representations such as `externref`, `(ref eq)`, and malformed `0x00`
    encodings produce structured validation diagnostics before resource host
    binding; and typed-reference representation payload bytes are consumed by
    the decoder instead of being misread as destructor/callback option tags.
  - Evidence update: this checked row plus the `Current Execution Board`
    checked-child list and `Recently Checked` entry.
  - Claim impact: reduces P2/P3 resource validation risk; no direct support
    gate.
- [x] `CM-CANONICAL-COPY-OPTION-PLACEMENT` - Reject non-copy options on
  stream/future canonical copy definitions.
  - Scope: component-model canonical validation for decoded `stream.read`,
    `stream.write`, `future.read`, and `future.write` definitions before async
    host binding.
  - Edit targets: `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart --name "reports invalid canonical option placements"`
    failed before the fix because `canon stream.read` with an `async` option
    validated without a diagnostic rejecting that option placement.
  - Implementation gate:
    `dart test test/component_test.dart --name "reports invalid canonical option placements"`;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`.
  - Performance gate: N/A; this reuses the existing validation-time option scan
    and adds no runtime host or canonical copy hot path.
  - Done when: decoded stream/future copy definitions accept only string
    encoding, memory, and realloc options, and invalid options fail with a
    structured validation diagnostic before async host state can be bound.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: reduces P2/P3 component validation risk; no direct support
    gate.
- [x] `CM-VALUE-DEFINITION-TYPE-VALIDATION` - Validate value definition type
  indexes in definition order.
  - Scope: component-model value section decoding and validation before value
    index entries become visible to exports, equality imports, or instantiation
    arguments.
  - Edit targets: `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart --name "reports invalid component value definition type indexes"`
    failed before the fix because a value definition using a function type index
    threw a decode-time `FormatException`, and an out-of-range value definition
    type index could not be reported as a structured validation error.
  - Implementation gate:
    `dart test test/component_test.dart --name "reports invalid component value definition type indexes"`;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`; `dart analyze`;
    `dart test`.
  - Performance gate: N/A; this is validation-only, the recursive invalid-type
    guard only runs after a value-definition decode error, and no runtime host
    path is touched.
  - Done when: wrong-sort and out-of-range value definition type indexes produce
    `value[i].type` validation diagnostics before value entries can be consumed
    or host binding can observe them, while malformed payloads for valid types
    still remain decode errors.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: reduces P2/P3 component validation risk; no direct support
    gate.
- [x] `CM-INLINE-INSTANCE-DUPLICATE-EXPORTS` - Reject duplicate component and
  core inline instance export names.
  - Scope: component-model validation for `WasmComponentInstance.inlineExports`
    and `WasmComponentCoreInstance.inlineExports`.
  - Edit targets:
    `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart -n "validates component instantiation indexes and value arguments|validates core instance indexes in definition order"`
    failed before the fix because duplicate component/core inline export names
    validated cleanly.
  - Implementation gate:
    `dart test test/component_test.dart -n "validates component instantiation indexes and value arguments|validates core instance indexes in definition order"`;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`; `dart analyze`.
  - Performance gate: N/A; this adds validation-time linear name scans and no
    runtime host path.
  - Done when: duplicate inline export names in both component and core
    instances are rejected before alias resolution, adapter binding, or host
    state can observe the ambiguous shape.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: reduces P2/P3 component validation ambiguity; no direct
    support gate.
- [x] `CM-INSTANTIATION-DUPLICATE-ARGS` - Reject duplicate component and core
  instantiation argument names.
  - Scope: component-model validation for `WasmComponentInstance` and
    `WasmComponentCoreInstance` named instantiation arguments.
  - Edit targets:
    `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments"`
    failed before the fix because duplicate component instantiation argument
    names validated cleanly;
    `dart test test/component_test.dart --name "validates core instance indexes in definition order"`
    failed before the fix because duplicate core instantiation argument names
    validated cleanly.
  - Implementation gate:
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments"`;
    `dart test test/component_test.dart --name "validates core instance indexes in definition order"`;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`; `dart analyze`.
  - Performance gate: N/A; this adds a single validation-time linear scan of
    instantiation argument names and no runtime host path.
  - Done when: duplicate argument names in both component and core
    instantiation definitions are rejected before adapter binding or host state
    can observe the ambiguous shape.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: reduces P2/P3 component validation ambiguity; no direct
    support gate.
- [x] `CM-INSTANCE-CORE-SORT-VALIDATION` - Component instance arguments reject
  missing core sort indexes.
  - Scope: component-model validation for `WasmComponentInstance` argument and
    inline-export sort indexes that refer to the core index spaces.
  - Edit targets:
    `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments"`
    failed before the fix because an instance argument with sort
    `core memory 0` validated even though no core memory had been defined.
  - Implementation gate:
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments"`;
    `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`; `dart analyze`.
  - Performance gate: N/A; this reuses the existing component validation core
    index counter and adds no runtime host work.
  - Done when: component instance arguments and inline exports that use core
    sorts are checked against the visible core index spaces before host state or
    component instantiation planning can observe the invalid shape.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: reduces P2/P3 component validation risk; no direct support
    gate.
- [x] `CM-INSTANTIATION-IMPORT-MATCHING` - Component instance arguments match
  known local child component imports.
  - Scope: component-model validation for `WasmComponentInstance.instantiate`
    when the target component index resolves to a locally decoded child
    component.
  - Edit targets:
    `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, and this roadmap.
  - Red test:
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments" --reporter=compact`
    failed before the fix because a child component importing `"need"`
    validated successfully when instantiated with only `"other"`, so the
    validator reported neither unknown arguments nor missing imports.
  - Implementation gate:
    `dart test test/component_test.dart --name "validates component instantiation indexes and value arguments" --reporter=compact`;
    `dart test test/component_test.dart --reporter=compact`;
    `dart test test/wasi_component_host_test.dart test/wasi_component_versioned_host_test.dart --reporter=compact`;
    `dart test --reporter=compact --concurrency=1`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/component_benchmark.dart --json` reported
    `decode.per_iteration_us=59.835` and `validate.per_iteration_us=122.87`.
  - Done when: instantiating a known local child component rejects argument
    names that are not imports, rejects omitted required imports, rejects
    argument sort mismatches, and preserves component index-space alignment for
    imported or otherwise unknown component entries without pretending to
    validate their import sets.
  - Evidence update: this checked row plus the `Current Execution Board`
    checked-child list, `Recently Checked`, the verification matrix, and the
    current baseline.
  - Claim impact: reduces P2/P3 component validation ambiguity before adapter
    binding; imported-component type equivalence and generated-world validation
    remain open, so no support gate changes directly.
- [x] `CM-NESTED-ASYNC-VALUE-VALIDATION` - Reject nested stream/future value
  payloads during component validation.
  - Scope: component value type validation for global and scoped type
    definitions used by future Preview2/Preview3 async hosts.
  - Edit targets: `lib/src/wasm/backend/native/interpreter/component.dart`,
    `test/component_test.dart`, `test/wasi_component_async_host_test.dart`, and
    `test/wasi_component_host_test.dart`.
  - Red test:
    `dart test test/component_test.dart --name "reports nested stream and future element types"`
    failed before the fix because nested async value types validated cleanly and
    were rejected only later by async host binding; the host-focused
    `dart test test/wasi_component_host_test.dart --name "validates nested async stream bindings before binding"`
    gate now proves component-host planning reports validation errors before
    async value bindings or host binding errors are produced.
  - Implementation gate: `dart test test/component_test.dart`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart test test/wasi_component_host_test.dart`.
  - Performance gate: N/A for this validation-only shape guard; it reuses
    memoized type-shape traversal and does not add runtime host work.
  - Done when: `stream<stream<T>>`, `future<stream<T>>`, and scoped indexed
    nested async payloads fail validation with a diagnostic naming nested async
    element types before host state can be mutated, and component-host planning
    preserves that validation failure without creating async host bindings.
  - Evidence update: this checked row plus the `Current Execution Board`
    `Recently Checked` entry.
  - Claim impact: reduces P3 async validation risk; no direct support gate.
- [x] `P3-ASYNC-ERROR-CONTEXT-COPY` - Canonical memory copy for
  `stream<error-context>` and `future<error-context>`.
  - Scope: internal Preview3 async host value-copy behavior over real
    error-context resource handles.
  - Edit targets: `lib/src/wasi/component/async_host.dart`,
    `test/wasi_component_async_host_test.dart`, and
    `tool/wasi_component_async_benchmark.dart`.
  - Red test:
    `dart test test/wasi_component_async_host_test.dart --name "copies error-context"`
    failed before the fix because the async value validator rejected
    error-context stream/future payloads before canonical memory copy could run.
  - Implementation gate:
    `dart test test/wasi_component_async_host_test.dart --name "copies error-context"`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart test test/wasi_component_value_memory_test.dart`;
    `dart test test/wasi_component_host_test.dart`.
  - Performance gate:
    `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`
    reported dedicated `stream_error_context_memory_copy` and
    `future_error_context_memory_copy` metrics;
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported the existing error-context adapter and resource-table metrics.
  - Done when: error-context stream/future element types validate, copy through
    guest memory as 32-bit handles, keep ownership with the error-context host,
    drop async endpoints cleanly, and have dedicated benchmark output.
  - Evidence update: the `Current Execution Board` `Recently Checked` entry.
  - Claim impact: contributes to Preview3 async value execution coverage; does
    not complete `P3-ASYNC-COPY-GAPS`, `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
- [x] `P3-ASYNC-CHAR-SCALAR` - Reject non-scalar `future<char>` values before
  canonical memory copies.
  - Scope: internal Preview3 async future value validation plus shared
    Canonical ABI char scalar handling in value-memory and adapter direct paths.
  - Edit targets: `lib/src/wasi/component/unicode_scalar.dart`,
    `lib/src/wasi/component/async_host.dart`,
    `lib/src/wasi/component/value_memory.dart`,
    `lib/src/wasi/component/adapter_host.dart`,
    `test/wasi_component_async_host_test.dart`,
    `test/wasi_component_value_memory_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_async_host_test.dart --name "rejects non-scalar char future values before memory copies"`
    failed before the fix because `String.fromCharCode(0xd800)` was accepted as
    a `future<char>` value and `future.write` returned `null`.
  - Implementation gate:
    `dart test test/wasi_component_async_host_test.dart --name "rejects non-scalar char future values before memory copies"`;
    `dart test test/wasi_component_value_memory_test.dart --name "rejects non-scalar char stores"`;
    `dart test test/wasi_component_async_host_test.dart`;
    `dart test test/wasi_component_value_memory_test.dart`;
    `dart test test/wasi_component_adapter_plan_test.dart`;
    `dart test test/wasi_component_host_test.dart`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`
    reported `future_memory_copy.operations=8000` and
    `future_memory_copy.per_operation_us=0.165125`. The implementation is a
    constant-time scalar predicate shared by existing validation paths and adds
    no loop, allocation, or table mutation to copy hot paths.
  - Done when: non-scalar Dart strings fail before being written into a
    `future<char>` endpoint, legal scalar values still copy to canonical memory,
    value-memory store rejects non-scalar char without changing guest memory,
    and adapter direct char conversion uses the same scalar predicate.
  - Evidence update: this detailed child row plus the `Current Execution Board`
    checked-child list, `Recently Checked`, and the verification matrix.
  - Claim impact: contributes to Preview3 async Canonical ABI boundary
    correctness; does not complete `P3-ASYNC-COPY-GAPS`, `CM-VALUE-VALIDATION`,
    `SUPPORT-P2`, or `SUPPORT-P3`.
- [x] `P3-FLAGS-STREAM-COPY-VALIDATION` - Copy decoded `stream<flags>` values
  through canonical memory and reject duplicate host-side flag labels.
  - Scope: shared Canonical ABI value-memory flags layout plus Preview3 async
    stream write/read memory-copy operations.
  - Evidence: `lib/src/wasi/component/value_memory.dart`,
    `test/wasi_component_value_memory_test.dart`,
    `test/wasi_component_async_host_test.dart`,
    `tool/wasi_component_async_benchmark.dart`.
  - Red test:
    `dart test test/wasi_component_value_memory_test.dart test/wasi_component_async_host_test.dart --name "rejects duplicate flag labels before writing memory|copies decoded flags stream values through canonical memory" --reporter=compact`
    failed because duplicate labels were accepted by value-memory store and by
    async stream host writes.
  - Gate:
    - `dart test test/wasi_component_value_memory_test.dart --reporter=compact`
    - `dart test test/wasi_component_async_host_test.dart --reporter=compact`
    - `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`
  - Done when: a decoded `stream<flags {a,b,c}>` round-trips through canonical
    memory, duplicate labels fail before guest-memory writes or async endpoint
    enqueue, and the async benchmark reports `stream_flags_memory_copy`.
  - Claim impact: closes one composite Preview3 async value-memory path and one
    host-side value validation gap; broader stream/future shapes, generated
    worlds, waitable coverage for this shape, and public P3 support remain
    incomplete.
- [x] `P3-OPTION-STREAM-SELECTOR-VALIDATION` - Reject conflicting
  variant/option/result selectors before canonical memory writes or async
  stream enqueues.
  - Scope: shared Canonical ABI selector resolution for variants, options, and
    results, plus Preview3 decoded `stream<option<u32>>` memory-copy execution.
  - Edit targets: `lib/src/wasi/component/value_memory.dart`,
    `test/wasi_component_value_memory_test.dart`,
    `test/wasi_component_async_host_test.dart`,
    `tool/wasi_component_async_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_value_memory_test.dart test/wasi_component_async_host_test.dart --name "rejects conflicting variant case selectors before writing memory|rejects conflicting option stream value selectors" --reporter=compact`
    failed before the fix because a value with mismatched variant `index` and
    `label` stored successfully, and a stream option value with mismatched
    `index` and `isSome` was accepted into the endpoint.
  - Implementation gate:
    `dart test test/wasi_component_value_memory_test.dart test/wasi_component_async_host_test.dart --name "rejects conflicting variant case selectors before writing memory|rejects conflicting option stream value selectors" --reporter=compact`;
    `dart test test/wasi_component_value_memory_test.dart --reporter=compact`;
    `dart test test/wasi_component_async_host_test.dart --reporter=compact`;
    `dart test test/wasi_component_host_test.dart --reporter=compact`;
    `dart test test/wasi_component_versioned_host_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_component_async_benchmark.dart --iterations=2000 --batch-size=16 --json`
    reported `stream_option_memory_copy.operations=64000` and
    `stream_option_memory_copy.per_operation_us=0.128375`.
  - Done when: selector fields that describe the same variant/option/result
    case must agree before memory or endpoint mutation, legal
    `stream<option<u32>>` values still copy through canonical memory, endpoint
    drops leave no table leaks, and the async benchmark measures the option
    stream copy path.
  - Evidence update: this detailed child row plus the `Current Execution Board`
    checked-child list, `Recently Checked`, the verification matrix, and the
    benchmark payload.
  - Claim impact: contributes to `P3-ASYNC-COPY-GAPS`,
    `CM-VALUE-VALIDATION`, `SUPPORT-P2`, and `SUPPORT-P3`; it does not complete
    `P3-ASYNC-COPY-GAPS`, `CM-VALUE-VALIDATION`, `SUPPORT-P1`, `SUPPORT-P2`, or
    `SUPPORT-P3`.
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
- [x] `CM-VARIANT-PAYLOAD-STORE-VALIDATION` - Canonical variant store rejects
  invalid payload shape before memory writes.
  - Scope: Canonical ABI value-memory store behavior for variant, option, and
    result-style payload cases used by Preview2/Preview3 adapters.
  - Edit targets: `lib/src/wasi/component/value_memory.dart`,
    `test/wasi_component_value_memory_test.dart`,
    `tool/wasi_resource_table_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_value_memory_test.dart --name "rejects invalid variant payloads before writing memory" --reporter=compact`
    failed before the fix because a payloadless variant case with an associated
    payload returned successfully, and invalid payload paths could mutate the
    discriminant byte before reporting the bad value.
  - Implementation gate:
    `dart test test/wasi_component_value_memory_test.dart --name "rejects invalid variant payloads before writing memory" --reporter=compact`;
    `dart test test/wasi_component_value_memory_test.dart --reporter=compact`;
    `dart test test/wasi_component_async_host_test.dart --reporter=compact`;
    `dart test test/wasi_component_host_test.dart --reporter=compact`;
    `dart analyze`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `canonical_variant_store.operations=4000` and
    `canonical_variant_store.per_operation_us=0.26275`.
  - Done when: payloadless cases reject associated values before writing memory,
    payload cases reject missing or invalid payloads before writing the
    discriminant, valid variant payload stores still succeed, and the component
    host/value-memory suites keep passing.
  - Evidence update: this checked row, the `Current Execution Board`
    `CM-VALUE-VALIDATION` checked-child list, the verification matrix, and the
    resource benchmark payload.
  - Claim impact: reduces P2/P3 Canonical ABI value validation risk; does not
    complete `CM-VALUE-VALIDATION`, `SUPPORT-P2`, or `SUPPORT-P3`.
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
  - Evidence: `WIT-WORLD-VERSION-PROFILE-INGESTION` now parses annotated
    Preview3 WIT interface functions and world includes, then routes local and
    qualified world targets through the fixed Preview2/Preview3 versioned
    hosts. `WIT-WORLD-PRIMITIVE-ADAPTER-BINDING` now expands local synchronous
    primitive WIT import/export functions into executable Preview2/Preview3
    adapter callbacks with primitive value validation.
    `WIT-WORLD-COMPOSITE-ADAPTER-BINDING` now binds synchronous `option<T>` and
    `result<T, E>` value trees over primitive payloads through the same adapter
    path. `WIT-WORLD-LIST-TUPLE-ADAPTER-BINDING` now binds synchronous
    `list<T>` and `tuple<T...>` value trees over primitive payloads through the
    same adapter path. `WIT-WORLD-RECORD-ADAPTER-BINDING` now parses local WIT
    `record` declarations and binds same-interface named records through the
    same Preview2/Preview3 adapter path.
  - Gate: current WIT ingestion tests plus future generated-WIT fixture and
    component-host binding tests.
  - Done when: imported/generated worlds bind through Preview2/Preview3
    adapters and failures name the interface/world boundary.

- [x] `WIT-WORLD-RECORD-ADAPTER-BINDING` - Local named WIT record values bind
  to executable Preview2/Preview3 adapters.
  - Scope: internal WIT adapter binding for local import interface functions
    with synchronous signatures that reference records declared in the same
    interface.
  - Edit targets: `lib/src/wasi/component/wit_document.dart`,
    `lib/src/wasi/component/wit_adapter.dart`,
    `test/wasi_component_wit_test.dart`,
    `test/wasi_component_versioned_host_test.dart`,
    `tool/wasi_resource_table_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_wit_test.dart --name "local record" --reporter=expanded`
    failed before the fix because local record declarations were not captured;
    `dart test test/wasi_component_versioned_host_test.dart --name "named WIT record" --reporter=expanded`
    failed before the fix because named record WIT adapter types were rejected
    before binding.
  - Implementation gate:
    `dart test test/wasi_component_wit_test.dart --name "local record" --reporter=expanded`;
    `dart test test/wasi_component_versioned_host_test.dart --name "named WIT record" --reporter=expanded`;
    `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_wit_record_adapter_program_invoke.operations=2000`
    and `component_wit_record_adapter_program_invoke.per_operation_us=0.6135`.
  - Done when: local WIT record declarations are parsed, same-interface record
    names resolve recursively through supported field types, valid record
    arguments/results execute in Preview2 and Preview3 adapter programs, and
    bad record arity or field payload kinds fail before returning to the
    caller.
  - Claim impact: advances `WIT-INGESTION`; does not complete generated
    multi-package world binding, cross-interface named type resolution,
    variant/resource WIT adapter execution, async WIT adapter execution,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.

- [x] `WIT-WORLD-LIST-TUPLE-ADAPTER-BINDING` - Local list/tuple WIT world values
  bind to executable Preview2/Preview3 adapters.
  - Scope: internal WIT adapter binding for local import interface functions
    with synchronous `list<T>` and `tuple<T...>` signatures over supported
    primitive payloads.
  - Edit targets: `lib/src/wasi/component/wit_adapter.dart`,
    `test/wasi_component_versioned_host_test.dart`,
    `tool/wasi_resource_table_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_versioned_host_test.dart --name "list and tuple WIT values" --reporter=expanded`
    failed before the fix because list and tuple WIT adapter types were
    rejected before binding.
  - Implementation gate:
    `dart test test/wasi_component_versioned_host_test.dart --name "list and tuple WIT values" --reporter=expanded`;
    `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_wit_list_tuple_adapter_program_invoke.operations=2000`
    and `component_wit_list_tuple_adapter_program_invoke.per_operation_us=1.585`.
  - Done when: local WIT adapter bindings accept valid nested list/tuple values,
    reject tuple arity mismatches before callback execution, reject nested
    primitive payloads whose `WasmComponentValueData.kind` does not match the
    WIT payload type, and validate callback results before returning them to
    callers.
  - Claim impact: advances `WIT-INGESTION`; does not complete generated
    multi-package world binding, cross-interface record resolution,
    variant/resource WIT adapter execution, async WIT adapter execution,
    `SUPPORT-P1`, `SUPPORT-P2`, or `SUPPORT-P3`.

- [x] `WIT-WORLD-COMPOSITE-ADAPTER-BINDING` - Local composite WIT world values
  bind to executable Preview2/Preview3 adapters.
  - Scope: internal WIT adapter binding for local import interface functions
    with synchronous `option<T>` and `result<T, E>` signatures over supported
    primitive payloads.
  - Edit targets: `lib/src/wasi/component/wit_adapter.dart`,
    `test/wasi_component_versioned_host_test.dart`,
    `tool/wasi_resource_table_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_versioned_host_test.dart --name "composite WIT values" --reporter=expanded`
    failed before the fix because composite WIT adapter types were rejected
    before binding.
  - Implementation gate:
    `dart test test/wasi_component_versioned_host_test.dart --name "composite WIT values" --reporter=expanded`;
    `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_wit_composite_adapter_program_invoke.operations=4000`
    and `component_wit_composite_adapter_program_invoke.per_operation_us=0.712`.
  - Done when: local WIT adapter bindings accept valid `option<T>` some/none
    cases and `result<T, E>` ok/error cases, reject conflicting selector
    fields, reject nested primitive payloads whose `WasmComponentValueData.kind`
    does not match the WIT payload type, and call host callbacks only after
    those checks pass.
  - Claim impact: advances `WIT-INGESTION`; does not complete generated
    multi-package world binding, async WIT adapter execution, `SUPPORT-P1`,
    `SUPPORT-P2`, or `SUPPORT-P3`.

- [x] `WIT-WORLD-PRIMITIVE-ADAPTER-BINDING` - Local primitive WIT world
  functions bind to executable Preview2/Preview3 adapters.
  - Scope: internal WIT adapter binding for local import/export interface
    functions with synchronous primitive WIT signatures.
  - Edit targets: `lib/src/wasi/component/versioned_host.dart`,
    `lib/src/wasi/component/wit_adapter.dart`,
    `test/wasi_component_versioned_host_test.dart`,
    `tool/wasi_resource_table_benchmark.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_versioned_host_test.dart --name "WIT world adapters" --reporter=expanded`
    failed before the fix because the versioned WIT world plan could ingest but
    not expand or bind executable adapter callbacks.
  - Implementation gate:
    `dart test test/wasi_component_versioned_host_test.dart --name "WIT world adapters" --reporter=expanded`;
    `dart test test/wasi_component_versioned_host_test.dart test/wasi_component_wit_test.dart --reporter=compact`.
  - Performance gate:
    `dart run tool/wasi_resource_table_benchmark.dart --iterations=2000 --resources=256 --json`
    reported `component_wit_adapter_program_invoke.operations=4000` and
    `component_wit_adapter_program_invoke.per_operation_us=0.22325`.
  - Done when: the selected WIT world expands local functions once, exposes
    direction-aware qualified names, binds Preview2/Preview3 import/export
    callbacks, validates primitive arguments/results at invocation, rejects
    invalid `u32` inputs before callback execution, and keeps P3 async WIT
    worlds out of the synchronous adapter binding path.
  - Claim impact: advances `WIT-INGESTION`; does not complete generated
    multi-package world binding, async WIT adapter execution, `SUPPORT-P2`, or
    `SUPPORT-P3`.

- [x] `WIT-WORLD-VERSION-PROFILE-INGESTION` - Parsed WIT worlds enter the
  Preview2/Preview3 version-profile preflight.
  - Scope: internal WIT ingestion only; no generated adapter emission and no
    public Preview2/Preview3 support claim.
  - Edit targets: `lib/src/wasi/component/wit_document.dart`,
    `lib/src/wasi/component/versioned_host.dart`,
    `lib/src/wasi/preview2/component_host.dart`,
    `lib/src/wasi/preview3/component_host.dart`,
    `test/wasi_component_wit_test.dart`,
    `test/wasi_component_versioned_host_test.dart`, and this roadmap.
  - Red test:
    `dart test test/wasi_component_wit_test.dart test/wasi_component_versioned_host_test.dart --name "parses annotated|ingest WIT worlds" --reporter=expanded`
    failed before the fix because functions/includes were not modeled and
    fixed P2/P3 wrappers had no WIT world preflight method.
  - Implementation gate:
    `dart test test/wasi_component_wit_test.dart test/wasi_component_versioned_host_test.dart --name "parses annotated|ingest WIT worlds" --reporter=expanded`;
    `dart test test/wasi_component_wit_test.dart test/wasi_component_versioned_host_test.dart test/wasi_component_host_test.dart --reporter=compact`.
  - Performance gate: N/A for this declaration-boundary increment.
    Supplemental
    `dart run tool/component_benchmark.dart --json > .dart_tool/component_benchmark_after_wit_ingestion.json`
    reported component decode at `57.325us/iter` and validation at
    `112.59us/iter`.
  - Done when: annotated `async func`, `stream<T>`, `future<T>`, nested
    resource methods, and `include` WIT boundaries are captured; Preview2
    reports version-profile errors for P3 async/0.3 world targets; Preview3
    accepts the same world for later adapter binding.
  - Claim impact: advances `WIT-INGESTION`; does not complete generated world
    binding, `SUPPORT-P2`, or `SUPPORT-P3`.

## Completion Checklist

Full Wasm and WASI Preview1/Preview2/Preview3 support must remain unclaimed
until every row below is checked. Checking a row requires current command
evidence to be added to that row or to a linked checked child row in the same
commit.

- [ ] `P1-RUNTIME-COMPLETE`
  - Condition: every Preview1 syscall implemented by the native/browser host has
    syscall-level regression coverage, official/conformance-style workload
    coverage, error side-effect checks, and Node/browser/native runtime
    alignment where the runtime owns behavior.
  - Gate: full `test/wasi_test.dart`, targeted Chrome/Node Preview1 gates,
    wasi-testsuite-style Preview1 command/reactor fixtures, and VFS/socket
    benchmark evidence.
- [ ] `P2-WORLD-COMPLETE`
  - Condition: WASI 0.2 worlds/interfaces bind through real component-model
    adapters with resources, canonical ABI lowering/lifting, WIT ingestion, and
    executable host calls.
  - Gate: versioned Preview2 adapter tests, WIT world ingestion tests,
    component execution tests, and relevant resource/adapter benchmarks.
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
