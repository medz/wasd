# WASM Conformance Matrix

- Started at (UTC): `2026-02-25T01:46:51.087142Z`
- Ended at (UTC): `2026-02-25T01:46:54.808010Z`
- Target: `js`
- Suite: `all`
- Status: `passed`

## Step Results

| Step | Status | Duration (ms) | Command |
| --- | --- | ---: | --- |
| toolchain-check | passed | 24 | `bash tool/ensure_toolchains.sh --check` |
| analyze | passed | 529 | `dart analyze lib test tool example` |
| node-check | passed | 18 | `node --version` |
| js-tests | passed | 2962 | `dart test -p node` |
| spec-sync-check | passed | 183 | `dart run tool/spec_sync.dart` |

## Notes

- `proposal` and `all` currently share the same local regression flow while official proposal testsuite wiring is being expanded.
- Raw run payload is written to `.dart_tool/spec_runner/latest.json`.
