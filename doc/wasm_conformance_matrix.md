# WASM Conformance Matrix

- Started at (UTC): `2026-02-25T12:06:20.486294Z`
- Ended at (UTC): `2026-02-25T12:06:23.253960Z`
- Target: `vm`
- Suite: `proposal`
- Status: `passed`

## Step Results

| Step | Status | Duration (ms) | Command |
| --- | --- | ---: | --- |
| toolchain-check | passed | 28 | `bash tool/ensure_toolchains.sh --check` |
| analyze | passed | 544 | `dart analyze lib test tool example` |
| proposal-testsuite | passed | 960 | `dart run tool/spec_testsuite_runner.dart --suite=proposal --output-json=.dart_tool/spec_runner/proposal_latest.json --output-md=doc/wasm_proposal_failures.md` |
| spec-sync-check | passed | 1231 | `dart run tool/spec_sync.dart` |

## Notes

- Proposal testsuite summary is written to `doc/wasm_proposal_failures.md`.
- Raw run payload is written to `.dart_tool/spec_runner/latest.json`.
