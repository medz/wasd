# WASM + WASI Backlog

Last updated: 2026-02-25

This document tracks remaining work, split into two streams:
- `WASM`: core WebAssembly decode/validation/execution scope.
- `WASI`: preview1 host interface and filesystem semantics.

## WASM Pending Work

| ID | Priority | Item | Current Evidence | Done Criteria |
| --- | --- | --- | --- | --- |
| WASM-01 | P0 | Expand static validation from pragmatic subset to fuller spec coverage. | `doc/core_completion_matrix.md` notes validator debt; `lib/src/validator.dart`. | Validation catches full control-flow/type/index constraints expected for supported feature set; add targeted negative tests. |
| WASM-02 | P0 | Implement SIMD execution semantics behind feature gate. | `lib/src/predecode.dart` throws when `0xFD` is enabled. | SIMD opcodes decode+execute for selected baseline subset; add execution tests and feature-gate tests. |
| WASM-03 | P0 | Implement threads/atomics/shared-memory semantics behind feature gate. | `lib/src/predecode.dart` throws when `0xFE` is enabled. | Atomics opcodes execute correctly for chosen subset; memory/shared behavior specified and tested. |
| WASM-04 | P1 | Implement exception-handling proposal execution behind feature gate. | `lib/src/predecode.dart` throws for EH opcodes. | EH instructions are decoded/validated/executed with runtime tests for throw/catch flow. |
| WASM-05 | P1 | Implement GC proposal execution behind feature gate. | `lib/src/predecode.dart` throws when `0xFB` is enabled. | GC-related instruction subset is supported with validation and runtime tests. |
| WASM-06 | P1 | Extend beyond single-memory model. | `lib/src/instance.dart`, `lib/src/vm.dart`, `lib/src/validator.dart` enforce memory index `0` / single memory. | Multi-memory indexing works for decode, validation, data init, and runtime load/store paths. |
| WASM-07 | P1 | Broaden element/reference support beyond current funcref-only paths. | `lib/src/module.dart` enforces `funcref` element constraints and `elemkind 0x00`. | Element segment handling supports required reference-type combinations for selected spec scope. |
| WASM-08 | P2 | Add component model binary/runtime plan and staged implementation. | `lib/src/module.dart` comment: component model format not implemented. | A scoped plan exists with feature gating, parser entry points, and first executable milestone. |

## WASI Pending Work

| ID | Priority | Item | Current Evidence | Done Criteria |
| --- | --- | --- | --- | --- |
| WASI-01 | P0 | Implement missing `fd_prestat_set_flags`. | Listed as remaining in `README.md`; no implementation in `lib/src/wasi_preview1.dart`. | Import is exposed, rights/flag behavior defined, and positive+negative tests added. |
| WASI-02 | P0 | Complete `path_open` symlink-follow semantics (`LOOKUP_SYMLINK_FOLLOW`). | Listed as remaining in `README.md`; `_pathOpen` validates `dirflags` but does not apply symlink-follow behavior. | Behavior matches selected preview1 semantics for follow/no-follow cases with tests. |
| WASI-03 | P0 | Replace socket stubs with real behavior (`sock_accept/recv/send/shutdown`). | `lib/src/wasi_preview1.dart` currently returns `ENOSYS`. | Socket calls work for a defined baseline (or return spec-correct errors) with integration tests. |
| WASI-04 | P1 | Replace `proc_raise` stub with defined signal behavior or explicit compatibility policy. | `lib/src/wasi_preview1.dart` currently returns `ENOSYS`. | Behavior is implemented (or intentionally mapped) and documented with tests. |
| WASI-05 | P1 | Tighten `fd_filestat_set_times` and `path_filestat_set_times` edge semantics. | `README.md` calls out remaining full-flag semantics work. | All flag combinations and edge cases are validated against documented expectations. |
| WASI-06 | P1 | Improve `poll_oneoff` behavior beyond current immediate event filling. | `lib/src/wasi_preview1.dart` currently fills events synchronously with simplified readiness model. | Subscription timing/readiness behavior is spec-aligned for supported event types and tested. |
| WASI-07 | P2 | Harden host-IO policy model (sandbox and capability boundaries). | `doc/core_completion_matrix.md` notes policy model can be hardened. | Explicit policy options exist, escape tests are added, and defaults are documented. |
| WASI-08 | P2 | Keep host-backed and in-memory filesystem behavior aligned. | Conditional backend split in `lib/src/wasi_fs_auto.dart` + filesystem abstractions. | Backend parity tests cover same API contracts and error mapping across both backends. |

## Suggested Execution Order

1. WASM-01, WASM-02, WASM-03 (core correctness + major feature gates).
2. WASI-01, WASI-02, WASI-03 (highest visible preview1 gaps).
3. WASM-04 to WASM-07 and WASI-04 to WASI-06 (semantics completion).
4. WASM-08, WASI-07, WASI-08 (long-tail architecture and hardening).
