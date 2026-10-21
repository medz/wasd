# Host globals

Version `0.6.0` includes numeric host-global bindings, first published in
`0.6.0-dev.1`. Released `0.6.1` retains that numeric support. Unreleased main
also binds nullable `externref` and `funcref` globals on the Dart VM through the
existing `GlobalImportExportValue` wrapper, without a new public type or
import-map format.

```dart
import 'package:wasd/wasm.dart';

final seed = Global<Int32, int>(
  const GlobalDescriptor<Int32, int>(value: ValueKind.i32),
  666,
);
final module = Module(bytes.buffer, features: {CoreFeature.multiMemory});
final instance = Instance(module, {
  'spectest': {'global_i32': ImportExportKind.global(seed)},
});
```

Use `mutable: true` in the descriptor for a mutable import. The VM links only
matching value kinds and mutability: an `f32` global cannot satisfy an `i32`
import, and a mutable global cannot satisfy an immutable declaration or vice
versa. Mismatches throw `LinkError` before active data initialization and the
start function. Missing globals, foreign implementations with no checkable
descriptor, and unsupported global kinds also fail explicitly. Unreleased VM
reference bindings accept only the abstract nullable `externref` and `funcref`
types, including their equivalent explicit `(ref null extern)` and
`(ref null func)` encodings. Typed, nonnullable, GC and vector global boundaries
are rejected before data initialization or the start function; they are not
silently omitted from exports.

| Kind | Dart value | Binding behavior |
| --- | --- | --- |
| `ValueKind.i32` | `int` | Signed 32-bit wrapping |
| `ValueKind.i64` | `BigInt` | Signed 64-bit wrapping; the host property stays `BigInt` |
| `ValueKind.f32` | `double` | Rounded to binary32 |
| `ValueKind.f64` | `double` | Binary64 |
| `ValueKind.externref` | `Object?` | Unreleased VM: retain the original host value, including `null` |
| `ValueKind.funcref` | `Function?` | Unreleased VM: a genuine function from this backend, or `null` |

Existing standalone VM globals retain their value-box behavior. On first use
as a Wasm import, the value is converted into one typed runtime binding;
subsequent host reads/writes use that binding. Immutable setters still fail.
Unused global entries in a superset imports map remain standalone and are not
checked or converted, including entries whose name declares another import kind.
Selection compares the original module/name pair, including names containing
`::`. Shared internal import keys now use unambiguous length prefixes, so
distinct declared pairs remain distinct instead of being rejected or silently
aliased. See [import identity](import_identity.md) for the internal migration.
This is an embedder conversion boundary, not a guarantee of transactional host
state rollback after a later linking or initialization failure.

The same host `Global` passed to multiple imports or instances shares its
storage: host setters are visible to Wasm, and `global.set` is visible to the
host and other importing instances. Distinct host objects remain independent.
VM global exports retain the same binding when re-imported. Globals defined by
a module remain owned by each instance, even when compiled once. This addition
does not extend table/tag host imports, GC initializers or Component execution.

## Reference identity and lifetime

For an external reference, the VM returns the original Dart value rather than
an integer handle or a copy. Distinct host objects remain distinct even when
their `==` operators compare equal. Integers such as `-1` are ordinary external
values and cannot forge a null or function reference.

A nullable function global can use `Global<FuncRef, Function?>` with
`GlobalDescriptor<FuncRef, Function?>(value: ValueKind.funcref)`. A non-null value
must be a genuine Wasm function from this backend; an arbitrary Dart
closure is rejected. Re-exporting a function reference preserves its identity
and originating instance. Guest indirect calls still check the real function
signature. Calls that reach an asynchronous guest target return a `Future`,
including when the importing instance has only synchronous host imports.
Modules with function-returning host imports use awaitable exports so that a
returned function can be called indirectly in the same guest invocation. Once
an instance has observed an asynchronous function dependency, its function
exports continue returning futures if that reference later moves into a table.
Imports sharing a module and field name must have equivalent signatures when
reference conversion is required; conflicting signatures are rejected before
data initialization or start functions run. An unused function export with an
unsupported reference signature does not prevent instantiation; calling that
export is rejected before guest execution.

Connected instances, globals and exported functions share a reference-store
lifetime. The store retains distinct external values previously passed through
it, including values copied into guest locals or tables after a global changes.
Those values remain retained while any connected store owner is alive; they are
not collected individually when a global is overwritten. The process-wide
reference directories use weak entries and finalizers rather than permanent
strong object roots. This is a store-lifetime retention boundary, not a general
Wasm GC guarantee.

## JavaScript adapter

The existing JS adapter accepts typed numeric host globals and its supported
`externref` primitives: `null`, `int`, `double`, `bool`, `String` and `BigInt`.
Arbitrary Dart objects and Functions as external references remain unsupported,
as do public JS `funcref` values. The unreleased re-import path retains the
underlying JavaScript global instead of copying its value. Node and Chrome
regressions cover these adapter bindings separately from VM reference support;
they do not execute the pure Dart interpreter.

The current JS function bridge may return a JavaScript bigint wrapper for an
`i64` result. Numeric cross-target tests inspect all 64 bits through two `i32`
exports rather than changing that function ABI. These global bindings do not
establish complete JSPI or cross-platform reference support.

## Official data-segment gap

The public runner now supplies the pinned spectest immutable `i32` global `666`
and memory (one initial page, maximum two) through public wrappers. It executes
all seven commands in `data0.wast` and all fourteen instantiation assertions in
`data1.wast` at testsuite `193e551ff22663995b1ac95dc62344133669e14b`.

```sh
dart run tool/core_multi_memory_public_runner.dart --file=data0 --file=data1
dart test test/wasm_host_globals_test.dart
dart test -p node test/wasm_host_globals_test.dart
dart test -p chrome test/wasm_host_globals_test.dart
```

The two-file gap has 21 passing commands, zero failures/skips/not-run commands
and zero unexpected link failures. The complete fixed subset is 16 files and
396 commands. A wrong provider type or mutability is an unexpected link failure,
not a successful bounds trap. On a command failure, dependent commands in that
file are recorded as not run; subsequent files still run and the process exits
nonzero. `--file` selections must belong to the fixed subset. Reports retain
pass/fail/skip/not-run/link-failure counts separately. wasm-tools only converts
the WAST input; all assertion execution uses public WASD `Module`/`Instance`.

This does not establish full October Core conformance or Component/WASI `0.3.1`
compatibility. Those remain in the [standards plan](standards.md).
