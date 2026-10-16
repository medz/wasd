;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/i32.wat -o test/fixtures/host_tags/i32.wasm
(module
  (import "host" "tick" (func $tick))
  (import "host" "tag" (tag $tag (param i32)))
  (export "tag" (tag $tag))
  (export "alias" (tag $tag))
  (func (export "catch") (param i32) (result i32)
    (block $caught (result i32)
      (try_table (catch $tag $caught)
        call $tick local.get 0 throw $tag)
      unreachable))
)
