;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/unsupported_export_start.wat -o test/fixtures/host_tags/unsupported_export_start.wasm
(module
  (import "host" "tick" (func $tick))
  (tag (export "tag") (param v128))
  (start $tick)
)
