# WASM Proposal Failure Board

- Started at (UTC): `2026-02-25T03:45:46.081513Z`
- Ended at (UTC): `2026-02-25T03:45:46.370738Z`
- Suite: `proposal`
- Testsuite dir: `third_party/wasm-spec-tests`
- Testsuite revision: `c337f0d`
- wast2json: `/Users/seven/workspace/wasd/.toolchains/bin/wast2json`

## Totals

- Files: 23
- Passed files: 8
- Failed files: 15
- Commands seen: 818
- Commands passed: 792
- Commands failed: 15
- Commands skipped: 26

## Groups

| Group | Files | Passed | Failed |
| --- | ---: | ---: | ---: |
| custom-descriptors | 14 | 1 | 13 |
| custom-page-sizes | 4 | 3 | 1 |
| threads | 4 | 4 | 0 |
| wide-arithmetic | 1 | 0 | 1 |

## Top Failure Reasons

| Reason | Count |
| --- | ---: |
| wast2json-failed | 15 |

## Failed Files

| Group | File | Line | Reason | Details |
| --- | --- | ---: | --- | --- |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/array_new_exact.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/array_new_exact.wast:2:20: error: unexpected token "i8", expected i32, i64, f32, f64, v128, externref, exnref or funcref.<br>  (type $a1 (array i8))<br>                   ^^<br>third_party/... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/binary-descriptors.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/binary-descriptors.wast:2:2: error: error in binary module: @0x0000000c: unexpected type form (got -0x32)<br>(module binary<br> ^^^^^^<br>third_party/wasm-spec-tests/proposals/custom-descri... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast.wast:5:28: error: unexpected token "i16", expected i32, i64, f32, f64, v128, externref, exnref or funcref.<br>  (type $st (struct (field i16)))<br>                           ^... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq.wast:... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq_fail.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq_fail.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq_... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_fail.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_fail.wast:5:28: error: unexpected token "i16", expected i32, i64, f32, f64, v128, externref, exnref or funcref.<br>  (type $st (struct (field i16)))<br>                       ... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/descriptors.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/descriptors.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>third_party/wasm-spec-tests/proposals/custom-descriptors/descriptors.wast:5:12: error: u... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/exact-casts.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/exact-casts.wast:5:17: error: unexpected token "sub", expected func, struct or array.<br>  (type $super (sub (struct)))<br>                ^^^<br>third_party/wasm-spec-tests/proposals/custo... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/exact-func-import.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/exact-func-import.wast:1:9: error: unexpected token "definition", expected a module field.<br>(module definition<br>        ^^^^^^^^^^ |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/exact.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/exact.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>third_party/wasm-spec-tests/proposals/custom-descriptors/exact.wast:5:39: error: unexpected to... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/ref_cast_desc_eq.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/ref_cast_desc_eq.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>third_party/wasm-spec-tests/proposals/custom-descriptors/ref_cast_desc_eq.wast:5:15... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/ref_get_desc.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/ref_get_desc.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>third_party/wasm-spec-tests/proposals/custom-descriptors/ref_get_desc.wast:5:15: error:... |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/struct_new_desc.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-descriptors/struct_new_desc.wast:4:4: error: unexpected token "rec", expected a module field.<br>  (rec<br>   ^^^<br>third_party/wasm-spec-tests/proposals/custom-descriptors/struct_new_desc.wast:5:19: ... |
| custom-page-sizes | `third_party/wasm-spec-tests/proposals/custom-page-sizes/memory_max.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/custom-page-sizes/memory_max.wast:36:13: error: invalid int "0x1_0000_0000"<br>    (memory 0x1_0000_0000 (pagesize 1)))<br>            ^^^^^^^^^^^^^ |
| wide-arithmetic | `third_party/wasm-spec-tests/proposals/wide-arithmetic/wide-arithmetic.wast` | 0 | wast2json-failed | third_party/wasm-spec-tests/proposals/wide-arithmetic/wide-arithmetic.wast:7:5: error: unexpected token i64.add128, expected ).<br>    i64.add128)<br>    ^^^^^^^^^^<br>third_party/wasm-spec-tests/proposals/wide-arithmetic/wide-arithmetic.wast:13:... |
