# WASD

WASD (Wasm And Dart System / WebAssembly System for Dart) is a pure Dart WebAssembly runtime inspired by zwasm's layered design,
implemented as a cross-target interpreter that works on Dart native, JS, and
Wasm compile targets.

## Current coverage

- Binary module decoding
  - sections: `type`, `import`, `function`, `table`, `memory`, `global`,
    `export`, `start`, `element`, `code`, `data`, `data_count`
  - custom sections are skipped safely during decode
- Runtime features
  - function/table/memory/global imports
  - global initialization with const-expression evaluation
  - active element initialization
  - active data initialization
  - start function execution
  - pre-instantiation static validation phase (`WasmValidator`)
- Control flow
  - `block`, `loop`, `if`, `else`, `br`, `br_if`, `br_table`, `return`
- Calls
  - `call`, `call_indirect` + signature checking
  - tail-call opcodes: `return_call`, `return_call_indirect`
- Variable and memory access
  - `local.get/set/tee`, `global.get/set`
  - full MVP load/store family (`i32/i64/f32/f64` + 8/16/32 signed/unsigned variants)
  - `memory.size`, `memory.grow`
  - table instructions: `table.get/set`
- Numeric execution
  - `i32` full core arithmetic/bit/compare ops
  - `i64` core arithmetic/bit/compare ops
  - `f32/f64` core arithmetic and compare ops
  - conversions/reinterpret/sign-extension/trunc-sat families
- Bulk memory/table
  - `memory.init`, `data.drop`, `memory.copy`, `memory.fill`
  - `table.init`, `elem.drop`, `table.copy`, `table.grow`, `table.size`, `table.fill`
- Multi-value
  - multi-result functions (including import/export call paths)
- WASI Preview1 (phase-2 baseline)
  - `fd_write`, `fd_read`, `fd_pread`, `fd_pwrite`
  - `fd_seek`, `fd_tell`, `fd_advise`, `fd_allocate`
  - `fd_datasync`, `fd_sync`
  - `fd_filestat_get`, `fd_filestat_set_size`, `fd_filestat_set_times`
  - `fd_fdstat_get`, `fd_fdstat_set_flags`, `fd_fdstat_set_rights`
  - `fd_prestat_get`, `fd_prestat_dir_name`, `fd_readdir`
  - `fd_renumber`
  - `fd_close`, `path_open`, `path_rename`, `path_unlink_file`
  - `path_create_directory`, `path_remove_directory`
  - `path_filestat_get`, `path_filestat_set_times`
  - `path_link`, `path_symlink`, `path_readlink`
  - `args_sizes_get`, `args_get`
  - `environ_sizes_get`, `environ_get`
  - `clock_time_get`, `clock_res_get`, `random_get`
  - `poll_oneoff`, `sched_yield`, `proc_exit`
  - `proc_raise` (configurable via `procRaiseMode`: `enosys` / `success` / `trap`)
  - `sock_accept`, `sock_recv`, `sock_send`, `sock_shutdown` via transport abstraction
    (`socketTransport`; default remains `ENOSYS` when transport is absent)
  - filesystem backend auto-selection via conditional import:
    - supports `dart:io`: use host-backed filesystem
    - no `dart:io`: fallback to `WasiInMemoryFileSystem`
  - socket backend auto-selection via conditional import (when `preopenedSockets` provided):
    - supports `dart:io`: `RawServerSocket`/`RawSocket` host transport
    - supports `dart:js_interop`: `package:web` `WebSocket` transport
    - no host backend support: no-op transport (socket calls remain `ENOSYS`)
  - can force in-memory backend: `WasiPreview1(preferHostIo: false)`
  - custom socket transport injection: `WasiPreview1(socketTransport: ...)`
  - host-io path sandbox checks (canonical root boundary enforcement)
  - proposal feature gates: `WasmFeatureSet(simd/threads/exceptionHandling/gc/componentModel)`
  - helper runner: `WasiRunner` (instantiate + bind memory + invoke `_start`)
  - runtime adapter: [lib/src/wasi_preview1.dart](lib/src/wasi_preview1.dart)
  - filesystem abstractions: [lib/src/wasi_filesystem.dart](lib/src/wasi_filesystem.dart)
  - conditional backend selector: [lib/src/wasi_fs_auto.dart](lib/src/wasi_fs_auto.dart)

## Not implemented yet

