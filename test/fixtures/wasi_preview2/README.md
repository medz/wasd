# WASI Preview2 fixtures

## `wasmtime_v47_0_3_hello.component.wasm`

This is a fixed, offline conformance fixture for a real
`wasi:cli/command` component. It writes `Hello, world!\n` to stdout and exits
with status 0.

- Upstream release: Wasmtime `v47.0.3`
- Upstream commit: `5554cc1a651da536af2cc46c7324bdc085b162e3`
- Source:
  [`hello_wasi_snapshot1.wat`](https://raw.githubusercontent.com/bytecodealliance/wasmtime/5554cc1a651da536af2cc46c7324bdc085b162e3/tests/all/cli_tests/hello_wasi_snapshot1.wat)
  - Size: 728 bytes
  - SHA-256:
    `86a3163046a33dec0b8f0625242d07e8edb7cfee40411f86106dfad4b9c22fc6`
- Preview1 command adapter:
  [`wasi_snapshot_preview1.command.wasm`](https://github.com/bytecodealliance/wasmtime/releases/download/v47.0.3/wasi_snapshot_preview1.command.wasm)
  - Size: 52,870 bytes
  - SHA-256:
    `9b1c0683da07acc749a148335c98ac5cbd9155876013dc20d73679f86a421bcd`
- Generator: `wasm-tools 1.252.0 (d66d4364c 2026-06-12)`
- Generated core module:
  - Size: 254 bytes
  - SHA-256:
    `9bf371b7e1f46d4c3e07bffb065d6523d71b296d69f2d50aa05b783fc73189ac`
- Generated component:
  - Size: 18,717 bytes
  - SHA-256:
    `9bc764eae49b55c963bbce08b5d9caebe176d7e32fdee097a85930495396a329`

Generate from the verified source and adapter files at the repository root:

```sh
.toolchains/bin/wasm-tools parse \
  hello_wasi_snapshot1.wat \
  -o hello_wasi_snapshot1.wasm

.toolchains/bin/wasm-tools component new \
  hello_wasi_snapshot1.wasm \
  --adapt wasi_snapshot_preview1=wasi_snapshot_preview1.command.wasm \
  -o wasmtime_v47_0_3_hello.component.wasm
```

Wasmtime distributes the source and adapter under
[Apache-2.0 WITH LLVM-exception](../../../third_party/component-model-tests/test/wasmtime/LICENSE-Apache-2.0_WITH_LLVM-exception).

## `wasi_cli_0_2_12_exit_with_code.component.wasm`

This is a fixed, offline command fixture for the stable
`wasi:cli/exit@0.2.12.exit-with-code` function. Its guest lowers the imported
function, requests process exit code 7, and exports `wasi:cli/run@0.2.12`.

The component is handwritten against the official stable
[`exit.wit`](https://github.com/WebAssembly/WASI/blob/v0.2.12/proposals/cli/wit/exit.wit).

- Source: `wasi_cli_0_2_12_exit_with_code.component.wat`
  - Size: 1,068 bytes
  - SHA-256:
    `e743b5e0f5f88de84b9a4d00684b422f633ec06d97c1eef4fabb00b8b7d9b313`
- Generator: `wasm-tools 1.252.0 (d66d4364c 2026-06-12)`
- Generated component:
  - Size: 488 bytes
  - SHA-256:
    `5728b22e11f5187a874d40a21545120aae1e59430d55ac3f0b8ba69f7a8e0424`

Generate the component from the checked-in source at the repository root:

```sh
.toolchains/bin/wasm-tools parse \
  test/fixtures/wasi_preview2/wasi_cli_0_2_12_exit_with_code.component.wat \
  -o test/fixtures/wasi_preview2/wasi_cli_0_2_12_exit_with_code.component.wasm

.toolchains/bin/wasm-tools validate \
  test/fixtures/wasi_preview2/wasi_cli_0_2_12_exit_with_code.component.wasm
```

## `wasi_http_0_2_12_static_response.component.wasm`

This is a fixed, offline fixture for a stable `wasi:http/proxy` component. Its
`wasi:http/incoming-handler@0.2.12` export accepts an incoming request and
returns a successful response through the response outparam. The response has
status 200, no headers, no body, and no informational responses.

The component is handwritten against the official stable
[`wasi:http` 0.2.12 WIT](https://github.com/WebAssembly/WASI/tree/v0.2.12/proposals/http/wit).

- Source: `wasi_http_0_2_12_static_response.component.wat`
  - Size: 6,009 bytes
  - SHA-256:
    `e9654c2572a997c5d93f403d689355bb97cf6f7529213412b632bc5ea26bf109`
- Generator: `wasm-tools 1.252.0 (d66d4364c 2026-06-12)`
- Generated component:
  - Size: 2,487 bytes
  - SHA-256:
    `94bd7c8d6a10cca265f7237868135b37c7e76b9b12967d863fe988ad880f07a8`

Generate the component from the checked-in source at the repository root:

```sh
.toolchains/bin/wasm-tools parse \
  test/fixtures/wasi_preview2/wasi_http_0_2_12_static_response.component.wat \
  -o test/fixtures/wasi_preview2/wasi_http_0_2_12_static_response.component.wasm
```

## Toolchain-generated `wasi:http/proxy` fixtures

These fixtures exercise the component structure emitted by `wasm-tools`
against the complete official `wasi:http/proxy@0.2.12` world. In particular,
they retain the generated nested incoming-handler shim, imported resource type
arguments, canonical lowerings, and canonical lift with post-return.

- Official WIT: WebAssembly/WASI tag
  [`v0.2.12`](https://github.com/WebAssembly/WASI/tree/v0.2.12/proposals/http/wit)
- Source archive:
  [`v0.2.12.tar.gz`](https://github.com/WebAssembly/WASI/archive/refs/tags/v0.2.12.tar.gz)
  - Size: 248,811 bytes
  - SHA-256:
    `7b269a7bc7431133bc4eddfda2c80a097dae45c54b865dd6edc216c8042ed836`
- Generator: `wasm-tools 1.252.0 (d66d4364c 2026-06-12)`

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| `wasi_http_0_2_12_proxy_static_response.guest.wat` | 790 | `ee8950c386c0ab5ee123490182711a7a30bcb1ec0082576622ac13ac77b2df56` |
| `wasi_http_0_2_12_proxy_static_response.component.wasm` | 4,173 | `a6bdc7afb0f1b7ae16f27e1a1da3502f44cd9d12f7c01bbb3778008a646bc138` |
| `wasi_http_0_2_12_proxy_post_return_trap.guest.wat` | 806 | `10d6894c9c30cdc48317b66d4be02b600bf2521a1aace3f9dfc844a90eb07448` |
| `wasi_http_0_2_12_proxy_post_return_trap.component.wasm` | 4,174 | `4e5e9d40699d4142ec2fd426686af4312f5e3cd0f02fffc8958daf00393d7d42` |
| `wasi_http_0_2_12_proxy_unset_response.guest.wat` | 193 | `95e2e839bcfaf44ec4355a844a14b9cf08af31909bb9368bfda74b03e2615db1` |
| `wasi_http_0_2_12_proxy_unset_response.component.wasm` | 1,553 | `f0f6579792df2ebc8a8e361fa4a5125a8e100248635069c781aa1d9863e39e99` |

The static-response fixture returns status 200 with empty headers and no body.
The post-return fixture returns the same response, then traps in its canonical
post-return function. The unset-response fixture returns without setting the
required response outparam and must be rejected by the host.

Regenerate all three components from the repository root:

```sh
proxy_fixture_tmp=$(mktemp -d)
proxy_fixture_wit="$proxy_fixture_tmp/http-wit"

curl -L \
  https://github.com/WebAssembly/WASI/archive/refs/tags/v0.2.12.tar.gz \
  -o "$proxy_fixture_tmp/wasi-v0.2.12.tar.gz"
shasum -a 256 "$proxy_fixture_tmp/wasi-v0.2.12.tar.gz"
tar -xzf "$proxy_fixture_tmp/wasi-v0.2.12.tar.gz" \
  -C "$proxy_fixture_tmp"

mkdir -p "$proxy_fixture_wit/deps"
cp "$proxy_fixture_tmp/WASI-0.2.12/proposals/http/wit/handler.wit" \
  "$proxy_fixture_wit/handler.wit"
cp "$proxy_fixture_tmp/WASI-0.2.12/proposals/http/wit/proxy.wit" \
  "$proxy_fixture_wit/proxy.wit"
cp "$proxy_fixture_tmp/WASI-0.2.12/proposals/http/wit/types.wit" \
  "$proxy_fixture_wit/types.wit"

for dependency in cli clocks filesystem io random sockets; do
  ln -s \
    "$proxy_fixture_tmp/WASI-0.2.12/proposals/$dependency/wit" \
    "$proxy_fixture_wit/deps/$dependency"
done

for fixture_name in static_response post_return_trap unset_response; do
  fixture_prefix="wasi_http_0_2_12_proxy_$fixture_name"
  .toolchains/bin/wasm-tools component embed \
    "$proxy_fixture_wit" \
    --world proxy \
    "test/fixtures/wasi_preview2/$fixture_prefix.guest.wat" \
    -o "$proxy_fixture_tmp/$fixture_prefix.embedded.wasm"
  .toolchains/bin/wasm-tools component new \
    "$proxy_fixture_tmp/$fixture_prefix.embedded.wasm" \
    -o "test/fixtures/wasi_preview2/$fixture_prefix.component.wasm"
  .toolchains/bin/wasm-tools validate \
    "test/fixtures/wasi_preview2/$fixture_prefix.component.wasm"
done
```

The printed source-archive checksum must match the value above before using
the generated components.
