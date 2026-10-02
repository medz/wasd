(module
  (import "a" "b::c" (global i32))
  (func (export "get") (result i32) global.get 0)
)
