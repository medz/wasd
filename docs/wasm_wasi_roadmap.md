# Wasm and WASI Roadmap

This repository is moving from limited Wasm plus WASI Preview 1 support toward
real, verified Wasm and WASI support across Preview 1, WASI 0.2, and WASI 0.3.
This document is the working architecture guide for that transition.

Status date: 2026-06-21.

## External Reference Points

- WASI upstream now describes WASI 0.3 as the current preview, building on
  WASI 0.2 with component-model-native `async`, `future<T>`, and `stream<T>`.
  Reference: https://github.com/WebAssembly/WASI
- WASI.dev states that WASI 0.3.0 was released on 2026-06-11, with support in
  Wasmtime 43+ and jco. It also notes that `wasi:io` is removed and absorbed
  into the component model Canonical ABI.
  Reference: https://wasi.dev/roadmap
- Wasmtime keeps WASI 0.3 behind a dedicated `p3` crate feature and labels it
  experimental, unstable, and incomplete. Its p3 layer is split by interface
  groups (`cli`, `clocks`, `filesystem`, `random`, `sockets`) and linked through
  per-store `WasiCtx` plus `ResourceTable`.
  Reference: https://docs.rs/wasmtime-wasi/latest/wasmtime_wasi/p3/
- wasmCloud keeps P3 behind a `wasip3` feature and registers P3 implementations
  alongside P2 while keeping P2 stable by default.
  Reference: https://wasmcloud.com/docs/runtime/

## Architecture Direction

1. Keep the Wasm core runtime, component decoder, and WASI host layers separate.
   Component decoding may be permissive, but semantic validation must be
   explicit and diagnosable.
2. Treat WASI Preview 1, WASI 0.2, and WASI 0.3 as versioned host surfaces, not
   as one mixed namespace. Shared host primitives should sit below the versioned
   adapters.
3. Model component resources with a resource table abstraction before claiming
   production P2/P3 support. P3 streams and futures require stable ownership,
   borrowing, drop, and async lifecycle behavior.
4. Keep runtime support claims tied to real verification. README and public API
   docs must distinguish implemented, experimental, and planned surfaces.
5. Prefer generated or spec-derived interface bindings once WIT coverage starts.
   Hand-written host shims should stay narrow and tested.

## Performance Direction

- Validation must be linear in the decoded component graph wherever possible.
  Recursive graph checks must use memoization and visiting sets.
- Component decode and validation changes should be measured with
  `dart run tool/component_benchmark.dart --json`. The synthetic benchmark
  exercises repeated `stream<T>` definitions over a shared borrow-containing
  type graph, which is the current stress case for component validation.
- Test runners must report elapsed time and peak memory for heavy paths, at
  minimum the spec runner and DOOM runtime tests.
- Heavy external-process tests should be grouped behind explicit runner modes so
  default validation remains useful without hiding performance regressions.
- Any new conformance runner should cache toolchain discovery, generated
  bundles, and fixture conversion results by input hash.

## Near-Term Slices

1. Finish component-model validation gaps that are local and deterministic:
   resource type references, function/result restrictions, borrow containment,
   canonical options, and start/import/export index validation.
2. Add a small benchmark harness for component validation and decode paths before
   broadening official corpus coverage.
3. Audit `tool/spec_runner.dart` and DOOM tests for process-spawn and fixture
   conversion hot spots, then add timing and caching where it changes actual
   runtime cost.
4. Introduce explicit WASI version modules for future P2/P3 work instead of
   extending Preview 1 host types in place.
5. Add WIT/interface ingestion only after the versioned host boundary and
   resource-table model are in place.

## Completion Bar

The project should not claim full WASI 0.3 support until it can run real P3
components through a versioned host layer with resource, stream, future, and
async behavior covered by tests and measured performance gates.
