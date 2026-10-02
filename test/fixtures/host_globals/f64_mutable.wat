(module
  (import "host" "tick" (func $tick))
  (import "host" "value" (global $value (mut f64)))
  (export "value" (global $value))
  (func (export "get") (result f64) call $tick global.get $value)
  (func (export "set") (param f64) call $tick local.get 0 global.set $value)
(func (export "bits") (result i64) call $tick (i64.reinterpret_f64 (global.get $value))))
