;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/mixed.wat -o test/fixtures/host_tags/mixed.wasm
(module
  (import "host" "tick" (func $tick))
  (import "host" "tag" (tag $tag (param i32 i64 f32 f64)))
  (export "tag" (tag $tag))
  (export "alias" (tag $tag))
  (func (export "catch") (param i32 i64 f32 f64) (result i32 i64 f32 f64)
    (block $caught (result i32 i64 f32 f64)
      (try_table (catch $tag $caught)
        call $tick local.get 0 local.get 1 local.get 2 local.get 3 throw $tag)
      unreachable))
)
