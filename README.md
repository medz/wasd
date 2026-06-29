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
  wasd: ^0.2.0
```

## Quick Start

Run included examples:

```bash
dart run example/wasm_cli.dart
dart run example/wasm_cli.dart 3 9
```

The Flutter DOOM example has its own guide in
[`example/doom/README.md`](example/doom/README.md).

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
```

## Compatibility Snapshot

### WebAssembly Implementation Version

| Item | Version | Status |
| --- | --- | --- |
| Core Wasm module binary | `0x01 0x00 0x00 0x00` | Supported |

### WASI Version

| WASI Version | Status |
| --- | --- |
| Preview 1 | Partial, actively expanding |
| Preview 2 | Not implemented |
| Preview 3 | Not implemented |

## Limitations

- Some proposal/component forms are intentionally guarded and may return `UnsupportedError` until implemented.
- `WASI(version: WASIVersion.preview2)` and `WASI(version: WASIVersion.preview3)` are explicit future-facing version choices and currently throw `UnsupportedError`; only Preview1 host instantiation is implemented.
- JS runtimes use the in-repo `wasi_snapshot_preview1` host on both Node.js and browsers, not `node:wasi`, for command-style flows (`proc_exit`, `proc_raise` through an optional `procRaiseHandler`, `args_*`, `environ_*`, `random_get`, configured-stdin `fd_read`, `fd_write`, socket `fd_read`/`fd_write`, `fd_pread`, `fd_pwrite`, `fd_tell`, `fd_advise`, `fd_datasync`, `fd_sync`, `fd_allocate`, `fd_fdstat_get`, `fd_fdstat_set_flags`, `fd_fdstat_set_rights`, `fd_filestat_get`, `fd_filestat_set_size`, `fd_filestat_set_times`, `fd_prestat_*`, `fd_close`, `fd_renumber`, `clock_time_get`, `poll_oneoff` clock/file/socket readiness) and virtual filesystem basics (`fd_seek`, `fd_readdir`, `path_open`, `path_filestat_get`, `path_filestat_set_times`, writable in-memory files, path create/link/symlink/readlink/rename/unlink/remove, symlink-follow lookup flags, descriptor rights enforcement, configured Preview1 stream socket descriptors for `sock_accept`, configured stream/datagram socket descriptors for `sock_recv`, `sock_send`, `fd_read`, `fd_write`, and `sock_shutdown`, and host-backed stream/datagram receive/send handlers for injected socket descriptors). JS `proc_raise` returns `ENOSYS` unless a handler is provided.
- Native preview1 host support covers the shared JS surface plus native-only real host filesystem backing for configured preopened host directories. The shared VFS remains the portable in-memory backend used by JS and by virtual files; native preopens are the real filesystem bridge. On native, `path_open` can open regular host files below a preopen, `fd_read`, `fd_pread`, `fd_seek`, `fd_tell`, and `fd_filestat_get` operate on the host file handle without loading the whole file into the in-memory VFS, `fd_write`, `fd_pwrite`, `fd_filestat_set_size`, `fd_allocate`, `O_TRUNC`, and `O_CREAT` persist regular-file changes to the host filesystem, `path_create_directory`, `path_unlink_file`, `path_remove_directory`, `path_rename`, `path_link`, and `path_symlink` mutate real host directories/files for create/delete/rename/hard-link/symlink flows, `path_readlink` reads real host symlink targets, `path_open` and `path_filestat_get` follow real host symlinks only when the resolved target stays inside the configured preopen, `path_open(O_DIRECTORY)` can open host directories, `fd_readdir` lists a deterministic snapshot of host directory entries, and `path_filestat_get` reports host regular-file, directory, and symlink type/size metadata. Full host symlink timestamp/set-times metadata is not implemented yet for real host paths; those remaining symlink metadata APIs currently apply to the in-memory VFS. Native also supports `proc_raise` signal delivery or an optional `procRaiseHandler`, configured `WASIPreview1Socket` stream descriptors for `sock_accept`, configured stream/datagram descriptors for `sock_recv`, `sock_send`, `fd_read`, `fd_write`, and `sock_shutdown`, and host-backed stream/datagram receive/send handlers for injected socket descriptors. Preview1 does not define socket creation syscalls, so native/JS socket support is descriptor injection rather than a raw networking API.

Contributions for missing features and edge-case regressions are welcome.

## Contributing

Contributions are welcome through pull requests and issues.

- Follow existing lint/style rules (`dart format .`, `dart analyze`)
- Add focused regression tests for behavior changes
- Keep changes scoped and reproducible with command output

## License

WASD is licensed under the MIT License. See [LICENSE](LICENSE).
