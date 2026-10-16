;; .toolchains/bin/wasm-tools parse test/fixtures/host_tags/exported_payloads.wat -o test/fixtures/host_tags/exported_payloads.wasm
(module
  (tag (export "empty"))
  (tag (export "i32") (param i32))
  (tag (export "i64") (param i64))
  (tag (export "f32") (param f32))
  (tag (export "f64") (param f64))
  (tag (export "mixed") (param i32 i64 f32 f64))
)
