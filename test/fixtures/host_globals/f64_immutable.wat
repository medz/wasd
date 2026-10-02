(module
  (import "host" "tick" (func $tick))
  (import "host" "value" (global $value f64))
  (export "value" (global $value))
  (func (export "get") (result f64) call $tick global.get $value)

)
