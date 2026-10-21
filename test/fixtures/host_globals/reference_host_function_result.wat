(module
  (type $unary (func (param i32) (result i32)))
  (import "host" "provide" (func $provide (result funcref)))
  (table 1 funcref)
  (func (export "stash") i32.const 0 call $provide table.set)
  (func (export "call") (param i32) (result i32)
    local.get 0 i32.const 0 call_indirect (type $unary))
  (func (export "direct") (param i32) (result i32)
    i32.const 0 call $provide table.set
    local.get 0 i32.const 0 call_indirect (type $unary))  (func $hidden (param i32) (result i32)
    i32.const 0 call $provide table.set
    local.get 0 i32.const 0 call_indirect (type $unary))
  (global (export "reference") funcref (ref.func $hidden))
)