- SIMD execution semantics
- threads/atomics/shared memory semantics
- exception handling semantics
- GC/reference-subtyping semantics
- component model semantics
- remaining WASI Preview1 semantics (`fd_prestat_set_flags`, `fd_filestat_set_times` full flag semantics, `path_open` symlink-follow semantics, and advanced socket lifecycle semantics beyond current transport-backed `sock_*` subset, etc.)

## Examples

- Basic invocation: [example/invoke.dart](example/invoke.dart)
- Load various wasm modules: [example/load_various_wasm.dart](example/load_various_wasm.dart)
- Load `.wasm` from file: [example/load_from_file.dart](example/load_from_file.dart)
- Batch-load all `.wasm` files under a directory: [example/load_wasm_suite.dart](example/load_wasm_suite.dart)
- Minimal WASI hello example: [example/wasi_hello.dart](example/wasi_hello.dart)
- WASI file-write example (via in-memory FS): [example/wasi_write_file.dart](example/wasi_write_file.dart)
- WASI seek/stat example: [example/wasi_seek_stat.dart](example/wasi_seek_stat.dart)
- WASI runner example (`_start` + proc_exit): [example/wasi_runner.dart](example/wasi_runner.dart)
- Doom wasm headless runner: [example/run_doom_wasm.dart](example/run_doom_wasm.dart)
- Doom wasm terminal playable runner: [example/play_doom_terminal.dart](example/play_doom_terminal.dart)
- Doom asset bootstrap script: [example/doom/setup_assets.sh](example/doom/setup_assets.sh)

Run:

```bash
dart run example/invoke.dart
dart run example/load_various_wasm.dart
dart run example/load_from_file.dart ./path/to/module.wasm exported_fn 1 2
dart run example/load_wasm_suite.dart ./path/to/wasm_dir
dart run example/wasi_hello.dart
dart run example/wasi_write_file.dart
dart run example/wasi_seek_stat.dart
dart run example/wasi_runner.dart
example/doom/setup_assets.sh
dart run example/run_doom_wasm.dart
dart run example/play_doom_terminal.dart
```

Doom quick run (headless, 120 frames, dump first frame as PPM):

```bash
example/doom/setup_assets.sh
dart run example/run_doom_wasm.dart example/doom/doom.wasm example/doom/doom1.wad 120 example/doom/frame_0001.ppm
```

Doom terminal playable mode (interactive):

```bash
example/doom/setup_assets.sh
dart run example/play_doom_terminal.dart
```

If your terminal shows a black screen, use monochrome fallback:

```bash
dart run example/play_doom_terminal.dart --mono
```

Doom desktop window mode (Flutter):

```bash
cd doom_window
tool/sync_assets.sh
flutter pub get
flutter run -d macos
```

On Linux/Windows, replace `-d macos` with your desktop target.
`doom_window` now loads `doom.wasm` + `doom1.wad` from Flutter assets
(`doom_window/assets/doom/*`) instead of external filesystem paths.
Controls in window mode: arrows/WASD move, `Ctrl` (and `Space`) fire, `Alt`
strafe, `Shift` run, `Enter` use, `Esc` menu.

## Conformance Tooling

The repository includes a first-pass conformance runner and pinned toolchain
bootstrap scripts:

```bash
tool/ensure_toolchains.sh
git clone --depth 1 https://github.com/WebAssembly/testsuite.git third_party/wasm-spec-tests
dart run tool/spec_runner.dart --target=vm --suite=all
dart run tool/spec_runner.dart --target=js --suite=all
dart run tool/spec_runner.dart --target=wasm --suite=all
# core-only run
dart run tool/spec_runner.dart --target=vm --suite=core
# proposal-only run (non-gating by default)
dart run tool/spec_runner.dart --target=vm --suite=proposal
```

Artifacts:

- Markdown report: `.dart_tool/spec_runner/wasm_conformance_matrix.md`
- JSON report: `.dart_tool/spec_runner/latest.json`
- Core failure board: `.dart_tool/spec_runner/wasm_core_failures.md`
- Core JSON report: `.dart_tool/spec_runner/core_latest.json`
- Proposal failure board: `.dart_tool/spec_runner/wasm_proposal_failures.md`
- Proposal JSON report: `.dart_tool/spec_runner/proposal_latest.json`
- Spec update tracker: `dart run tool/spec_sync.dart`

## zwasm WAT samples

Copied from `zwasm/examples/wat` into:

- [example/wat](example/wat)

These are source `.wat` samples for reference and conversion workflows.

## Why WASD

No FFI, no native code, and no runtime-specific APIs. This keeps the runtime
portable across all Dart compile targets.
