(module
  (import "a" "b::c" (global i32))
  (import "a::b" "c" (global i32))
  (func (export "first") (result i32) global.get 0)
  (func (export "second") (result i32) global.get 1)
)
