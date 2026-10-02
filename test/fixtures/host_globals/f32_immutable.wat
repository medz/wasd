(module
  (import "host" "tick" (func $tick))
  (import "host" "value" (global $value f32))
  (export "value" (global $value))
  (func (export "get") (result f32) call $tick global.get $value)

)
