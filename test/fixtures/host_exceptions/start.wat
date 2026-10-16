;; .toolchains/bin/wasm-tools parse test/fixtures/host_exceptions/start.wat -o test/fixtures/host_exceptions/start.wasm
(module
  (import "host" "tag" (tag $tag (param i32)))
  (func $start i32.const 19 throw $tag)
  (start $start)
)
