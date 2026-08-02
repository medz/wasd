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
- Running WASI Preview1 command modules
- Running stable WASI 0.2.12 command and HTTP proxy components on Dart VM
- Inspecting module imports/exports/custom sections

## Why WASD

- Pure Dart core runtime, aligned with Dart/Flutter embedding workflows
- Public API that mirrors WebAssembly-style operations (`compile`, `instantiate`, `validate`)
- Explicit host integration via import maps and typed wrappers
- Built-in WASI Preview1 host plus Preview2 command/proxy runners through `WASI`
- Regression-oriented tests and conformance tooling in-repo

## Installation

```bash
dart pub add wasd
```

Or add manually in `pubspec.yaml`:

```yaml
dependencies:
  wasd: ^0.4.0
```

## Quick Start

Run included examples:

```bash
dart run example/wasm_cli.dart
dart run example/wasm_cli.dart 3 9
```

The Flutter DOOM example has its own guide in the
[GitHub repository](https://github.com/medz/wasd/tree/main/example/doom).

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

To capture guest output instead of forwarding it to the host process streams,
provide per-instance byte sinks. Sinks receive raw bytes synchronously, so the
host chooses whether to buffer, stream, or limit the output.

```dart
import 'dart:typed_data';
import 'package:wasd/wasd.dart';

final stdout = BytesBuilder();
final stderr = BytesBuilder();
final wasi = WASI(stdoutSink: stdout.add, stderrSink: stderr.add);
```

## WASI Preview2 (Dart VM)

Decode a stable [WASI 0.2.12](https://github.com/WebAssembly/WASI/blob/main/specifications/wasi-0.2.12/Overview.md)
`wasi:cli/command` component and run it with the native Preview2 host:

```dart
import 'dart:io';
import 'package:wasd/wasd.dart';

Future<void> main() async {
  final bytes = await File('app.component.wasm').readAsBytes();
  final component = WasmComponent.decode(bytes);
  final host = WASI.preview2(args: const ['app.component.wasm']);
  final result = await WASIPreview2CommandRunner(host).run(component);

  print('exitCode=${result.exitCode}');
}
```

`WASIPreview2ProxyRunner` executes stable `wasi:http/proxy` incoming handlers
against a `WASIPreview2HttpIncomingRequest`. Preview2 execution is currently
native Dart VM only and targets the synchronous Canonical ABI required by
these stable WASI 0.2.12 worlds.

```dart
final proxyComponent = WasmComponent.decode(
  await File('proxy.component.wasm').readAsBytes(),
);
final proxyHost = WASI.preview2();
final request = WASIPreview2HttpIncomingRequest(
  method: const WASIPreview2HttpMethod.standard('get'),
  headers: WASIPreview2HttpFields(),
  pathWithQuery: '/',
  scheme: const WASIPreview2HttpScheme.standard('HTTP'),
  authority: 'example.test',
);
final response = await WASIPreview2ProxyRunner(proxyHost).handle(
  proxyComponent,
  request,
);
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

## Verification

```bash
dart analyze
dart test test/wasi_test.dart test/wasm_test.dart
dart test test/wasi_preview2_conformance_test.dart test/wasi_preview2_http_proxy_toolchain_test.dart
```

## Compatibility Snapshot

### WebAssembly Implementation Version

| Item | Version | Status |
| --- | --- | --- |
| Core Wasm module binary | `0x01 0x00 0x00 0x00` | Supported |

### WASI Version

| WASI Version | Status |
| --- | --- |
| Preview 1 | Supported for `wasi_snapshot_preview1` command modules |
| Preview 2 | Native Dart VM execution for stable WASI 0.2.12 `wasi:cli/command` and `wasi:http/proxy` components, with the required `random`, `clocks`, `io`, `cli`, `filesystem`, `sockets`, and `http` host import bindings |
| Preview 3 | Not supported for execution; experimental host/filesystem/async scaffolding remains available |

### Runtime Support

| Runtime | Preview1 host | Preview2 runner | Filesystem model |
| --- | --- | --- | --- |
| Dart VM | In-repo `wasi_snapshot_preview1`; passes official `wasm32-wasip1` wasi-testsuite command modules | Stable WASI 0.2.12 command and HTTP proxy components | Real host preopens plus portable in-memory VFS |
| Node.js | In-repo `wasi_snapshot_preview1`, not `node:wasi` | Not yet supported | Real host preopens plus portable in-memory VFS |
| Browser JS | In-repo `wasi_snapshot_preview1` | Not yet supported | Portable in-memory VFS |

The Preview2 runner deliberately does not claim general Component Model
coverage. Component Model 0.3 async/future/stream/task features, experimental
proposal packages, and full Preview3 execution remain out of scope.

When `dart:io` cannot faithfully implement a Preview2 socket operation, the
native adapter returns `not-supported` instead of reporting simulated success.
Native TCP bind/listen is currently unsupported; native TCP connect and UDP
bind/connect remain available.

Dart `HttpClient` does not expose HTTP trailers. Native outgoing-handler
requests with trailers and incoming responses that declare trailers therefore
report `HTTP-protocol-error`; proxy response trailers remain available to the
host caller.

Native outgoing HTTP preserves encoded response bodies and redirect responses;
it does not transparently decompress content or follow redirects.

The socket resolver performs dependency-free IDNA ToASCII conversion for a
conservative canonical Unicode subset and validates existing A-labels.
Disallowed symbols, malformed A-labels, and labels that require Unicode
normalization tables or ContextJ/ContextO processing are rejected with
`invalid-argument` instead of producing a non-canonical DNS name.

## Contributing

Contributions are welcome through pull requests and issues.

- Follow existing lint/style rules (`dart format .`, `dart analyze`)
- Add focused regression tests for behavior changes
- Keep changes scoped and reproducible with command output

## License

WASD is licensed under the MIT License. See [LICENSE](LICENSE).
