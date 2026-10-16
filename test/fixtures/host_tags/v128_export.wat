;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/v128_export.wat -o test/fixtures/host_tags/v128_export.wasm
(module (tag (export "tag") (param v128)))
