# Host table fixtures

These tiny fixtures cover public basic nullable externref/funcref table bindings.
Generate each `.wasm` from the matching `.wat` with the pinned
`.toolchains/bin/wasm-tools parse`, then run `wasm-tools validate` and update
`test/support/host_table_fixtures.dart` with the exact binary base64.

`limits_effect` checks rejection before active element/data initialization and
start, with a valid grown-table control using its current length. Async function
sources reuse the checked reference-global callback fixture.

The private table fixture keeps numeric exports synchronous with a synchronous
host tick. The copy fixture is exercised through an explicitly enabled internal
multi-table bridge; source/target public Tables and the final public call stay
observable, without claiming public multi-table feature support. Unsupported
public typed, nonnullable, GC and table64 export fixtures must reject before
active data or start. Public record checks use value and nested Object identity.
