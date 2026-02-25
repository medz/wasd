# WASM Core Failure Board

- Started at (UTC): `2026-02-25T12:59:45.092004Z`
- Ended at (UTC): `2026-02-25T12:59:45.439651Z`
- Suite: `core`
- Testsuite dir: `/Users/seven/workspace/wasd/third_party/wasm-spec-tests`
- Testsuite revision: `c337f0d`
- Wast converter: `wasm-tools json-from-wast` (`/Users/seven/workspace/wasd/.toolchains/bin/wasm-tools`)

## Totals

- Files: 20
- Passed files: 7
- Failed files: 13
- Commands seen: 860
- Commands passed: 791
- Commands failed: 13
- Commands skipped: 56

## Groups

| Group | Files | Passed | Failed |
| --- | ---: | ---: | ---: |
| core | 20 | 7 | 13 |

## Top Failure Reasons

| Reason | Count |
| --- | ---: |
| unhandled-exception | 10 |
| assert-module-unexpected-success | 3 |

## Failed Files

| Group | File | Line | Reason | Details |
| --- | --- | ---: | --- | --- |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/address64.wast` | 3 | unhandled-exception | FormatException: Validation failed: data offset expr must produce i32, got WasmValueType.i64. |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/align.wast` | 949 | assert-module-unexpected-success | {type: assert_invalid, line: 949, filename: align.112.wasm, module_type: binary, text: type mismatch} |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/align64.wast` | 3 | unhandled-exception | Unsupported operation: defined memory requires memory64, which is not yet supported. |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/annotations.wast` | 32 | unhandled-exception | FormatException: Invalid Wasm magic number. |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array.wast` | 28 | assert-module-unexpected-success | {type: assert_invalid, line: 28, filename: array.1.wasm, module_type: binary, text: unknown type} |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_copy.wast` | 54 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x11 |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_fill.wast` | 38 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x10 |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_init_data.wast` | 31 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x12 |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_init_elem.wast` | 44 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0xb |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_new_data.wast` | 12 | unhandled-exception | Unsupported operation: Unsupported opcode: 0xfb09 |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_new_elem.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported element init expr opcode: 0x41 |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/binary-leb128.wast` | 483 | assert-module-unexpected-success | {type: assert_malformed, line: 483, filename: binary-leb128.44.wasm, module_type: binary, text: integer representation too long} |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/binary_leb128_64.wast` | 1 | unhandled-exception | Unsupported operation: defined memory requires memory64, which is not yet supported. |
