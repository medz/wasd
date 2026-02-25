# WASM Conformance Matrix

- Started at (UTC): `2026-02-25T02:55:48.738247Z`
- Ended at (UTC): `2026-02-25T02:55:51.261479Z`
- Target: `vm`
- Suite: `proposal`
- Status: `passed`

## Step Results

| Step | Status | Duration (ms) | Command |
| --- | --- | ---: | --- |
| toolchain-check | passed | 33 | `bash tool/ensure_toolchains.sh --check` |
| analyze | passed | 520 | `dart analyze lib test tool example` |
| proposal-testsuite | optional-failed | 610 | `dart run tool/spec_testsuite_runner.dart --suite=proposal` |
| spec-sync-check | passed | 1357 | `dart run tool/spec_sync.dart` |

## Notes

- Proposal testsuite summary is written to `doc/wasm_proposal_failures.md`.
- Proposal failures are non-gating by default; pass `--strict-proposals` to enforce them.
- Raw run payload is written to `.dart_tool/spec_runner/latest.json`.
