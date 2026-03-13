# Agent Guidelines

## Project Layout

`lib/` contains the public package entrypoints: `wasd.dart`, `wasm.dart`, and `wasi.dart`. Prefer keeping new API surface small and routing implementation details through `lib/src/`.

Key implementation areas:

- `lib/src/wasm/`: core Wasm parsing, instantiation, backends, and runtime support.
- `lib/src/wasi/`: WASI host implementations and compatibility layers.
- `lib/src/wasi/preview1/native/`: Dart VM and native Preview1 host behavior.
- `lib/src/wasi/preview1/js/web/`: browser Preview1 host shim.
- `lib/src/wasi/preview1/js/node/`: Node Preview1 bridge backed by `node:wasi`.
- `test/`: unit, regression, README, runtime, and smoke tests.
- `test/support/`: shared helpers and runtime detection.
- `test/fixtures/`: checked-in binary fixtures.
- `tool/`: conformance runners, fixture setup, and local maintenance scripts.
- `example/`: runnable examples, including `example/doom/` for the Flutter demo.

Avoid broad edits in `third_party/` unless the task explicitly updates vendored upstream material.

## WASI-Specific Expectations

This repository currently exposes a limited WASI Preview1 implementation. Do not assume full Preview1 coverage, and do not imply Preview2 or Preview3 support in code or docs unless the repository actually implements it.

Current runtime split matters:

- `native` and `js/web` implement the in-repo Preview1 host surface.
- `js/node` delegates Preview1 behavior to `node:wasi`.
- Browser and native behavior are intended to stay aligned for the supported Preview1 subset.

When changing WASI behavior:

- update the targeted regression tests in `test/wasi_test.dart`;
- keep README support claims aligned with actual runtime behavior;
- verify the relevant runtime paths, not just the default Dart VM path.

## Build, Test, and Verification Commands

Run commands from the repository root.

Baseline:

- `dart pub get`: install dependencies.
- `dart analyze`: run the configured analyzer and lints.
- `dart test`: run the full default test suite.
- `dart format .`: apply canonical Dart formatting.

Fast targeted checks:

- `dart test test/wasi_test.dart test/wasm_test.dart`: fast verification for core runtime changes.
- `dart test -p chrome test/wasi_test.dart`: required when touching `lib/src/wasi/preview1/js/web/` or shared JS/browser behavior.
- `dart test -p node test/wasi_test.dart`: useful when touching `lib/src/wasi/preview1/js/node/` or Node-specific integration.
- `dart run example/wasm_cli.dart 3 9`: quick CLI smoke test.

Fixtures and toolchains:

- `tool/setup_test_fixtures.sh --doom-only`: fetch DOOM fixtures for smoke tests.
- `tool/ensure_toolchains.sh --check`: verify pinned WABT and `wasm-tools` under `.toolchains/`.

Slower runtime checks:

- `dart test test/doom_smoke_test.dart`
- `dart test test/doom_e2e_node_test.dart`
- `dart test test/doom_render_smoke_test.dart`

Use the smallest verification set that matches the change, but do not skip browser checks for browser code or README checks for README-facing API changes.

## Change Workflow

Choose the workflow by change type instead of applying one process to every edit.

Default workflow for behavior changes:
Use this for feature work, bug fixes, runtime behavior changes, parser changes, host behavior changes, and test-logic changes.

1. Collect the relevant code and spec context first.
2. Write or update the regression/spec tests before the implementation.
3. Run the targeted tests and confirm they fail for the expected reason before the fix.
4. Implement the change.
5. Re-run the targeted tests and confirm they pass.
6. Run any broader verification needed for the affected runtimes.
7. Run `dart format .`.
8. Run `dart analyze`.
9. Commit the change. Split formatting-only follow-up into a separate commit when that improves review clarity.
10. Create a PR and use `Resolves #<id>` when the PR closes an issue.

Lightweight workflow for documentation-only changes:
Use this for prose-only docs that do not change executable examples, commands, or behavior claims.

- No test-first or red-to-green requirement.
- No analyzer requirement by default.
- If the doc changes README snippets, commands, or behavior guarantees, run the relevant README or behavior tests.

Lightweight workflow for comment-only changes:
Use this for code comments and doc comments when runtime behavior is unchanged.

- No test-first or red-to-green requirement.
- Run `dart format .` on the repository after the edit.
- If the comment changes public API documentation, examples, or behavior descriptions that are tightly coupled to tests, run the smallest relevant test set as well.

Lightweight workflow for formatting-only changes:
Use this for pure formatting with no intended behavior change.

- No test-first or red-to-green requirement.
- Run `dart format .`.
- Keep formatting-only changes in a separate commit when practical.

## Editing Rules

Use standard Dart formatting with 2-space indentation. Follow existing Dart naming: `PascalCase` for types, `camelCase` for members, and `snake_case.dart` for files.

Keep edits scoped:

- Prefer narrow patches over drive-by refactors.
- Separate functional changes from pure formatting when practical.
- Do not change generated artifacts, `.dart_tool/`, `build/`, or downloaded fixtures unless the task explicitly requires it.

Repository-specific caveats:

- `tool/**` and `example/**` are excluded from `dart analyze`, so changes there need targeted execution or tests.
- README snippets and commands are covered by tests; update those tests when behavior or docs change.

## Testing Rules

Every behavior change needs a focused regression test. Add tests close to the affected area and prefer extending existing suites before adding new files.

Common expectations by change type:

- WASI Preview1 behavior: update `test/wasi_test.dart`.
- Core Wasm runtime/parsing: update `test/wasm_test.dart` or the relevant spec/regression test.
- README-visible behavior: update `test/readme_snippets_test.dart` or `test/readme_commands_test.dart`.
- DOOM, Node, or browser flows: run the corresponding smoke or platform-specific tests.

If a change is meant to affect multiple runtimes, verify multiple runtimes.

## Commit and PR Guidelines

Use Conventional Commits, for example:

- `feat(wasi): ...`
- `fix(example/doom): ...`
- `test: ...`
- `style: ...`

Keep commit scopes specific to the area changed. When a task mixes behavior and formatting, prefer separate commits if that improves review clarity.

Pull requests should:

- stay narrowly scoped;
- explain the behavior change;
- list the verification commands actually run;
- link the relevant issue.

If a PR resolves an issue, use `Resolves #<id>` in the PR body. Include screenshots only for UI or `example/doom` changes.
