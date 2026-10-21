(module
 (import "host" "tick" (func $tick))
 (import "host" "value" (global $value externref))
 (export "value" (global $value))
 (func (export "get") (result externref) call $tick global.get $value)
)
