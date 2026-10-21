(module
  (type $unary (func (param i32) (result i32)))
  (import "host" "tick" (func $tick))
  (table $values (import "host" "table") 1 4 funcref)
  (func (export "call") (param i32 i32) (result i32)
    call $tick local.get 1 local.get 0 call_indirect (type $unary))
)
