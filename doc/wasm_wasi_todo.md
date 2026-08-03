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
    component; the proxy gates use `wasm-tools` 1.254.0 components generated
    from the official WASI 0.2.12 WIT and verify success, required post-return,
    and unset-response failure paths.
  - Conformance note: the official `wasi-testsuite` currently has no Preview2
    test suite, so it is not presented as Preview2 conformance evidence.
  - Scope boundary: browser/Node Preview2 execution, experimental proposal
    packages, and general lifted indirect signatures remain outside the P2
    contract. Preview3 is tracked separately below.
  - Native limitation: Dart `HttpClient` has no trailer API, so outgoing HTTP
    requests with trailers and incoming responses declaring trailers fail
    explicitly; proxy response trailers are preserved.
  - Resolver limitation: dependency-free IDNA ToASCII covers a conservative
    canonical subset and validates existing A-labels; disallowed symbols,
    malformed A-labels, and labels requiring Unicode normalization tables or
    ContextJ/ContextO are rejected explicitly.

- [x] `SUPPORT-P3`
  - Status: complete for the frozen native Dart VM scope: stable WASI 0.3.0
    `wasi:cli/command` and `wasi:http/service` components.
  - Frozen WASI contract: stable WASI 0.3.0 commit
    `3ee2a590c766594ae44a54730fc74fc27da5c609`; six packages (`random`,
    `clocks`, `filesystem`, `sockets`, `cli`, `http`) and eight worlds
    (`random/imports`, `clocks/imports`, `filesystem/imports`,
    `sockets/imports`, `cli/imports`, `cli/command`, `http/service`,
    `http/middleware`). `wasi:clocks/timezone` is excluded.
  - Frozen Component Model contract: commit
    `73b7ad51d3b5d6f1ef53c923d8c585e28b242bcc`, async gate.
  - Frozen wasi-testsuite contract: source commit
    `6600796756adce3632409d7e207a9834c9d99ff8`, precompiled fixture commit
    `c63d52e69316d1aa2c9e7db6251892775204e7e0`, `45` `wasm32-wasip3`
    fixtures. The machine-readable source of truth is
    `tool/wasi_preview3_contract.lock.json`.
  - Implemented runtime scope: native Dart VM command and HTTP service runners,
    standard imports for all six packages, async task/subtask/waitable/future/
    stream/cancellation/backpressure semantics, scoped resources and component
    types, and Preview2 compatibility imports used by official adapters.
  - Component Model evidence:
    `dart run tool/component_decode_probe.dart --testsuite-dir=/path/to/component-model/test --groups=async --strict --require-testsuite-dir`
    reports `37/37` strict WASD decodes;
    `dart run tool/component_official_runner.dart --testsuite-dir=/path/to/component-model/test --groups=async --wasm-tools-bin=.toolchains/bin/wasm-tools --require-testsuite-dir --require-engine --no-default-expected-failures`
    reports `31/31` `wasm-tools` validations;
    the same runner with Wasmtime `48.0.0 (e8ac8c27f)` reports `31/31`
    reference executions. The validation and reference runs do not execute the
    WAST assertions through WASD.
  - Local green evidence:
    `dart test test/component_test.dart`
    `dart test test/wasi_preview3_standard_wit_test.dart`
    `dart test test/wasi_preview3_async_runtime_test.dart`
    `dart test test/wasi_preview3_service_runner_test.dart`
    `dart test test/wasi_preview3_native_filesystem_test.dart`
    `dart test test/wasi_preview3_native_http_test.dart`
    `dart test test/wasi_preview3_sockets_test.dart`
    `dart test test/wasi_preview3_task_return_runner_test.dart`
    `dart test test/wasi_testsuite_preview3_runner_test.dart`
  - Official closeout evidence:
    `dart run tool/wasi_testsuite_preview3_runner.dart --testsuite-dir=/path/to/wasi-testsuite --runner-dir=/path/to/wasi-testsuite/test-runner --python=/path/to/venv/bin/python`
    reports `39/45` `wasm32-wasip3` fixtures passed with `0` skipped, xfailed,
    or xpassed. The six failures (`sockets-tcp-bind`, `sockets-tcp-listen`,
    `sockets-echo`, `sockets-tcp-connect`, `sockets-tcp-receive`, and
    `sockets-tcp-send`) require the explicitly unsupported native TCP
    bind/listen split.
  - Scope boundary: Node.js and browser Preview3 runners, timezone, error
    context, explicit cooperative thread creation, more-async builtins,
    fixed-length lists, maps, memory64, and general Component Model WAST
    execution are not claimed.
  - Native filesystem boundary: preopens reject static absolute-path,
    parent-traversal, and symlink escapes. Dart's path-based filesystem APIs
    cannot prevent an external actor from concurrently replacing a preopen
    path node; isolation therefore requires preopens that untrusted actors
    cannot mutate.
  - Native sockets boundary: synchronous Preview3 imports may return pending
    Dart callbacks that the component runner waits for. Explicit native TCP
    bind reports `not-supported` because `dart:io` starts listening as part of
    `ServerSocket.bind`; unbound listen and connect remain available. UDP bind
    and implicit connect wait for a real `RawDatagramSocket`. Active TCP and
    UDP endpoints receive the supported raw socket options. Because
    `RawDatagramSocket` has no IPv6-only bind option, an IPv6 wildcard UDP
    socket may also reserve the matching IPv4 port; IPv4 and IPv4-mapped
    datagrams are filtered before they reach that IPv6 guest socket. Native
    addresses with nonzero IPv6 flow info or numeric scope IDs report
    `not-supported` because `dart:io` cannot preserve those fields.
