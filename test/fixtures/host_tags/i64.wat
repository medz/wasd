;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/i64.wat -o test/fixtures/host_tags/i64.wasm
(module
  (import "host" "tick" (func $tick))
  (import "host" "tag" (tag $tag (param i64)))
  (export "tag" (tag $tag))
  (export "alias" (tag $tag))
  (func (export "catch") (param i64) (result i64)
    (block $caught (result i64)
      (try_table (catch $tag $caught)
        call $tick local.get 0 throw $tag)
      unreachable))
)
