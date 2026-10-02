(module
  (import "host" "tick" (func $tick))
  (import "host" "value" (global $value i32))
  (export "value" (global $value))
  (func (export "get") (result i32) call $tick global.get $value)

)
