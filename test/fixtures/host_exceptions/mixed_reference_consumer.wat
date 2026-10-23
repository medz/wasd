;; .toolchains/bin/wasm-tools parse test/fixtures/host_exceptions/mixed_reference_consumer.wat -o test/fixtures/host_exceptions/mixed_reference_consumer.wasm
(module
  (import "host" "source" (func $source))
  (import "host" "tag" (tag $tag (param i32 externref f64)))
  (export "tag" (tag $tag))
  (func (export "catch") (result i32 externref f64)
    (block $caught (result i32 externref f64)
      (try_table (catch $tag $caught) call $source)
      unreachable))
)
