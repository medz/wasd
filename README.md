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
- Running stable WASI 0.3.0 command and HTTP service components on Dart VM
- Inspecting module imports/exports/custom sections

## Why WASD

- Pure Dart core runtime, aligned with Dart/Flutter embedding workflows
- Public API that mirrors WebAssembly-style operations (`compile`, `instantiate`, `validate`)
- Explicit host integration via import maps and typed wrappers
- Built-in WASI Preview1 host plus Preview2 and Preview3 runners through `WASI`
- Regression-oriented tests and conformance tooling in-repo

## Installation

```bash
dart pub add wasd
```

Or add manually in `pubspec.yaml`:

```yaml
dependencies:
  wasd: ^0.5.2
```

This preview is `0.6.0-dev.3`. The latest stable release is `0.5.2`, selected
by the default installation above.

To opt into the preview explicitly:

```bash
dart pub add wasd:^0.6.0-dev.3
```

Or use:

```yaml
dependencies:
  wasd: ^0.6.0-dev.3
```

The preview combines Dart VM [multi-memory opt-in](doc/core_features.md),
[typed numeric host globals](doc/host_globals.md), and
[unambiguous Core import names](doc/import_identity.md), together with the
previously unpublished floating-point and GC initialization fixes. Those fixes
were prepared as `0.5.3` and are now included in this batch; a separate `0.5.3`
release is not planned. These additions require the preview installation and
do not establish full Core, Component Model or WASI conformance. See the [fixed standards and acceptance plan](doc/standards.md).

Version `0.6.0-dev.2` adds [public numeric tags and exceptions](doc/host_tags.md),
including host/guest propagation on Dart VM and Dart2js on Node and Chrome.
Native modules require `CoreFeature.exceptionHandling`. It also corrects
Preview2 TCP listen failure state and adds the Preview3 TCP and clock fixes
described below. These additions were not included in `0.6.0-dev.1`.

The frozen Core 3.0 gate now checks all `261` official source files, preserving
their original paths. It also exposed and fixed validation of multiple
supertypes. See the [standards plan](doc/standards.md) for the `65,336` command
result and its execution and public API coverage boundaries.

Version `0.6.0-dev.3` adds [synchronous Component map adapters](doc/component_maps.md).
It also supports Component name attributes and named WIT interface bindings;
see the [standards plan](doc/standards.md) for their scope.
Its execution gate runs complete frozen Component string and numeric
files through WASD, including nested scalar calls and strict invocation traps;
these selected files do not establish full Component conformance.
Version `0.6.0-dev.3` adds WASI `0.3.1` contract and linking support alongside `0.3.0`, with
versioned WIT calls plus command/service execution tests. The official 45-case
suite remains a separate `0.3.0` compatibility gate.
The Preview1 gate in `0.6.0-dev.3` freezes all 72 official `wasm32-wasip1` cases and
verifies every fixture and runner input before execution. Native Linux/macOS
results and Node/browser regressions remain separate acceptance profiles;
see the [standards plan](doc/standards.md) for the uncovered syscall boundaries.

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

## WASI Preview3 (Dart VM)

