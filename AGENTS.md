# Repository Guidelines

## Project Structure & Module Organization
`wasd` is a Dart package with a public entrypoint at `lib/wasd.dart` and core implementation under `lib/src/` (runtime, component model, WASI, validation, and VM helpers).  
Tests live in `test/` and use focused regression files such as `wasi_preview1_test.dart` and `component_test.dart`.  
Runnable examples are in `example/` (`hello.dart`, `sum.dart`), with a desktop Flutter demo in `example/doom/`.  
Tooling and conformance runners are in `tool/`.  
WebAssembly testsuites are vendored as submodules in `third_party/wasm-spec-tests` and `third_party/component-model-tests`.

## Build, Test, and Development Commands
- `dart pub get`: install package dependencies.
- `dart analyze`: run static analysis with repository lint rules.
- `dart test`: run the full test suite.
- `dart test test/wasi_preview1_test.dart`: run one focused suite.
- `dart run example/hello.dart`: quick runtime smoke test.
- `git submodule update --init --recursive`: fetch testsuite mirrors.
- `tool/ensure_toolchains.sh --check`: verify pinned `wabt`/`wasm-tools`.
- `dart run tool/spec_runner.dart --target=vm --suite=all`: run conformance checks (reports under `.dart_tool/spec_runner/`).

## Coding Style & Naming Conventions
Use standard Dart formatting (`dart format .`) with 2-space indentation.  
Lint baseline is `package:lints/recommended` plus `prefer_final_fields` and `prefer_final_locals`.  
Name files in `snake_case.dart`, types in `UpperCamelCase`, methods/variables in `lowerCamelCase`, and prefix private symbols with `_`.

## Testing Guidelines
Use `package:test`; all test files must end with `_test.dart` and stay under `test/`.  
Prefer deterministic, boundary-heavy regression tests for runtime/WASI behavior.  
When fixing a bug, add or update a targeted regression test in the nearest existing suite before broad refactors.

## Commit & Pull Request Guidelines
Follow Conventional Commits as used in history: `fix(scope): ...`, `test(scope): ...`, `refactor(scope)!: ...`.  
Use `!` for breaking behavior changes.  
PRs should include a concise behavior summary, linked issues (if any), and commands run (typically `dart analyze` and `dart test`; include spec/tool commands when relevant).  
For `example/doom` UI changes, include screenshots; for submodule or toolchain changes, call out updated revisions explicitly.
