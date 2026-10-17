# Standards coverage and the road to 1.0

This implementation and acceptance plan retains the historical `0.5.0`
(`528b2b828f979d08ba1798f7e8e955e892ab052d`) baseline checked on 2026-10-01.
Release evidence below identifies `0.6.0-dev.2` and the additions in
`0.6.0-dev.3` separately. Historical results retain their original scope.
A target in this document is not a support claim. Release support must be backed
by WASD execution, validation, and host tests at the exact release commit.

## Fixed specification targets

| Area | Target for 1.0 | Maturity and source |
| --- | --- | --- |
| Core WebAssembly | Release 3.0, W3C snapshot dated 2026-10-01; spec source `957c932e7158c5a6891be68ca424aaa0aa505f97` | [W3C Candidate Recommendation Draft](https://www.w3.org/TR/2026/CRD-wasm-core-2-20261001/), distinct from the [2019 Recommendation](https://www.w3.org/TR/2019/REC-wasm-core-1-20191205/) |
| WASI Preview1 | Legacy `wasi_snapshot_preview1`; `wasi-0.1` branch snapshot `fae981bae14809d91f9bc2d63852d461f331d161` | [Frozen WITX](https://github.com/WebAssembly/WASI/tree/fae981bae14809d91f9bc2d63852d461f331d161/preview1/witx); not the Component Model ABI |
| WASI Preview2 | WASI `0.2.12` | [Tagged WIT contract](https://github.com/WebAssembly/WASI/tree/v0.2.12); stable release interfaces, not all experimental WASI proposals |
| WASI Preview3 | WASI `0.3.1`, source `59e48bfe3fae9bf2480eb15abd8f55999eb3b395`; retain explicit `0.3.0` compatibility | [Release](https://github.com/WebAssembly/WASI/releases/tag/v0.3.1); includes newly required `map`, `implements`, and `external-id` support |
| Component Model | General validation, linking, instantiation, and execution of the features required by the frozen WASI releases; freeze an updated source revision before its acceptance gate | [Specification and tests](https://github.com/WebAssembly/component-model); an evolving proposal, not a W3C Recommendation. Existing async gate is pinned to `73b7ad51d3b5d6f1ef53c923d8c585e28b242bcc` |
| Additional proposals | Track individually by named proposal, source revision, feature gate, and test results | [Core proposals](https://github.com/WebAssembly/proposals), [WASI phase process](https://github.com/WebAssembly/WASI/blob/main/docs/phase-process.md). No implicit promise to implement future revisions |

Core module binary version `1` does not mean Core specification release `1.0`.
Likewise, internal `core`, `stable`, and `full` feature profile names do not
describe the current standardization status of GC, SIMD, or exceptions.
Features incorporated into the frozen Core 3.0 target belong in its acceptance
gate even if the code still calls them proposals.

The June 2026 Core testsuite in the historical `0.5.0` matrix below predates the
October specification snapshot. That baseline is retained separately from the
current frozen Core gate.

`tool/core_spec_inventory.json` records all `261` official WAST source paths
and Git blob hashes at spec revision
`957c932e7158c5a6891be68ca424aaa0aa505f97`: `258` under `test/core/` and `3`
under `test/custom/`. The older flattened testsuite mirror at
`193e551ff22663995b1ac95dc62344133669e14b` omitted
`test/core/memory_grow.wast` through a basename collision with
`test/core/multi-memory/memory_grow.wast` and predates updates to eight other
inputs. The inventory reuses the `252` unchanged mirror files and restores the
nine remaining official files under `test/fixtures/core_spec/`, preserving the
original paths and bytes.

Run the frozen gate with the pinned precompiled toolchain:

```sh
dart run tool/core_spec_runner.dart --output-json=build/core.json --output-md=build/core.md
```

The current Dart VM result with `wasm-tools` `1.262.0` is `261/261` files and
`65,336/65,336` commands passed, zero failures and zero skips. The runner checks
the complete inventory before execution and rejects empty conversions or any
skipped command. Core CI runs this gate for each Dart SDK in its matrix.

The command count includes module setup and validation assertions.
`assert_malformed` assertions containing text modules are judged by external
text parsers; binary decoding, validation and execution use WASD's internal
interpreter. This gate does not establish equivalent coverage through the
public API, its feature selection, or other runtimes. The historical Component
Model async gate retains its recorded `wasm-tools` `1.254.0` validator; the
newer Core converter rejects the frozen draft's removed `cancellable` option.

The `0.6.0-dev.3` Component `map` type and synchronous Canonical ABI adapter slice
uses source `0220da84209397d9067c19cac83dae969aa85a7b`. Its binary validation,
memory conversion, bound callbacks and WIT binding regressions are described in
[Component map adapters](component_maps.md). This bounded gate is separate from
general Component assertion execution and the historical async gate above.

The same frozen Component source also supplies `implements`, version suffix
and `external-id` name attributes. Imports, exports, type exports and inline
exports preserve this metadata while linking and uniqueness use the external
name. Modern binary name tags `0x00` and `0x01` both carry a plain name;
`0x02` carries a name and attribute vector. The earlier suffix-first heuristic
has been replaced by these frozen rules.

WIT parsing retains applicable `externalId` metadata and separates named
interface labels from their targets. Two imports of the same interface bind
through separate labels and callbacks; `include ... with` preserves renamed
labels and resource identities. These checks do not establish general
Component composition, executable direct world functions or complete WASI
`0.3.1` adoption.

The `0.6.0-dev.3` WASI `0.3.1` contract/linking slice uses source
`59e48bfe3fae9bf2480eb15abd8f55999eb3b395` and retains exact `0.3.0` support.
It resolves six stable packages and eight worlds, reuses existing host
implementations through exact versioned callback keys, and runs custom
`0.3.1` command/service inputs with real host calls and resource cleanup.
The source delta and normalized contract digests are recorded separately in
`tool/wasi_preview3_contract.lock.json`. The fixed official `45/45` native
Linux/macOS gate still uses `0.3.0` guests; it is compatibility evidence for
that version, not an official `0.3.1` suite. General Component/async assertion
execution and full package/world/platform acceptance remain open.

The `0.6.0-dev.3` WASD Component execution gate covers two complete official
files at source `0220da84209397d9067c19cac83dae969aa85a7b`:

| File | Frozen Git blob | Commands |
| --- | --- | ---: |
| `test/values/strings.wast` | `e96f54e97689a32ba70b05e12226e01b8dea024b` | 17 |
| `test/values/numerics.wast` | `99fcbc03b0b352b29db247c90085ad0febbd3fe5` | 26 |

The combined gate executes `43/43` commands: 17 actual component
initializations, one definition registration, 18 exact return assertions and
seven invocation trap assertions. The numeric file exercises integer narrowing,
bool normalization, Unicode scalar validation, flags masking and nested calls
with lexical outer type aliases. Every module instance starts fresh.
Decode, link, lookup and ordinary host errors cannot satisfy invalid-char traps.
The runner verifies independently pinned source hashes, freshly converts inputs
with pinned `wasm-tools` `1.262.0`, and executes them through WASD's existing
Dart interpreter and Canonical ABI adapters. The converter supplies inputs;
it is not the execution engine.

```sh
dart run tool/component_spec_runner.dart --output-json=build/component-values.json
```

Core CI runs these selected complete files on both Dart SDKs. This remains separate
from the historical decode, external validation and reference-runtime results.
General Component composition, additional value codecs, full async assertion
execution and a portable public instance API remain open requirements.
Nested Component starts and concrete local resource aliases are explicitly
rejected before execution. Imported resource identities and the numeric
file's lexical type aliases remain supported.

## Implementation and evidence matrix

The `0.6.0-dev.3` Preview1 gate freezes official runner/source
`6600796756adce3632409d7e207a9834c9d99ff8` and precompiled fixtures
`c63d52e69316d1aa2c9e7db6251892775204e7e0` in
`tool/wasi_preview1_contract.lock.json`. It verifies all 137 fixture inputs
and 15 runner source files by SHA-256 and Git blob before executing exactly
72 unique cases (AssemblyScript 12, C 14, Rust 46). Missing, duplicate,
unexecuted, skipped, xfailed or xpassed cases fail the gate. Native CI runs
this profile on Linux and macOS and preserves the raw result and gate report.
CI compiles WASD's Dart Preview1 runner to native AOT once and reuses that
executable for all 72 processes. `WASD_PREVIEW1_RUNNER` selects that single
executable path; leaving it unset retains the Dart JIT runner. Reports record
the selected profile and executable identity. The guest fixtures, per-case
timeout and Preview2/Preview3 runner selection stay unchanged.

```sh
dart run tool/wasi_testsuite_preview1_gate.dart --testsuite-dir third_party/wasi-testsuite-fixtures --runner-dir third_party/wasi-testsuite-source/test-runner --python build/wasi-testsuite-venv/bin/python --json build/wasi-preview1.json
```

This selected suite does not import `fd_datasync`, `fd_sync`, `proc_raise`,
`sock_accept`, `sock_recv` or `sock_send`; `sock_shutdown` has error cases only.
Successful inherited-socket operations, host sync/durability and process/thread
CPU timers and guest-specific CPU accounting still need separate acceptance.
The `0.6.0-dev.3` CPU-clock read fix uses existing libc `clock_gettime/getres`
on 64-bit Linux/macOS, with the correct OS clock IDs and measured resolution.
Node uses capability-detected process/thread CPU APIs and preserves full u64
nanosecond output. Missing, invalid or failed CPU APIs return `INVAL` without
writing output; browsers do not substitute a wall clock. CPU subscriptions
are explicitly unsupported and produce clock events with `INVAL`.
Node and browser CI runs
`test/wasi_test.dart` as in-repo regressions with explicit platform skips;
neither profile executes these 72 official guests.

| Area | Implementation in 0.5.0 | Evidence and remaining work |
| --- | --- | --- |
| Core decoding and validation | Pure Dart decoder, predecoder, and validator under `lib/src/wasm/backend/native/interpreter/` | Fresh VM baseline: `260/260` official root WAST files, `65,212/65,212` commands, zero skips, at testsuite `193e551ff22663995b1ac95dc62344133669e14b`, using wasm-tools `1.254.0`. Enumerate newer specification deltas and public API feature selection |
| Numeric, control, memory, table, reference, tail-call, SIMD, GC, exception, memory64/multiple-memory instructions | Interpreter paths exist; feature availability depends on the entrypoint/profile | Same root-suite baseline; it does not prove cross-platform parity, every valid type combination, or proposals outside that suite. GC `v128` data initialization was an uncovered gap in synchronous and forced async execution |
| Threads and shared memory | Atomic/thread-related interpreter paths exist | Sequential instruction tests do not prove concurrent shared-memory, scheduling, or wait/notify behavior. Freeze an explicit threading profile and run real concurrency tests |
| WASI Preview1 | VM host, in-repo Node host, browser shim and virtual filesystem | Historical unit/regression coverage; the `0.6.0-dev.3` pinned 72-case native gate above replaces the unpinned official report. Host syscall and platform boundaries remain open |
| WASI Preview2 | VM command/proxy runners, synchronous Canonical ABI, WIT adapters and host interfaces for random, clocks, io, cli, filesystem, sockets, http | Focused conformance/toolchain tests exist. Audit all stable package exports and execution worlds. A command/proxy runner is not general Component Model execution |
| WASI Preview3 0.3.0 | VM command/service runners, async Canonical ABI, stream/future/task/resource support; six-package/eight-world lock | Historical published `0.5.0` / `0.6.0-dev.1` baseline: `39/45` fixtures passed, with six native TCP failures. The `0.6.0-dev.2` acceptance gate records `45/45` passed and zero failed, skipped, xfailed or xpassed for the Linux/macOS native AOT profile, including same-socket TCP bind/listen/connect and monotonic clock deadline checks. `tool/wasi_preview3_contract.lock.json` records this gate. Version `0.6.0-dev.3` adds 0.3.1 contract/linking; complete package/world/platform acceptance remains open |
| Component Model binary/WIT | Strict decoder and component/WIT/adapter machinery exist | Frozen historical async gate: WASD decode `37/37`, wasm-tools validation `31/31`, Wasmtime reference execution `31/31`. Only the first executes WASD code, and it only decodes. Add WASD assertion execution for general synchronous and async components |
| Component Model composition | WASI runners support particular compositions and host bindings | Cover nested components, imports/exports, aliasing, types, resource ownership, canonical lift/lower, instantiation and failure semantics independently of WASI-specific runners |
| Stable host capabilities | VM filesystem/network/HTTP adapters and browser/Node P1 adapters | Keep explicit capability contracts for platform-scoped TCP bind/listen, HTTP trailers, IPv6 metadata and filesystem race guarantees; never replace an unsupported operation with simulated success |
| Experimental WASI packages | Outside the current six/seven stable package contracts | Keep a separate tracked backlog for timezone, key-value, machine learning, runtime config, WebGPU and device APIs. Package names or proposal maturity alone do not establish portable host support |

The pure Dart execution engine must remain free of a native Wasm-runtime
dependency. Current public JS backends call the platform JavaScript
`WebAssembly` engine; that is a separate adapter, not evidence that the Dart
interpreter passed on Node or in a browser. Portable interpreter access and
cross-target tests remain part of the 1.0 work. Preview2/3 currently require the
Dart VM host. Browser permissions and missing host services must be represented
explicitly rather than promised as identical OS capabilities.

The `ffi` dependency provides native Preview1 OS facilities and, in
`0.6.0-dev.2`, Linux/macOS native Preview3 TCP host sockets. It does not implement
Wasm execution or introduce a native Wasm runtime. Host adapters must state
their OS dependencies and capabilities separately from the pure Dart interpreter.

## Incremental releases and acceptance

These are candidate batches, not preannounced release dates or completed work.
Each may be split into smaller independently tested 0.x releases.

| Candidate | Deliverable and required acceptance |
| --- | --- |
| 0.5.1 | GC `v128` data initialization in synchronous and forced async execution, tests for byte order/unaligned offsets/bounds/drop, unchanged pinned Core suite result; repair or classify full-suite baseline failures before release |
| 0.6.x | Updated/pinned Core 3.0 inventory and public feature contract; close uncovered validation/execution combinations, numeric bit preservation and GC default/segment boundary gaps; strict official assertions plus local regressions |
| 0.7.x | General synchronous Component Model validation/composition/execution, full Canonical ABI and resource lifetime checks; assertions executed by WASD independently of command/proxy runners |
| 0.8.x | General async Component Model execution and WASI 0.3.1 adopted features; streams/futures/cancellation/backpressure/trap cleanup and multi-component tests; re-run the async suite through WASD |
| 0.9.x | Complete stable P1/P2/P3 package/world audit, portable interpreter entrypoints, real host capabilities and concurrency profiles; official WASI suites, VM/Node/browser matrix, Linux/macOS/Windows host checks |
| 1.0.0-rc.x | Freeze public APIs, versions, suite revisions and capability matrix; all required executable assertions pass, with exclusions limited to explicitly named optional host capabilities; documentation/example/package consumer checks |
| 1.0.0 | Exact-head CI and substantive review, resolved review findings, package dry run, authorized publish, independently verified pub archive/version/tag and clean scoped handoff |

Core semantics, component execution and mandatory WASI behavior cannot be
silently excluded to obtain a green release. Where a host cannot express a
required capability, provide an explicit supported adapter/profile or retain
the failing conformance result and block a full-support claim.

Use the [official Core testsuite](https://github.com/WebAssembly/testsuite),
[Component Model tests](https://github.com/WebAssembly/component-model/tree/main/test)
and [official WASI testsuite](https://github.com/WebAssembly/wasi-testsuite).
Reports must distinguish WASD execution, WASD decoding, external validation,
reference-runtime execution, failures and skips. Store exact input/tool/output
revisions with release evidence; never infer conformance from README prose.
