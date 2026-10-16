;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/nonfinal_import.wat -o test/fixtures/host_tags/nonfinal_import.wasm
(module
  (type $tag (sub (func (param i32))))
  (import "host" "tag" (tag (type $tag)))
)
