;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/provider.wat -o test/fixtures/host_tags/provider.wasm
(module
  (import "host" "tick" (func $tick))
  (tag $tag (param i32))
  (export "tag" (tag $tag))
  (export "alias" (tag $tag))
  (func (export "throw") (param i32)
    call $tick local.get 0 throw $tag)
)
