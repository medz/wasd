# WASM Proposal Failure Board

- Started at (UTC): `2026-02-25T04:36:14.994577Z`
- Ended at (UTC): `2026-02-25T04:36:15.328081Z`
- Suite: `proposal`
- Testsuite dir: `/Users/seven/workspace/wasd/third_party/wasm-spec-tests`
- Testsuite revision: `c337f0d`
- Wast converter: `wasm-tools json-from-wast` (`/Users/seven/workspace/wasd/.toolchains/bin/wasm-tools`)

## Totals

- Files: 23
- Passed files: 11
- Failed files: 12
- Commands seen: 992
- Commands passed: 948
- Commands failed: 12
- Commands skipped: 32

## Groups

| Group | Files | Passed | Failed |
| --- | ---: | ---: | ---: |
| custom-descriptors | 14 | 2 | 12 |
| custom-page-sizes | 4 | 4 | 0 |
| threads | 4 | 4 | 0 |
| wide-arithmetic | 1 | 1 | 0 |

## Top Failure Reasons

| Reason | Count |
| --- | ---: |
| unhandled-exception | 10 |
| assert-module-unexpected-success | 2 |

## Failed Files

| Group | File | Line | Reason | Details |
| --- | --- | ---: | --- | --- |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/array_new_exact.wast` | 1 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x6 |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/binary-descriptors.wast` | 92 | assert-module-unexpected-success | {type: assert_malformed, line: 92, filename: binary-descriptors.4.wasm, module_type: binary, text: malformed definition type} |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x1c |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x25 |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_desc_eq_fail.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x26 |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/br_on_cast_fail.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x1c |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/descriptors.wast` | 118 | assert-module-unexpected-success | {type: assert_invalid, line: 118, filename: descriptors.10.wasm, module_type: binary, text: type is not described by its descriptor} |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/exact-casts.wast` | 4 | unhandled-exception | Unsupported operation: Unsupported init expression opcode: 0xfb |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/exact.wast` | 3 | unhandled-exception | Unsupported operation: Validation failed: unsupported const expr opcode 0x0 |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/ref_cast_desc_eq.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x24 |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/ref_get_desc.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x22 |
| custom-descriptors | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/proposals/custom-descriptors/struct_new_desc.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x20 |
