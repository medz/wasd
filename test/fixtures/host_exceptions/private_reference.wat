;; .toolchains/bin/wasm-tools parse test/fixtures/host_exceptions/private_reference.wat -o test/fixtures/host_exceptions/private_reference.wasm
(module
  (import "host" "tick" (func $tick))
  (import "host" "source" (func $source))
  (tag $private (param anyref))
  (func (export "throw")
    call $tick ref.null any throw $private)
  (func (export "relay") call $tick call $source)
  (func (export "catch_is_null") (result i32)
    (block $caught (result anyref)
      (try_table (catch $private $caught) call $tick call $source)
      unreachable)
    ref.is_null)
)
