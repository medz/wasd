(module
  (import "host" "tick" (func $tick))
  (import "host" "value" (global $value i64))
  (export "value" (global $value))
  (func (export "get") (result i64) call $tick global.get $value)
  
(func (export "getLo") (result i32) call $tick (i32.wrap_i64 (global.get $value)))
(func (export "getHi") (result i32) call $tick (i32.wrap_i64 (i64.shr_u (global.get $value) (i64.const 32))))
)