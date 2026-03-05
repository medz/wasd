# WASD

[![pub package](https://img.shields.io/pub/v/wasd.svg)](https://pub.dev/packages/wasd)
[![Dart SDK](https://img.shields.io/badge/Dart-%3E%3D3.11.0-0175C2?logo=dart)](https://dart.dev/)
[![License](https://img.shields.io/github/license/medz/wasd)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/medz/wasd?style=social)](https://github.com/medz/wasd/stargazers)

**A pure Dart WebAssembly runtime for Dart and Flutter ecosystems.**

WASD provides Dart-native WebAssembly execution with a pure Dart core runtime layer, so you can embed and run Wasm modules directly from Dart code without relying on a native runtime dependency in the core library.

## Overview

WASD is a Dart package for:

- Decoding and validating WebAssembly binaries
- Instantiating modules with host imports
- Executing exported functions from Dart
- Running WASI Preview1 workloads
- Decoding and instantiating WebAssembly Components
- Lowering/lifting values with a canonical ABI helper
- Gating proposal features through explicit runtime configuration

## Why WASD

- Pure Dart core runtime, aligned with Dart/Flutter embedding workflows
- Explicit host integration model via `WasmImports`
- Built-in WASI Preview1 surface with `WasiPreview1` and `WasiRunner`
- Component-model support via `WasmComponent` and `WasmComponentInstance`
- Feature gates for proposals such as SIMD, threads, exception handling, GC, and component model
- Extensive regression-oriented tests and spec-runner tooling in-repo

## Installation

```bash
dart pub add wasd
```

Or add manually in `pubspec.yaml`:

```yaml
dependencies:
  wasd: ^0.1.0
```

## Quick Start

Run included examples:

```bash
dart run example/hello.dart
dart run example/sum.dart
dart run example/sum.dart 3 9
```

Minimal module invocation:

```dart
import 'dart:typed_data';
import 'package:wasd/wasd.dart';

void main() {
  final Uint8List wasmBytes = loadYourModuleBytes();
  final instance = WasmInstance.fromBytes(wasmBytes);
  final result = instance.invokeI32('sum', [20, 22]);
  print(result); // 42
}

Uint8List loadYourModuleBytes() => throw UnimplementedError();
```

## DOOM CLI and Runtime Parity

Prepare Doom fixtures:

```bash
tool/setup_test_fixtures.sh --doom-only
```

Run the CLI baseline (native Dart runtime):

```bash
dart run example/doom_cli.dart --mode=instantiate
```

Run VM vs dart2js/Node parity matrix (same CLI entry):

```bash
dart run tool/doom_runtime_matrix.dart --mode=instantiate
```

You can switch to `--mode=start` to exercise `_start` behavior as the preview1 surface grows.

Capture and monitor the first rendered DOOM frame (Node.js runtime):

```bash
node tool/doom_node_monitor.mjs
```

This command writes a frame image (`.bmp`) and `report.json` under `.dart_tool/doom_node_monitor/frames/`.

## Host Function Imports

Provide host callbacks with `WasmImports`:

```dart
import 'dart:typed_data';
import 'package:wasd/wasd.dart';

void main() {
  final wasmBytes = loadYourModuleBytes();
  final imports = WasmImports(
    functions: {
      WasmImports.key('env', 'plus'): (args) {
        final a = args[0] as int;
        final b = args[1] as int;
        return a + b;
      },
    },
  );

  final instance = WasmInstance.fromBytes(wasmBytes, imports: imports);
  print(instance.invokeI32('use_plus', [4, 5])); // 9
}

Uint8List loadYourModuleBytes() => throw UnimplementedError();
```

## WASI Preview1

Use `WasiPreview1` directly or run `_start` via `WasiRunner`.

```dart
import 'dart:typed_data';
import 'package:wasd/wasd.dart';

void main() {
  final wasmBytes = loadWasiModuleBytes();
  final stdout = <int>[];
  final wasi = WasiPreview1(
    args: const ['demo'],
    stdoutSink: (bytes) => stdout.addAll(bytes),
  );

  final runner = WasiRunner(wasi: wasi);
  final exitCode = runner.runStartFromBytes(wasmBytes);

  print('exitCode=$exitCode');
  print(String.fromCharCodes(stdout));
}

Uint8List loadWasiModuleBytes() => throw UnimplementedError();
```

## Component Model

Enable `componentModel` when decoding/instantiating components:

```dart
import 'dart:typed_data';
import 'package:wasd/wasd.dart';

void main() {
  final componentBytes = loadComponentBytes();
  final instance = WasmComponentInstance.fromBytes(
    componentBytes,
    features: const WasmFeatureSet(componentModel: true),
  );

  final value = instance.invokeCore('one');
  print(value);
}

Uint8List loadComponentBytes() => throw UnimplementedError();
```

For canonical ABI flattening/lifting, use `WasmCanonicalAbi` helpers through `WasmComponentInstance.invokeCanonical(...)` / `invokeCanonicalAsync(...)`.

## Feature Gates

WASD uses `WasmFeatureSet` and `WasmFeatureProfile` to control proposal behavior.

- `core`: no proposal defaults
- `stable`: enables `simd`, `exception-handling`
- `full`: adds `threads`, `gc`, `component-model`

Example:

```dart
import 'package:wasd/wasd.dart';

void main() {
  final features = WasmFeatureSet.layeredDefaults(
    profile: WasmFeatureProfile.stable,
    additionalEnabled: const {'memory64'},
    additionalDisabled: const {'exception_handling'},
  );

  print(features.isEnabled('memory64')); // true
}
```

You can extend/override defaults with `additionalEnabled` and `additionalDisabled` (for example, `multi-memory`).

## Project Structure

- `lib/wasd.dart`: public package entrypoint
- `lib/src/`: runtime, VM, module decoder, validator, WASI, component model
- `test/`: regression and behavior tests
- `example/`: runnable examples (`hello.dart`, `sum.dart`, `doom/`)
- `tool/`: conformance runners and toolchain scripts
- `third_party/`: vendored Wasm spec/component testsuites

## Conformance & Tooling

```bash
git submodule update --init --recursive
tool/ensure_toolchains.sh --check
dart run tool/spec_runner.dart --target=vm --suite=all
```

Spec reports are written under `.dart_tool/spec_runner/`.

## Development

```bash
dart pub get
tool/setup_test_fixtures.sh
dart analyze
dart test
dart test test/doom_smoke_test.dart test/community_wasm_fixtures_test.dart
dart test test/wasi_preview1_test.dart
dart run example/hello.dart
```

## Compatibility Snapshot

### WebAssembly Implementation Version

| Item | Version | Status |
| --- | --- | --- |
| Core Wasm module binary | `0x01 0x00 0x00 0x00` | Supported |
| Wasm Component binary | `0x0d 0x00 0x01 0x00` | Supported |

### WASI Version

| WASI Version | Status |
| --- | --- |
| Preview 1 | Supported |
| Preview 2 | Not implemented |
| Preview 3 | Not implemented |

## Limitations

- Component instantiation requires enabling `componentModel` in `WasmFeatureSet`.
- Some proposal/component forms are intentionally guarded and may return `UnsupportedError` until implemented.
- JS runtime behavior is environment-dependent: Node.js uses `node:wasi`; browsers provide a minimal `wasi_snapshot_preview1` shim for command-style flows (`proc_exit`, `args_*`, `environ_*`, `random_get`, `fd_read`, `fd_write`, `fd_fdstat_get`, `fd_filestat_get`, `fd_prestat_*`, `fd_close`, `clock_time_get`) and virtual filesystem basics (`fd_seek`, `path_open`, `path_filestat_get`), with explicit `ENOSYS` stubs for unsupported calls (for example `path_unlink_file`, `proc_raise`, `sock_*`).
- Native preview1 host support intentionally tracks the same minimal surface as the browser shim: command-style flows plus virtual filesystem basics (`fd_seek`, `path_open`, `path_filestat_get`), while unsupported preview1 syscalls stay as explicit `ENOSYS` stubs.

Contributions for missing features and edge-case regressions are welcome.

## Contributing

Contributions are welcome through pull requests and issues.

- Follow existing lint/style rules (`dart format .`, `dart analyze`)
- Add focused regression tests for behavior changes
- Keep changes scoped and reproducible with command output

## License

WASD is licensed under the MIT License. See [LICENSE](LICENSE).
