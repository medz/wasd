# WASM Core Failure Board

- Started at (UTC): `2026-02-25T13:20:22.148660Z`
- Ended at (UTC): `2026-02-25T13:20:22.557336Z`
- Suite: `core`
- Testsuite dir: `/Users/seven/workspace/wasd/third_party/wasm-spec-tests`
- Testsuite revision: `c337f0d`
- Wast converter: `wasm-tools json-from-wast` (`/Users/seven/workspace/wasd/.toolchains/bin/wasm-tools`)

## Totals

- Files: 20
- Passed files: 12
- Failed files: 8
- Commands seen: 1308
- Commands passed: 1198
- Commands failed: 8
- Commands skipped: 102

## Groups

| Group | Files | Passed | Failed |
| --- | ---: | ---: | ---: |
| core | 20 | 12 | 8 |

## Top Failure Reasons

| Reason | Count |
| --- | ---: |
| unhandled-exception | 7 |
| assert-module-unexpected-success | 1 |

## Failed Files

| Group | File | Line | Reason | Details |
| --- | --- | ---: | --- | --- |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/annotations.wast` | 32 | unhandled-exception | FormatException: Invalid Wasm magic number. |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array.wast` | 28 | assert-module-unexpected-success | {type: assert_invalid, line: 28, filename: array.1.wasm, module_type: binary, text: unknown type} |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_copy.wast` | 54 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x11 |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_fill.wast` | 38 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x10 |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_init_data.wast` | 31 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0x12 |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_init_elem.wast` | 44 | unhandled-exception | Unsupported operation: Unsupported 0xFB sub-opcode: 0xb |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_new_data.wast` | 12 | unhandled-exception | Unsupported operation: Unsupported opcode: 0xfb09 |
| core | `/Users/seven/workspace/wasd/third_party/wasm-spec-tests/array_new_elem.wast` | 3 | unhandled-exception | Unsupported operation: Unsupported element init expr opcode: 0x41 |
