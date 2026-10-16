;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/funcref_export.wat -o test/fixtures/host_tags/funcref_export.wasm
(module (tag (export "tag") (param funcref)))
