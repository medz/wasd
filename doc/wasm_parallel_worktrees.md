# WASM Parallel Worktrees

This repo now has three dedicated worktrees for parallel WASM delivery lanes:

- `/Users/seven/workspace/wasd-wt-core-runtime` (`parallel-core-runtime`)
- `/Users/seven/workspace/wasd-wt-simd-eh` (`parallel-simd-eh`)
- `/Users/seven/workspace/wasd-wt-gc-component` (`parallel-gc-component`)

## Lane ownership

- `parallel-core-runtime`: runtime core, validator/predecode boundaries, conformance harness.
- `parallel-simd-eh`: SIMD + EH proposal implementation and testsuite closure.
- `parallel-gc-component`: GC + component model pipeline and ABI semantics.

## Parallel conformance run

Run all three targets in parallel from the main workspace:

```bash
bash tool/parallel_worktree_matrix.sh
```

Logs are written to:

- `.dart_tool/parallel_matrix/vm_all.log`
- `.dart_tool/parallel_matrix/js_all.log`
- `.dart_tool/parallel_matrix/wasm_all.log`

Each lane runs:

```bash
dart run tool/spec_runner.dart --target=<vm|js|wasm> --suite=all --strict-proposals
```

## Merge strategy

1. Keep each lane rebased on `main`.
2. Land lane PRs in this order:
   1. `parallel-core-runtime`
   2. `parallel-simd-eh`
   3. `parallel-gc-component`
3. After each merge, re-run `bash tool/parallel_worktree_matrix.sh`.
