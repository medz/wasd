# WASM Conformance Matrix

- Started at (UTC): `2026-02-25T04:03:52.342684Z`
- Ended at (UTC): `2026-02-25T04:03:54.740024Z`
- Target: `vm`
- Suite: `proposal`
- Status: `passed`

## Step Results

| Step | Status | Duration (ms) | Command |
| --- | --- | ---: | --- |
| toolchain-check | passed | 23 | `bash tool/ensure_toolchains.sh --check` |
| analyze | passed | 509 | `dart analyze lib test tool example` |
| proposal-testsuite | optional-failed | 676 | `dart run tool/spec_testsuite_runner.dart --suite=proposal --testsuite-dir=third_party/wasm-spec-tests` |
| spec-sync-check | passed | 1186 | `dart run tool/spec_sync.dart` |

## Notes

- Proposal testsuite summary is written to `doc/wasm_proposal_failures.md`.
- Proposal failures are non-gating by default; pass `--strict-proposals` to enforce them.
- Raw run payload is written to `.dart_tool/spec_runner/latest.json`.
