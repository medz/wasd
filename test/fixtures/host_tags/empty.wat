;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/empty.wat -o test/fixtures/host_tags/empty.wasm
(module
  (import "host" "tick" (func $tick))
  (import "host" "tag" (tag $tag ))
  (export "tag" (tag $tag))
  (export "alias" (tag $tag))
  (func (export "catch")
    (block $caught
      (try_table (catch $tag $caught)
        call $tick  throw $tag)
      unreachable))
)
