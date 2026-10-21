(module
 (type $unary (func (param i32) (result i32)))
 (import "host" "tick" (func $tick))
 (import "host" "value" (global $value (mut funcref)))
 (table 1 funcref)
 (export "value" (global $value))
 (func (export "get") (result funcref) call $tick global.get $value)
 (func (export "set") (param funcref) call $tick local.get 0 global.set $value)
 (func (export "clear") call $tick ref.null func global.set $value)
 (func (export "call") (param i32) (result i32)
  call $tick i32.const 0 global.get $value table.set
  local.get 0 i32.const 0 call_indirect (type $unary))
)
