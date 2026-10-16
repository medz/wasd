;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/externref_export.wat -o test/fixtures/host_tags/externref_export.wasm
(module (tag (export "tag") (param externref)))
