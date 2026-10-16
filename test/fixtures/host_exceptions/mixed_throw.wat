;; .toolchains/bin/wasm-tools parse test/fixtures/host_exceptions/mixed_throw.wat -o test/fixtures/host_exceptions/mixed_throw.wasm
(module
  (import "host" "tick" (func $tick))
  (tag $tag (param i32 i64 f32 f64))
  (export "tag" (tag $tag))
  (export "alias" (tag $tag))
  (func (export "throw") (param i32 i64 f32 f64)
    call $tick
    local.get 0 local.get 1 local.get 2 local.get 3 throw $tag)
)
