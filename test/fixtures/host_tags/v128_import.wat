;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/v128_import.wat -o test/fixtures/host_tags/v128_import.wasm
(module (import "host" "tag" (tag (param v128))))
