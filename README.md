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
- Compiling and instantiating modules from bytes or streams
- Instantiating modules with host imports
- Executing exported functions from Dart
- Running WASI Preview1 workloads
- Inspecting module imports/exports/custom sections

## Why WASD

- Pure Dart core runtime, aligned with Dart/Flutter embedding workflows
- Public API that mirrors WebAssembly-style operations (`compile`, `instantiate`, `validate`)
- Explicit host integration via import maps and typed wrappers
- Built-in WASI Preview1 host surface through `WASI`
- Regression-oriented tests and conformance tooling in-repo

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
dart run example/wasm_cli.dart
dart run example/wasm_cli.dart 3 9
```

Run the Flutter DOOM example:

```bash
cd example/doom
flutter run -d macos
flutter run -d chrome --web-hostname=127.0.0.1 --web-port=8125 --web-header=Cross-Origin-Opener-Policy=same-origin --web-header=Cross-Origin-Embedder-Policy=require-corp
```

Minimal module invocation:

```dart
import 'dart:typed_data';
import 'package:wasd/wasd.dart';

Future<void> main() async {
  final Uint8List wasmBytes = loadYourModuleBytes();
  final runtime = await WebAssembly.instantiate(wasmBytes.buffer);
  final addExport = runtime.instance.exports['add'];
  if (addExport is! FunctionImportExportValue) {
    throw StateError('Expected `add` export to be a function.');
  }

  final result = (addExport.ref([20, 22]) as num).toInt();
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

Provide host callbacks with `Imports` and `ImportExportKind.function`:

```dart
import 'dart:typed_data';
import 'package:wasd/wasd.dart';

Future<void> main() async {
  final wasmBytes = loadYourModuleBytes();
  final imports = <String, ModuleImports>{
    'env': {
      'plus': ImportExportKind.function((args) {
        final a = args[0] as int;
        final b = args[1] as int;
        return a + b;
      }),
    },
  };

  final runtime = await WebAssembly.instantiate(wasmBytes.buffer, imports);
  final usePlus = runtime.instance.exports['use_plus'];
  if (usePlus is! FunctionImportExportValue) {
    throw StateError('Expected `use_plus` export to be a function.');
  }

  print(usePlus.ref([4, 5])); // 9
}

Uint8List loadYourModuleBytes() => throw UnimplementedError();
```

## WASI Preview1

Use `WASI` and call `_start` through `wasi.start(instance)`.

```dart
import 'package:wasd/wasd.dart';

Future<void> main() async {
  final wasmBytes = loadWasiModuleBytes();
  final wasi = WASI(
    args: const ['demo'],
    env: const {'FOO': 'bar'},
  );

  final runtime = await WebAssembly.instantiate(wasmBytes.buffer, wasi.imports);
  final exitCode = wasi.start(runtime.instance);

  print('exitCode=$exitCode');
}

Uint8List loadWasiModuleBytes() => throw UnimplementedError();
```

## Module Metadata

```dart
import 'dart:typed_data';
import 'package:wasd/wasd.dart';

Future<void> main() async {
  final wasmBytes = loadYourModuleBytes();
  final module = await WebAssembly.compile(wasmBytes.buffer);
  final imports = Module.imports(module);
  final exports = Module.exports(module);

  print('imports=${imports.length} exports=${exports.length}');
}

Uint8List loadYourModuleBytes() => throw UnimplementedError();
```

## Project Structure

- `lib/wasd.dart`: public package entrypoint
- `lib/src/`: runtime, VM, module decoder, validator, WASI, component model
- `test/`: regression and behavior tests
- `example/`: runnable examples (`wasm_cli.dart`, `doom_cli.dart`, `doom/`)
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
dart test test/doom_smoke_test.dart test/doom_e2e_node_test.dart
dart test test/wasi_test.dart test/wasm_test.dart
dart run example/wasm_cli.dart
```

## Compatibility Snapshot

### WebAssembly Implementation Version

| Item | Version | Status |
| --- | --- | --- |
| Core Wasm module binary | `0x01 0x00 0x00 0x00` | Supported |

### WASI Version

| WASI Version | Status |
| --- | --- |
| Preview 1 | Supported |
| Preview 2 | Not implemented |
| Preview 3 | Not implemented |

## Limitations

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
