# WASM Conformance Matrix

- Started at (UTC): `2026-02-25T11:31:46.267105Z`
- Ended at (UTC): `2026-02-25T11:31:54.244858Z`
- Target: `js`
- Suite: `proposal`
- Status: `failed`

## Step Results

| Step | Status | Duration (ms) | Command |
| --- | --- | ---: | --- |
| toolchain-check | passed | 29 | `bash tool/ensure_toolchains.sh --check` |
| analyze | passed | 555 | `dart analyze lib test tool example` |
| node-check | passed | 19 | `node --version` |
| js-threads-portable | passed | 3299 | `dart test -p node test/threads_portable_test.dart` |
| proposal-prepare-manifest | passed | 677 | `dart run tool/spec_testsuite_runner.dart --suite=proposal --prepare-manifest=.dart_tool/spec_runner/proposal_manifest.json --prepare-root=.dart_tool/spec_runner/proposal_bundle` |
| proposal-player-js-compile | passed | 1748 | `dart compile js tool/spec_testsuite_player.dart -o .dart_tool/spec_runner/spec_testsuite_player.js` |
| proposal-player-js-run | failed | 249 | `node tool/run_spec_player_js.mjs .dart_tool/spec_runner/spec_testsuite_player.js .dart_tool/spec_runner/proposal_manifest.json .dart_tool/spec_runner/proposal_latest.json` |
| proposal-report | passed | 229 | `dart run tool/spec_result_report.dart --input-json=.dart_tool/spec_runner/proposal_latest.json --output-md=doc/wasm_proposal_failures.md` |
| spec-sync-check | passed | 1167 | `dart run tool/spec_sync.dart` |

## Notes

- Proposal testsuite summary is written to `doc/wasm_proposal_failures.md`.
- Raw run payload is written to `.dart_tool/spec_runner/latest.json`.
