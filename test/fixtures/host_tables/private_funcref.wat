(module
  (type $unary (func (param i32) (result i32)))
  (import "host" "tick" (func $tick))
  (table 1 funcref)
  (func $increment (type $unary) local.get 0 i32.const 1 i32.add)
  (elem (i32.const 0) $increment)
  (func (export "run") (param i32) (result i32)
    call $tick local.get 0 i32.const 0 call_indirect (type $unary))
)
