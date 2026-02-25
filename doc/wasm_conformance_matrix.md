# WASM Conformance Matrix

- Started at (UTC): `2026-02-25T02:00:58.516695Z`
- Ended at (UTC): `2026-02-25T02:02:30.224583Z`
- Target: `js`
- Suite: `all`
- Status: `passed`

## Step Results

| Step | Status | Duration (ms) | Command |
| --- | --- | ---: | --- |
| toolchain-check | passed | 21 | `bash tool/ensure_toolchains.sh --check` |
| analyze | passed | 509 | `dart analyze lib test tool example` |
| node-check | passed | 17 | `node --version` |
| js-tests | passed | 2955 | `dart test -p node` |
| proposal-testsuite | optional-failed | 86894 | `dart run tool/spec_testsuite_runner.dart --suite=proposal` |
| spec-sync-check | passed | 1307 | `dart run tool/spec_sync.dart` |

## Notes

- Proposal testsuite summary is written to `doc/wasm_proposal_failures.md`.
- Proposal failures are non-gating by default; pass `--strict-proposals` to enforce them.
- Raw run payload is written to `.dart_tool/spec_runner/latest.json`.
