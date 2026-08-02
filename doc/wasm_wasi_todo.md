# wasd Wasm + WASI Execution TODO

This file is an execution checklist, not a narrative roadmap.

Rules:

- One unchecked row means one executable red -> green task.
- Every checked row must name the command evidence that made it green.
- Do not mark P1 complete while any P1 row is unchecked.
- Browser JS is allowed to use the in-memory VFS. Native and Node preopens must
  use the real host filesystem for host-backed paths.

## Phase 1 Target

Ship real, verifiable support for:

- WebAssembly Core 1.0/current standardized core suite.
- WASI 0.1 / Preview1 across native VM, browser JS, and Node JS for the supported
  runtime model.

P2/P3 work starts only after these P1 gates are green.

## Current Evidence

- [x] `WASM-CORE-SPEC`
  - Status: upstream standardized core spec revision `193e551` passes on VM, JS,
    and wasm-compiled runner targets.
  - Evidence:
    `dart run tool/spec_runner.dart --target=all --suite=core --json=.dart_tool/spec_runner/spec_runner_all_core_upstream_193e551_20260629.json --report=.dart_tool/spec_runner/spec_runner_all_core_upstream_193e551_20260629.md`
  - Result: `260/260` files, `65192/65212` commands passed, `0` failed, with
    `20` harness-level custom-section unsupported-command skips.

- [x] `WASI-P1-OFFICIAL-WASIP1`
  - Status: official wasi-testsuite `wasm32-wasip1` command modules pass in the
    current recorded run.
  - Evidence:
    `.dart_tool/wasi_testsuite_wasd_p1_current.json`
  - Result: `72` passed, `0` failed, `0` skipped for `wasm32-wasip1`.
  - Note: the `41` skipped tests in that JSON are `wasm32-wasip3`, not P1.

- [x] `P1-NODE-HOST-REGULAR-FILE-TIMESTAMPS`
  - Status: Node host-backed regular-file `fd_filestat_set_times` and
    `path_filestat_set_times` update the real host file.
  - Evidence:
    `dart test -p node test/wasi_test.dart --name "node preview1 updates real host file timestamps" --reporter=expanded`
  - Result: passed after fixing Node host timestamp mutation and JS `u64`
    filestat writes.

## P1 Verified TODO

- [x] `P1-HOST-PATH-TIMESTAMPS-COMPLETE`
  - Status: host `path_filestat_set_times` now covers real host regular files,
    directories, and no-follow symlinks. Native uses POSIX `utimensat`; Node uses
    `utimesSync` and `lutimesSync`.
  - Red tests:
    `dart test test/wasi_native_host_fs_test.dart --name "native host path_filestat_set_times updates directories and nofollow symlinks" --reporter=expanded`
    `dart test -p node test/wasi_test.dart --name "node preview1 updates real host directory and symlink timestamps" --reporter=expanded`
  - Green evidence:
    `dart test test/wasi_native_host_fs_test.dart --name "native host path_filestat_set_times updates directories and nofollow symlinks" --reporter=expanded`
    `dart test -p node test/wasi_test.dart --name "node preview1 updates real host directory and symlink timestamps" --reporter=expanded`
    `dart test test/wasi_native_host_fs_test.dart --reporter=compact`
    `dart test -p node test/wasi_test.dart --reporter=compact`

- [x] `P1-CLOSEOUT-GATE`
  - Status: full P1 closeout gates pass after the last implementation row.
  - Green evidence:
    `dart test test/wasi_test.dart --reporter=compact`
    `dart test test/wasi_native_host_fs_test.dart --reporter=compact`
    `dart test test/wasm_test.dart test/wasi_test.dart test/wasi_native_host_fs_test.dart --reporter=compact`
    `dart test -p chrome test/wasi_test.dart --reporter=compact`
    `dart test -p node test/wasi_test.dart --reporter=compact`
    `python3 -m py_compile tool/wasi_testsuite_wasd_adapter.py`
    official `wasm32-wasip1` wasi-testsuite run through
    `tool/wasi_testsuite_wasd_adapter.py`
    `dart run tool/wasi_vfs_benchmark.dart --distribution=all --json`
    `dart analyze`

- [x] `README-SUPPORT-MATRIX`
  - Status: README support claims match verified runtime behavior.
  - Green evidence:
    `dart test test/readme_snippets_test.dart test/readme_commands_test.dart --reporter=compact`
    `dart analyze`

- [x] `SUPPORT-P1`
  - Status: Preview1 is complete for the repository's current command-module
    host model.
  - Evidence: all P1 implementation, conformance, runtime, README, benchmark,
    and analyzer gates above are checked.

## Next Blocking TODO

- [x] `SUPPORT-P2`
  - Status: complete for the repository's native Dart VM scope: stable WASI
    0.2.12 `wasi:cli/command` and `wasi:http/proxy` components using the
    synchronous Canonical ABI required by those worlds.
  - Host import bindings required by those worlds: `random`, `clocks`, `io`,
    `cli`, `filesystem`, `sockets`, and `http`, including native filesystem,
    socket, and outgoing HTTP adapters.
  - Green evidence:
    `dart test test/wasi_preview2_conformance_test.dart`
    `dart test test/wasi_preview2_http_proxy_conformance_test.dart`
    `dart test test/wasi_preview2_http_proxy_toolchain_test.dart`
    `dart test test/wasi_testsuite_preview2_runner_test.dart`
    `dart test test/wasi_preview2_host_semantics_test.dart`
    `dart test test/wasi_preview2_native_stat_layout_test.dart`
    `dart test test/wasi_component_native_http_test.dart`
    `dart test test/wasi_component_adapter_plan_test.dart test/wasi_component_resource_table_test.dart test/wasi_component_versioned_host_test.dart`
    `dart test test/wasi_component_public_api_test.dart test/readme_snippets_test.dart`
  - Fixture evidence: the command gate uses a Wasmtime v47.0.3 Preview2
    component; the proxy gates use `wasm-tools` 1.252.0 components generated
    from the official WASI 0.2.12 WIT and verify success, required post-return,
    and unset-response failure paths.
  - Conformance note: the official `wasi-testsuite` currently has no Preview2
    test suite, so it is not presented as Preview2 conformance evidence.
  - Scope boundary: browser/Node Preview2 execution, Component Model 0.3
    async/future/stream/task features, experimental proposal packages, general
    lifted indirect signatures, and Preview3 remain incomplete.
  - Native limitation: Dart `HttpClient` has no trailer API, so outgoing HTTP
    requests with trailers and incoming responses declaring trailers fail
    explicitly; proxy response trailers are preserved.
  - Resolver limitation: dependency-free IDNA ToASCII covers canonical labels;
    labels requiring Unicode normalization tables or ContextJ/ContextO are
    rejected explicitly.

- [ ] `SUPPORT-P3`
  - Status: in progress. Component host/filesystem/async-profile scaffolding is
    present; full runtime coverage and conformance closeout are not complete.
