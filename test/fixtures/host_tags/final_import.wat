;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/final_import.wat -o test/fixtures/host_tags/final_import.wasm
(module
  (type $tag (sub final (func (param i32))))
  (import "host" "tag" (tag (type $tag)))
)
