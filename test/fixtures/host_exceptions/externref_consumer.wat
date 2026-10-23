;; .toolchains/bin/wasm-tools parse test/fixtures/host_exceptions/externref_consumer.wat -o test/fixtures/host_exceptions/externref_consumer.wasm
(module
  (import "host" "source" (func $source))
  (import "host" "tag" (tag $tag (param externref)))
  (export "tag" (tag $tag))
  (func (export "catch") (result externref)
    (block $caught (result externref)
      (try_table (catch $tag $caught) call $source)
      unreachable))
)
