;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/f32.wat -o test/fixtures/host_tags/f32.wasm
(module
  (import "host" "tick" (func $tick))
  (import "host" "tag" (tag $tag (param f32)))
  (export "tag" (tag $tag))
  (export "alias" (tag $tag))
  (func (export "catch") (param f32) (result f32)
    (block $caught (result f32)
      (try_table (catch $tag $caught)
        call $tick local.get 0 throw $tag)
      unreachable))
)
