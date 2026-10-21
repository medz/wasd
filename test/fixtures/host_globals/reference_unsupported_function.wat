(module
  (func (export "unused") (param (ref extern)) (result (ref extern))
    local.get 0)
  (func (export "answer") (result i32) i32.const 42))
