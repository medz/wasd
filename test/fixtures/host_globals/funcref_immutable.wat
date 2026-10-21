(module
 (type $unary (func (param i32) (result i32)))
 (import "host" "value" (global $value funcref))
 (table 1 funcref)
 (export "value" (global $value))
 (func (export "get") (result funcref) global.get $value)
 (func (export "call") (param i32) (result i32)
  i32.const 0 global.get $value table.set
  local.get 0 i32.const 0 call_indirect (type $unary))
)
