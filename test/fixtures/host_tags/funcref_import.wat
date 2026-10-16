;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/funcref_import.wat -o test/fixtures/host_tags/funcref_import.wasm
(module (import "host" "tag" (tag (param funcref))))
