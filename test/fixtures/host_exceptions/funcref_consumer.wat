;; .toolchains/bin/wasm-tools parse test/fixtures/host_exceptions/funcref_consumer.wat -o test/fixtures/host_exceptions/funcref_consumer.wasm
(module
  (type $unary (func (param i32) (result i32)))
  (import "host" "source" (func $source))
  (import "host" "tag" (tag $tag (param funcref)))
  (export "tag" (tag $tag))
  ;; The table is private; only the tag carries a reference across the boundary.
  (table 1 funcref)
  (func (export "catch_call") (param i32) (result i32)
    i32.const 0
    (block $caught (result funcref)
      (try_table (catch $tag $caught) call $source)
      unreachable)
    table.set
    local.get 0 i32.const 0 call_indirect (type $unary))
)
