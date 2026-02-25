# WASM Proposal Failure Board

- Started at (UTC): `2026-02-25T04:03:53.149670Z`
- Ended at (UTC): `2026-02-25T04:03:53.468678Z`
- Suite: `proposal`
- Testsuite dir: `third_party/wasm-spec-tests`
- Testsuite revision: `c337f0d`
- Wast converter: `wasm-tools json-from-wast` (`/Users/seven/workspace/wasd/.toolchains/bin/wasm-tools`)

## Totals

- Files: 23
- Passed files: 10
- Failed files: 13
- Commands seen: 954
- Commands passed: 913
- Commands failed: 13
- Commands skipped: 28

## Groups

| Group | Files | Passed | Failed |
| --- | ---: | ---: | ---: |
| custom-descriptors | 14 | 1 | 13 |
| custom-page-sizes | 4 | 4 | 0 |
| threads | 4 | 4 | 0 |
| wide-arithmetic | 1 | 1 | 0 |

## Top Failure Reasons

| Reason | Count |
| --- | ---: |
| unhandled-exception | 13 |

## Failed Files

| Group | File | Line | Reason | Details |
| --- | --- | ---: | --- | --- |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/array_new_exact.wast` | 1 | unhandled-exception | Unsupported operation: Unsupported type form: 0x5e |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/binary-descriptors.wast` | 2 | unhandled-exception | Unsupported operation: Unsupported type form: 0x4e |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported type form: 0x5f |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported type form: 0x4e |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq_fail.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported type form: 0x4e |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_fail.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported type form: 0x5f |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/descriptors.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported type form: 0x4e |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/exact-casts.wast` | 4 | unhandled-exception | Unsupported operation: Unsupported type form: 0x50 |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/exact-func-import.wast` | 76 | unhandled-exception | Unsupported operation: Unsupported import kind: 0x20 |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/exact.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported type form: 0x4e |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/ref_cast_desc_eq.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported type form: 0x4e |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/ref_get_desc.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported type form: 0x4e |
| custom-descriptors | `third_party/wasm-spec-tests/proposals/custom-descriptors/struct_new_desc.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported type form: 0x4e |
