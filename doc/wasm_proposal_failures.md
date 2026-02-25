# WASM Proposal Failure Board

- Started at (UTC): `2026-02-25T02:55:49.592727Z`
- Ended at (UTC): `2026-02-25T02:55:49.861873Z`
- Suite: `proposal`
- Testsuite dir: `/Users/seven/workspace/wasd/third_party/wasm-spec-tests`
- Testsuite revision: `c337f0d`
- wast2json: `/Users/seven/workspace/wasd/.toolchains/bin/wast2json`

## Totals

- Files: 23
- Passed files: 4
- Failed files: 19
- Commands seen: 427
- Commands passed: 398
- Commands failed: 19
- Commands skipped: 25

## Groups

| Group | Files | Passed | Failed |
| --- | ---: | ---: | ---: |
| custom-descriptors | 14 | 0 | 14 |
| custom-page-sizes | 4 | 1 | 3 |
| threads | 4 | 3 | 1 |
| wide-arithmetic | 1 | 0 | 1 |

## Top Failure Reasons

| Reason | Count |
| --- | ---: |
| wast2json-failed | 15 |
| unhandled-exception | 3 |
| assert-module-unexpected-success | 1 |

## Failed Files

| Group | File | Line | Reason | Details |
| --- | --- | ---: | --- | --- |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/array_new_exact.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/array_new_exact.wast:2:20: error: unexpected token "i8", expected i32, i64, f32, f64, v128, externref, exnref or funcref.<br>  (type $a1 (array i8))<br>      ... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/binary-descriptors.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/binary-descriptors.wast:2:2: error: error in binary module: @0x0000000c: unexpected type form (got -0x32)<br>(module binary<br> ^^^^^^<br>/Users/seven/workspace/... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/binary.wast` | 612 | assert-module-unexpected-success | {type: assert_malformed, line: 612, filename: script.76.wasm, text: malformed limits flags, module_type: binary} |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast.wast:5:28: error: unexpected token "i16", expected i32, i64, f32, f64, v128, externref, exnref or funcref.<br>  (type $st (struct (field i16)))<br>... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>/Users/seven/workspace/wasd/third_party/wasm-spec-tes... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq_fail.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq_fail.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>/Users/seven/workspace/wasd/third_party/wasm-spe... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_fail.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_fail.wast:5:28: error: unexpected token "i16", expected i32, i64, f32, f64, v128, externref, exnref or funcref.<br>  (type $st (struct (field i1... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/descriptors.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/descriptors.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>/Users/seven/workspace/wasd/third_party/wasm-spec-tests/prop... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/exact-casts.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/exact-casts.wast:5:17: error: unexpected token "sub", expected func, struct or array.<br>  (type $super (sub (struct)))<br>                ^^^<br>/Users/seven/wo... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/exact-func-import.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/exact-func-import.wast:1:9: error: unexpected token "definition", expected a module field.<br>(module definition<br>        ^^^^^^^^^^ |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/exact.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/exact.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/ref_cast_desc_eq.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/ref_cast_desc_eq.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>/Users/seven/workspace/wasd/third_party/wasm-spec-tests... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/ref_get_desc.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/ref_get_desc.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>/Users/seven/workspace/wasd/third_party/wasm-spec-tests/pro... |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/struct_new_desc.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/struct_new_desc.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>/Users/seven/workspace/wasd/third_party/wasm-spec-tests/... |
| custom-page-sizes | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-page-sizes/custom-page-sizes-invalid.wast` | 97 | unhandled-exception | Unsupported operation: This runtime currently supports at most one linear memory. |
| custom-page-sizes | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-page-sizes/custom-page-sizes.wast` | 2 | unhandled-exception | Unsupported operation: defined memory uses custom page size log2=0, but only 64KiB pages (log2=16) are supported. |
| custom-page-sizes | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-page-sizes/memory_max.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-page-sizes/memory_max.wast:36:13: error: invalid int "0x1_0000_0000"<br>    (memory 0x1_0000_0000 (pagesize 1)))<br>            ^^^^^^^^^^^^^ |
| threads | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/threads/atomic.wast` | 3 | unhandled-exception | Unsupported operation: Threads feature gate is enabled, but atomics execution is not implemented yet. |
| wide-arithmetic | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/wide-arithmetic/wide-arithmetic.wast` | 0 | wast2json-failed | /Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/wide-arithmetic/wide-arithmetic.wast:7:5: error: unexpected token i64.add128, expected ).<br>    i64.add128)<br>    ^^^^^^^^^^<br>/Users/seven/workspace/wasd/third_party/wasm-spec-... |
