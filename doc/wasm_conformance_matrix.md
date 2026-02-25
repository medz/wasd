# WASM Conformance Matrix

- Started at (UTC): `2026-02-25T13:22:35.420156Z`
- Ended at (UTC): `2026-02-25T13:22:43.074860Z`
- Target: `wasm`
- Suite: `proposal`
- Status: `passed`

## Step Results

| Step | Status | Duration (ms) | Command |
| --- | --- | ---: | --- |
| toolchain-check | passed | 32 | `bash tool/ensure_toolchains.sh --check` |
| analyze | passed | 594 | `dart analyze lib test tool example` |
| node-check | passed | 21 | `node --version` |
| wasm-threads-portable-compile | passed | 2317 | `dart compile wasm tool/threads_portable_check.dart -o .dart_tool/spec_runner/threads_portable_check.wasm` |
| wasm-threads-portable-run | passed | 60 | `node tool/run_wasm_main.mjs .dart_tool/spec_runner/threads_portable_check.mjs .dart_tool/spec_runner/threads_portable_check.wasm` |
| proposal-prepare-manifest | passed | 619 | `dart run tool/spec_testsuite_runner.dart --suite=proposal --prepare-manifest=.dart_tool/spec_runner/proposal_manifest.json --prepare-root=.dart_tool/spec_runner/proposal_bundle` |
| proposal-player-wasm-compile | passed | 2412 | `dart compile wasm tool/spec_testsuite_player.dart -o .dart_tool/spec_runner/spec_testsuite_player.wasm` |
| proposal-player-wasm-run | passed | 131 | `node tool/run_spec_player_wasm.mjs .dart_tool/spec_runner/spec_testsuite_player.mjs .dart_tool/spec_runner/spec_testsuite_player.wasm .dart_tool/spec_runner/proposal_manifest.json .dart_tool/spec_runner/proposal_latest.json` |
| proposal-report | passed | 224 | `dart run tool/spec_result_report.dart --input-json=.dart_tool/spec_runner/proposal_latest.json --output-md=doc/wasm_proposal_failures.md` |
| spec-sync-check | passed | 1237 | `dart run tool/spec_sync.dart` |

## Notes

- Proposal testsuite summary is written to `doc/wasm_proposal_failures.md`.
- Raw run payload is written to `.dart_tool/spec_runner/latest.json`.
