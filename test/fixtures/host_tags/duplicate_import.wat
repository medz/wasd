;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/duplicate_import.wat -o test/fixtures/host_tags/duplicate_import.wasm
(module
  (import "host" "tag" (tag (param externref)))
  (import "host" "tag" (tag (param i32)))
)
