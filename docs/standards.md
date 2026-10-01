# Standards coverage and the road to 1.0

This is an implementation and acceptance plan, checked against `0.5.0`
(`528b2b828f979d08ba1798f7e8e955e892ab052d`) on 2026-10-01. A target in this
document is not a support claim. Release support must be backed by WASD
execution, validation, and host tests at the exact release commit.

## Fixed specification targets

| Area | Target for 1.0 | Maturity and source |
| --- | --- | --- |
| Core WebAssembly | Release 3.0, W3C snapshot dated 2026-10-01; spec source `957c932e7158c5a6891be68ca424aaa0aa505f97` | [W3C Candidate Recommendation Draft](https://www.w3.org/TR/2026/CRD-wasm-core-2-20261001/), distinct from the [2019 Recommendation](https://www.w3.org/TR/2019/REC-wasm-core-1-20191205/) |
| WASI Preview1 | Legacy `wasi_snapshot_preview1`, with a separately pinned WITX/fixture revision before its release gate | [WASI 0.1](https://wasi.dev/releases/wasi-p1); not the Component Model ABI |
| WASI Preview2 | WASI `0.2.12` | [Tagged WIT contract](https://github.com/WebAssembly/WASI/tree/v0.2.12); stable release interfaces, not all experimental WASI proposals |
| WASI Preview3 | WASI `0.3.1`, source `59e48bfe3fae9bf2480eb15abd8f55999eb3b395`; retain explicit `0.3.0` compatibility | [Release](https://github.com/WebAssembly/WASI/releases/tag/v0.3.1); includes newly required `map`, `implements`, and `external-id` support |
| Component Model | General validation, linking, instantiation, and execution of the features required by the frozen WASI releases; freeze an updated source revision before its acceptance gate | [Specification and tests](https://github.com/WebAssembly/component-model); an evolving proposal, not a W3C Recommendation. Existing async gate is pinned to `73b7ad51d3b5d6f1ef53c923d8c585e28b242bcc` |
| Additional proposals | Track individually by named proposal, source revision, feature gate, and test results | [Core proposals](https://github.com/WebAssembly/proposals), [WASI phase process](https://github.com/WebAssembly/WASI/blob/main/docs/phase-process.md). No implicit promise to implement future revisions |

Core module binary version `1` does not mean Core specification release `1.0`.
Likewise, internal `core`, `stable`, and `full` feature profile names do not
describe the current standardization status of GC, SIMD, or exceptions.
Features incorporated into the frozen Core 3.0 target belong in its acceptance
gate even if the code still calls them proposals.

The June 2026 Core testsuite below predates the October specification snapshot.
Passing that suite is a useful baseline, not proof of all October changes or
complete coverage. Refresh and pin the suite, then account for every delta
before claiming conformance to the frozen specification.

## Implementation and evidence matrix

| Area | Implementation in 0.5.0 | Evidence and remaining work |
| --- | --- | --- |
| Core decoding and validation | Pure Dart decoder, predecoder, and validator under `lib/src/wasm/backend/native/interpreter/` | Fresh VM baseline: `260/260` official root WAST files, `65,212/65,212` commands, zero skips, at testsuite `193e551ff22663995b1ac95dc62344133669e14b`, using wasm-tools `1.254.0`. Enumerate newer specification deltas and public API feature selection |
| Numeric, control, memory, table, reference, tail-call, SIMD, GC, exception, memory64/multiple-memory instructions | Interpreter paths exist; feature availability depends on the entrypoint/profile | Same root-suite baseline; it does not prove cross-platform parity, every valid type combination, or proposals outside that suite. GC `v128` data initialization was an uncovered gap in synchronous and forced async execution |
| Threads and shared memory | Atomic/thread-related interpreter paths exist | Sequential instruction tests do not prove concurrent shared-memory, scheduling, or wait/notify behavior. Freeze an explicit threading profile and run real concurrency tests |
| WASI Preview1 | VM host, in-repo Node host, browser shim and virtual filesystem | Unit/regression tests exist. Re-run a pinned official P1 suite and platform matrix; document permissions and native filesystem/syscall boundaries |
| WASI Preview2 | VM command/proxy runners, synchronous Canonical ABI, WIT adapters and host interfaces for random, clocks, io, cli, filesystem, sockets, http | Focused conformance/toolchain tests exist. Audit all stable package exports and execution worlds. A command/proxy runner is not general Component Model execution |
| WASI Preview3 0.3.0 | VM command/service runners, async Canonical ABI, stream/future/task/resource support; six-package/eight-world lock | `tool/wasi_preview3_contract.lock.json` records `39/45` official fixtures, with six TCP failures; these historical figures were not re-run for this first Core slice. Upgrade to 0.3.1 with feature-level regressions |
| Component Model binary/WIT | Strict decoder and component/WIT/adapter machinery exist | Frozen historical async gate: WASD decode `37/37`, wasm-tools validation `31/31`, Wasmtime reference execution `31/31`. Only the first executes WASD code, and it only decodes. Add WASD assertion execution for general synchronous and async components |
| Component Model composition | WASI runners support particular compositions and host bindings | Cover nested components, imports/exports, aliasing, types, resource ownership, canonical lift/lower, instantiation and failure semantics independently of WASI-specific runners |
| Stable host capabilities | VM filesystem/network/HTTP adapters and browser/Node P1 adapters | Native TCP bind/listen separation, HTTP trailers, IPv6 metadata and filesystem race guarantees need explicit capability contracts; never replace an unsupported operation with simulated success |
| Experimental WASI packages | Outside the current six/seven stable package contracts | Keep a separate tracked backlog for timezone, key-value, machine learning, runtime config, WebGPU and device APIs. Package names or proposal maturity alone do not establish portable host support |

The pure Dart execution engine must remain free of a native Wasm-runtime
dependency. Current public JS backends call the platform JavaScript
`WebAssembly` engine; that is a separate adapter, not evidence that the Dart
interpreter passed on Node or in a browser. Portable interpreter access and
cross-target tests remain part of the 1.0 work. Preview2/3 currently require the
Dart VM host. Browser permissions and missing host services must be represented
explicitly rather than promised as identical OS capabilities.

The `ffi` dependency currently provides native Preview1 OS facilities; it does
not implement Wasm execution. Any future optional host adapter must state its
OS dependencies and capabilities separately from the interpreter.

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
