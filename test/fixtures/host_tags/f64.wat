;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/f64.wat -o test/fixtures/host_tags/f64.wasm
(module
  (import "host" "tick" (func $tick))
  (import "host" "tag" (tag $tag (param f64)))
  (export "tag" (tag $tag))
  (export "alias" (tag $tag))
  (func (export "catch") (param f64) (result f64)
    (block $caught (result f64)
      (try_table (catch $tag $caught)
        call $tick local.get 0 throw $tag)
      unreachable))
)
