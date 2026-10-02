# Explicit Core options

This API is part of the unreleased `0.6.0-dev.1` batch. Published `0.5.2` does not
provide it. The previously unpublished `0.5.3` floating-point fixes are included
in this batch; their frozen artifacts remain archived for restoration, with no
separate `0.5.3` release planned.

`Module` accepts an optional set of Core extensions. Omitting the set, or passing
an empty set, preserves the existing backend defaults. `supportedFeatures` is
an immutable set of extensions that the selected backend can explicitly enable;
it is not an inventory of default instructions or a whole-spec conformance claim.

```dart
import 'package:wasd/wasm.dart';

// bytes is a Uint8List containing a Core module.
if (!Module.supportedFeatures.contains(CoreFeature.multiMemory)) {
  throw UnsupportedError('This backend cannot explicitly enable multi-memory.');
}
final module = Module(bytes.buffer, features: {CoreFeature.multiMemory});
final instance = Instance(module, imports);
final read = instance.exports['read'] as FunctionImportExportValue;
final result = read.ref([]);
```

The Dart VM supports `CoreFeature.multiMemory` using the pure Dart interpreter.
It allows multiple imported/defined/exported linear memories and indexed scalar
loads/stores, size/grow, copy/fill/init and data segments. The existing public
host ABI supports function, memory and [numeric global imports](host_globals.md).
Enabling this option does not add reference global/table/tag imports or enable
SIMD, GC, threads or multiple tables.
Invalid memory indices, alignment and operand types still fail compilation.
Out-of-bounds accesses and dropped data segments still trap during execution;
an out-of-bounds active data segment fails instantiation. Existing runtime trap
wrappers are preserved, rather than promising a new common error class.

The JavaScript adapter currently reports an empty explicit-options set and
throws `CompileError` for any nonempty request before asking the platform engine
to compile. Its default behavior continues to follow the platform WebAssembly
engine, which may accept extensions implicitly. JS adapter checks do not prove
pure Dart interpreter portability. `WebAssembly.compile`/`instantiate` keep
their existing defaults; use `Module` when explicit options are needed.

## Executable acceptance matrix

The frozen [Core specification source](https://github.com/WebAssembly/spec/tree/957c932e7158c5a6891be68ca424aaa0aa505f97)
incorporates multiple memories in Release 3.0. This candidate uses a subset of
the [official testsuite](https://github.com/WebAssembly/testsuite/tree/193e551ff22663995b1ac95dc62344133669e14b)
at `193e551ff22663995b1ac95dc62344133669e14b`. That June suite predates the frozen
October target; this is feature acceptance evidence, not full October conformance.

| Behavior | Public execution or rejection evidence |
| --- | --- |
| Multiple imports/definitions/exports, indexed size/grow, independent limits | `memory_grow`, `memory_size_import`, `memory_size0/1/2`; public regression checks imported storage, aliases and separate instance-owned memory |
| Indexed scalar memory access and traps | `memory_trap0/1`, including i32/i64/f32/f64 operations; public sync/async-host bounds regressions |
| Indexed copy/fill/init, data drop and bounds | `memory-multi`, `memory_copy0/1`, `memory_fill0`, `memory_init0`, `data_drop0`; public sync/async-host regression |
| Immutable host global offsets and instantiation bounds | `data0/1`; typed public host-global regressions and wrong-provider controls |
| Invalid operand types | `memory_size3`; local official-invalid index/copy/alignment/type fixtures |
| Default compatibility, immutable query, copied caller options | Public `wasm_core_features_test.dart` |
| Other disabled options remain disabled | Official-valid multi-memory + SIMD/GC/multiple-table fixtures fail public compilation |
| Unsupported explicit JS request and unchanged default scalar module | Public Node and Chrome regressions |

Run the public official subset after installing the pinned fixture toolchain:

```sh
dart run tool/core_multi_memory_public_runner.dart
dart test test/wasm_core_features_test.dart
dart test -p node test/wasm_core_features_test.dart
dart test -p chrome test/wasm_core_features_test.dart
```

The runner executes all commands in its fixed 16 files through public
`Module`/`Instance`: 396 commands, including compile rejection and execution
trap assertions. It fails on unknown commands, values, a mismatched suite
revision or an unexpected result. `wasm-tools` only converts WAST to binaries.
The official `data0`/`data1` scripts are included using typed numeric host globals.
Unexpected link failures are recorded separately from expected instantiation
traps and commands that could not run after a failure.

General Component execution and WASI `0.3.1` remain subsequent acceptance work
under the [fixed standards plan](standards.md). This option neither implements
nor claims those contracts.
