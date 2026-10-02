(module
  (import "host" "tick" (func $tick))
  (import "host" "value" (global $value (mut f32)))
  (export "value" (global $value))
  (func (export "get") (result f32) call $tick global.get $value)
  (func (export "set") (param f32) call $tick local.get 0 global.set $value)
(func (export "bits") (result i32) call $tick (i32.reinterpret_f32 (global.get $value))))
