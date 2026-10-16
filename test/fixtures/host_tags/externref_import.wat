;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/externref_import.wat -o test/fixtures/host_tags/externref_import.wasm
(module (import "host" "tag" (tag (param externref))))
