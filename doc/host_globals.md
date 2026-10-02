# Numeric host globals

This addition is available in the `0.6.0-dev.1` preview. The Dart VM
adapter now accepts the existing `GlobalImportExportValue` wrapper for numeric
globals; it adds no public type or import-map format.

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
descriptor, and unsupported reference/vector host kinds also fail explicitly.

| Kind | Dart value | Binding behavior |
| --- | --- | --- |
| `ValueKind.i32` | `int` | Signed 32-bit wrapping |
| `ValueKind.i64` | `BigInt` | Signed 64-bit wrapping; the host property stays `BigInt` |
| `ValueKind.f32` | `double` | Rounded to binary32 |
| `ValueKind.f64` | `double` | Binary64 |

Existing standalone VM globals retain their value-box behavior. On first use
as a Wasm import, the numeric value is converted into one typed runtime binding;
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
VM numeric global exports retain the same binding when re-imported. Globals
defined by a module remain owned by each instance, even when compiled once.
Reference globals, GC initializer redesign, table/tag host imports and general
Component execution are outside this addition.

The existing JS adapter already accepts typed numeric host globals. Cross-target
tests check those bindings on Node and Chrome using scalar exports. The current
JS function bridge may return a JavaScript bigint wrapper for an `i64` result;
these tests inspect all 64 bits through two `i32` exports rather than changing
that function ABI. VM re-export/instance-owned isolation checks are separate
from these JS adapter checks, and no portable pure Dart interpreter claim is made.

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
