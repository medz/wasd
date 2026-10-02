(module
  (import "host" "tick" (func $tick))
  (import "host" "value" (global $value (mut i32)))
  (export "value" (global $value))
  (func (export "get") (result i32) call $tick global.get $value)
  (func (export "set") (param i32) call $tick local.get 0 global.set $value)
)
