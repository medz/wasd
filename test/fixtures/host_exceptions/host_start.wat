;; .toolchains/bin/wasm-tools parse test/fixtures/host_exceptions/host_start.wat -o test/fixtures/host_exceptions/host_start.wasm
(module
  (import "host" "tick" (func $tick))
  (func $start call $tick)
  (start $start)
)