Decode a stable [WASI 0.3.0](https://github.com/WebAssembly/WASI/tree/3ee2a590c766594ae44a54730fc74fc27da5c609)
`wasi:cli/command` component and run its async entrypoint with the native
Preview3 host:

```dart
import 'dart:io';
import 'package:wasd/wasd.dart';

Future<void> main() async {
  final bytes = await File('app.component.wasm').readAsBytes();
  final component = WasmComponent.decode(bytes);
  final host = WASI.preview3(args: const ['app.component.wasm']);
  try {
    final result = await WASIPreview3CommandRunner(host).run(component);
    print('exitCode=${result.exitCode}');
  } finally {
    host.close(force: true);
  }
}
```

`WASIPreview3ServiceRunner` executes stable `wasi:http/service` components.
Each request is passed directly to the component handler; integrating it with
an HTTP server remains an application concern.

```dart
final serviceComponent = WasmComponent.decode(
  await File('service.component.wasm').readAsBytes(),
);
final serviceHost = WASI.preview3();
try {
  final request = WASIPreview3HttpRequest.noTrailers(
    headers: WASIPreview3HttpFields(),
  )
    ..method = const WASIPreview3HttpMethod.standard('get')
    ..pathWithQuery = '/';
  final result = await WASIPreview3ServiceRunner(serviceHost).handle(
    serviceComponent,
    request,
  );
  if (!result.isOk) {
    throw StateError('service failed: ${result.errorCode}');
  }
  final response = result.value!;
  try {
    print('status=${response.statusCode}');
    // Forward response.contents and response trailers to the client here.
  } catch (_) {
    await response.cancel();
    rethrow;
  }
  await response.completeTransmission(
    const WASIPreview3HttpResult<void>.ok(null),
  );
} finally {
  serviceHost.close(force: true);
}
```

Each successful service response retains its component resource scope while
its body and trailers are in flight. Call `completeTransmission` after the
client observes the response, or `cancel` when abandoning it, so that scope is
released deterministically.

The frozen Preview3 contract covers the six stable `random`, `clocks`,
`filesystem`, `sockets`, `cli`, and `http` packages and eight import/execution
worlds. `wasi:clocks/timezone` is not part of that contract.

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
dart test test/wasi_preview3_async_runtime_test.dart test/wasi_preview3_service_runner_test.dart test/wasi_preview3_standard_wit_test.dart test/wasi_preview3_sockets_test.dart
dart run tool/wasi_testsuite_preview3_runner.dart \
  --testsuite-dir=/path/to/wasi-testsuite \
  --runner-dir=/path/to/wasi-testsuite/test-runner \
  --python=/path/to/venv/bin/python
```

The historical `0.5.0` and `0.6.0-dev.1` `wasm32-wasip3` baseline
passes `39/45` fixtures. The six failures
(`sockets-tcp-bind`, `sockets-tcp-listen`, `sockets-echo`,
`sockets-tcp-connect`, `sockets-tcp-receive`, and `sockets-tcp-send`) require
the explicit native TCP bind/listen split that `dart:io` cannot represent; they
fail with `not-supported`. There are no skips, expected failures, or unexpected
passes.

Version `0.6.0-dev.2` records `45/45` frozen official fixtures passed
through the native AOT runner, with zero failures, skips, expected failures or
unexpected passes. The fixed input revisions and counts are recorded in
`tool/wasi_preview3_contract.lock.json`.

Version `0.6.0-dev.2` adds native Preview3 TCP bind/listen on Linux and macOS using
the same OS socket through bind, listen or connect. Bind assigns
a local address without starting a listener; address reuse follows the WASI
contract and platform semantics. Monotonic waits recheck their deadlines after
timer wakeups so they cannot complete early. These changes were absent from
`0.6.0-dev.1`. Native CI runs the fixed official set through one
compiled AOT runtime per Linux/macOS job and runs host unit regressions on the
JIT VM. Other native platforms still report `not-supported` for explicit TCP
bind.

The frozen Component Model async gate currently records three distinct kinds
of evidence:

- WASD strict decoding: `37/37` component files decoded.
- `wasm-tools` `1.254.0` validation: `31/31` async WAST files validated.
- Wasmtime `48.0.0 (e8ac8c27f)` reference execution: `31/31` async WAST
  files passed.

The `wasm-tools` and Wasmtime results validate the frozen upstream inputs and
reference behavior. They do not execute those WAST assertions through WASD;
WASD's result in this gate is the strict decoder result above.
This frozen draft uses the recorded validator version: newer Core converters
reject its removed `cancellable` option and cannot replace that legacy check.

## Compatibility Snapshot

See [Standards coverage and the road to 1.0](https://github.com/medz/wasd/blob/main/doc/standards.md) for the fixed
specification targets, implementation evidence, and remaining acceptance gates.

### WebAssembly Implementation Version

| Item | Version | Status |
| --- | --- | --- |
| Core Wasm module binary | `0x01 0x00 0x00 0x00` | Supported |

### WASI Version

| WASI Version | Status |
| --- | --- |
| Preview 1 | Supported for `wasi_snapshot_preview1` command modules |
| Preview 2 | Native Dart VM execution for stable WASI 0.2.12 `wasi:cli/command` and `wasi:http/proxy` components, with the required `random`, `clocks`, `io`, `cli`, `filesystem`, `sockets`, and `http` host import bindings |
| Preview 3 | Native Dart VM execution for stable WASI 0.3.0 `wasi:cli/command` and `wasi:http/service` components across the frozen six-package, eight-world contract |

### Runtime Support

| Runtime | Preview1 host | Preview2 runner | Preview3 runner | Filesystem model |
| --- | --- | --- | --- | --- |
| Dart VM | In-repo `wasi_snapshot_preview1`; 72 selected official `wasm32-wasip1` command modules | Stable WASI 0.2.12 command and HTTP proxy components | Stable WASI 0.3.0 command/service components plus 0.3.1 contract/linking | Real host preopens plus portable in-memory VFS |
| Node.js | In-repo `wasi_snapshot_preview1`, not `node:wasi` | Not supported | Not supported | Real host preopens plus portable in-memory VFS |
| Browser JS | In-repo `wasi_snapshot_preview1` | Not supported | Not supported | Portable in-memory VFS |

The Preview2 and Preview3 runners deliberately do not claim general Component
Model execution. Preview3 support covers the frozen stable WASI 0.3.0
contract and its 0.3.1 contract/linking extension; experimental proposal packages and features outside that contract
remain out of scope.

Preview1 CPU-clock queries in `0.6.0-dev.3` use host process/current OS thread CPU
time on 64-bit Linux/macOS and the corresponding Node CPU API when available.
Unsupported CPU clocks return `INVAL` without modifying guest output. These
are host counters; they do not isolate CPU consumption per guest. CPU-clock
`poll_oneoff` subscriptions return an event with `INVAL`, since CPU timers are
not implemented. Realtime and monotonic timers retain their existing behavior.

Native Preview3 filesystem preopens reject guest absolute paths, `..`
traversal, and symlink escapes at resolution time. Dart exposes path-based
filesystem APIs rather than descriptor-relative traversal, so WASD cannot
close a time-of-check/time-of-use race if another process can concurrently
replace a preopen path component. Use preopen directories that untrusted
actors cannot modify when filesystem isolation is required.

When `dart:io` cannot faithfully implement a Preview2 socket operation, the
native adapter returns `not-supported` instead of reporting simulated success.
Preview2 native TCP bind/listen is currently unsupported; Preview2 native TCP
connect and UDP bind/connect remain available.

Preview3 synchronous socket imports may return pending Dart callbacks; the
component runner waits for them before returning to the guest. The development
Linux/macOS backend uses native sockets for explicitly bound TCP endpoints;
unbound TCP listen and connect continue to use `dart:io`. These operations wait
for real OS endpoints before reporting success. Native UDP bind and implicit UDP
connect likewise wait for a real `RawDatagramSocket`. TCP and UDP option values
are applied through native raw socket options when an active endpoint exists.
`RawDatagramSocket` has no IPv6-only bind option, so an IPv6 wildcard UDP socket
may also reserve the matching IPv4 port; IPv4 and IPv4-mapped datagrams are
discarded before they reach that IPv6 guest socket. Native addresses with
nonzero IPv6 flow info or numeric scope IDs return `not-supported` because
`dart:io` cannot preserve those fields.

Dart `HttpClient` does not expose HTTP trailers. Native outgoing-handler
requests with trailers and incoming responses that declare trailers therefore
report `HTTP-protocol-error`; proxy response trailers remain available to the
host caller. The Preview3 native client likewise reports
`HTTP-protocol-error` for outgoing request trailers and declared incoming
response trailers.

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
