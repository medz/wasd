# Component map adapters

Available in `0.6.0-dev.3`.

This slice covers binary map types, validation and synchronous Canonical ABI
adapter calls. It follows Component Model source
[`0220da84209397d9067c19cac83dae969aa85a7b`](https://github.com/WebAssembly/component-model/tree/0220da84209397d9067c19cac83dae969aa85a7b).
General Component assertion execution and complete WASI `0.3.1` adoption remain
in the [standards plan](standards.md).

WIT bindings accept map parameters and results, including nested records and
lists:

```wit
interface tables {
  type entries = map<u32, string>;
  update: func(value: entries) -> entries;
}
world command { import tables; }
```

Keys may be `bool`, signed or unsigned 8/16/32/64-bit integers, `char`, or
`string`, including aliases of those primitive types. Floats, containers and
resource handles are invalid keys. Function signatures retain the existing
value and ownership checks. Static component value declarations cannot contain
resources, borrows, futures, streams or error contexts, even inside an empty map
or an inactive option.

`WasmComponentDefinedValueTypeKind.map` has separate `keyType` and `valueType`
fields. A `WasmComponentValueDataKind.map` stores ordered tuple pairs in
`items` or `runtimeItems`: each tuple contains a key followed by a value.
The adapters preserve entry order and duplicate keys; they do not allocate a
Dart `Map` to deduplicate entries.

A map has its own type identity. The Canonical ABI despecializes its memory
layout to `list<tuple<K, V>>`, using the existing pointer/length and allocation
rules. Reallocation may grow memory; writes refresh the memory view after
allocation and before continuing past a child that may allocate. Tests cover
both new-page payloads and nested allocations that replace an earlier view.

The focused regression suites execute memory roundtrips and both directions of
`bindAdapterPlans` / `invokeFlat`, including bound callbacks and returned
values. WIT tests also invoke nested map bindings. Decoder-only success is
recorded separately from those calls.

```sh
dart test test/component_test.dart test/wasi_component_value_memory_test.dart test/wasi_component_adapter_plan_test.dart test/wasi_component_wit_test.dart test/wasi_component_wit_adapter_runtime_test.dart
dart test -p node test/component_test.dart
dart test -p chrome test/component_test.dart
```
