# WASM Conformance Matrix

- Started at (UTC): `2026-02-25T14:06:18.047799Z`
- Ended at (UTC): `2026-02-25T14:06:20.980370Z`
- Target: `vm`
- Suite: `proposal`
- Status: `passed`

## Step Results

| Step | Status | Duration (ms) | Command |
| --- | --- | ---: | --- |
| toolchain-check | passed | 29 | `bash tool/ensure_toolchains.sh --check` |
| analyze | passed | 548 | `dart analyze lib test tool example` |
| proposal-testsuite | passed | 1064 | `dart run tool/spec_testsuite_runner.dart --suite=proposal --output-json=.dart_tool/spec_runner/proposal_latest.json --output-md=doc/wasm_proposal_failures.md` |
| spec-sync-check | passed | 1288 | `dart run tool/spec_sync.dart` |

## Notes

- Proposal testsuite summary is written to `doc/wasm_proposal_failures.md`.
- Raw run payload is written to `.dart_tool/spec_runner/latest.json`.
