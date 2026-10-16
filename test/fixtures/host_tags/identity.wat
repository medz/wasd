;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/identity.wat -o test/fixtures/host_tags/identity.wasm
(module
  (import "host" "tick" (func $tick))
  (import "host" "first" (tag $first (param i32)))
  (import "host" "second" (tag $second (param i32)))
  (export "first" (tag $first))
  (export "second" (tag $second))
  (func (export "catch") (param i32) (result i32)
    (block $caught (result i32)
      (try_table (catch $second $caught)
        call $tick local.get 0 throw $first)
      unreachable))
)
