# Wasm Core Completion Matrix

This file defines "complete" for this project as a **Wasm Core interpreter** (binary format + runtime semantics) with bulk-memory and reference-table essentials.

## Scope Included In "Complete"

- Core module decoding:
  - type/import/function/table/memory/global/export/start/element/code/data/data_count
- Runtime core semantics:
  - instantiation, start, exports, globals, table/memory initialization
  - control flow, calls, call_indirect
- Numeric execution:
  - i32/i64/f32/f64 arithmetic, compare, bit ops
  - conversion/reinterpret/sign-extension/trunc-sat
- Memory/table operations:
  - full MVP load/store family
  - memory/table bulk operations (`memory.copy/fill/init`, `table.copy/fill/init`, drop ops)
- Multi-value function/block support
- Host imports for function/table/memory/global

## Out Of Scope (tracked separately)

- SIMD
- Threads/atomics/shared memory
- Exception handling
- GC/reference subtyping beyond baseline ref ops
- Component Model
- Full WASI API surface (phase-2 currently implements baseline Preview1 adapters only)

## Current Status

- Implemented in runtime:
  - bulk-memory/table prefixed instructions
  - full MVP load/store variants
  - conversion/sign-extension/reinterpret/trunc-sat families
  - table instruction family (`get/set/init/copy/grow/size/fill`)
  - tail-call opcodes (`return_call`, `return_call_indirect`)
- Decoder compatibility improvements:
  - `data_count` section support
  - custom section skipping
- Remaining technical debt:
  - static validation phase exists (`WasmValidator`) but is still a pragmatic subset of full spec validation
  - WASI coverage is partial (`fd_write/fd_read/fd_pread/fd_pwrite/fd_seek/fd_tell/fd_advise/fd_allocate/fd_datasync/fd_sync/fd_filestat_get/fd_filestat_set_size/fd_filestat_set_times/fd_fdstat_get/fd_fdstat_set_flags/fd_fdstat_set_rights/fd_prestat_get/fd_prestat_dir_name/fd_readdir/fd_renumber/fd_close/path_open/path_filestat_get/path_filestat_set_times/path_link/path_symlink/path_readlink/path_rename/path_unlink_file/path_create_directory/path_remove_directory/args_sizes_get/args_get/environ_sizes_get/environ_get/clock_time_get/clock_res_get/random_get/poll_oneoff/sched_yield/proc_raise/proc_exit/sock_accept/sock_recv/sock_send/sock_shutdown`), not full preview1
  - proposal execution semantics for SIMD/threads/EH/GC/component are still unimplemented (feature-gated)
  - host-io backend now enforces canonical root boundary checks; policy model can still be hardened further

## Acceptance Criteria

- Unit tests cover each major opcode family listed above
- Example scripts exercise multi-type modules and file-loaded wasm
- `dart test` and `dart analyze` are clean
