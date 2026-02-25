# WASM Proposal Failure Board

- Started at (UTC): `2026-02-25T11:31:52.702Z`
- Ended at (UTC): `2026-02-25T11:31:52.839Z`
- Suite: `proposal`
- Testsuite dir: `/Users/seven/workspace/wasd/third_party/wasm-spec-tests`
- Testsuite revision: `c337f0d`
- Wast converter: `wasm-tools json-from-wast` (`/Users/seven/workspace/wasd/.toolchains/bin/wasm-tools`)

## Totals

- Files: 23
- Passed files: 20
- Failed files: 3
- Commands seen: 1335
- Commands passed: 1290
- Commands failed: 3
- Commands skipped: 42

## Groups

| Group | Files | Passed | Failed |
| --- | ---: | ---: | ---: |
| custom-descriptors | 14 | 14 | 0 |
| custom-page-sizes | 4 | 4 | 0 |
| threads | 4 | 2 | 2 |
| wide-arithmetic | 1 | 0 | 1 |

## Top Failure Reasons

| Reason | Count |
| --- | ---: |
| assert-return-mismatch | 3 |

## Failed Files

| Group | File | Line | Reason | Details |
| --- | --- | ---: | --- | --- |
| threads | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/threads/atomic.wast` | 134 | assert-return-mismatch | index=0 expected=i32(286331153) actual=286331136 |
| threads | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/threads/memory.wast` | 220 | assert-return-mismatch | index=0 expected=i64(67) actual=64 |
| wide-arithmetic | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/wide-arithmetic/wide-arithmetic.wast` | 168 | assert-return-mismatch | index=1 expected=i64(-164735366972792420) actual=-164735366972792320 |
