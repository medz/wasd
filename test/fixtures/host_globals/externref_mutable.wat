(module
 (import "host" "tick" (func $tick))
 (import "host" "value" (global $value (mut externref)))
 (export "value" (global $value))
 (func (export "get") (result externref) call $tick global.get $value)
 (func (export "set") (param externref) call $tick local.get 0 global.set $value)
 (func (export "clear") call $tick ref.null extern global.set $value)
)
