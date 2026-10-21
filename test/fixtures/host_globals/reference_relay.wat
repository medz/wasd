(module
  (type $unary (func (param i32) (result i32)))
  (import "host" "value" (global $value (mut funcref)))
  (table 1 funcref)
  (func (export "call") (param i32) (result i32)
    i32.const 0
    global.get $value
    table.set
    local.get 0
    i32.const 0
    call_indirect (type $unary))  (func (export "get") (result funcref) global.get $value)
  (func (export "set") (param funcref) local.get 0 global.set $value)
  (func (export "clear") ref.null func global.set $value)
  (export "value" (global $value))
)
