(module
  (type $unary (func (param i32) (result i32)))
  (import "host" "value" (global $value (mut funcref)))
  (table 1 funcref)
  (func $stash (export "stash")
    i32.const 0
    global.get $value
    table.set
    ref.null func
    global.set $value)
  (func (export "call") (param i32) (result i32)
    local.get 0
    i32.const 0
    call_indirect (type $unary))
  (start $stash))
