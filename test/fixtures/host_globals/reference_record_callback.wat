(module
 (import "host" "value" (global $value (mut externref)))
 (import "host" "echo" (func $echo (param externref) (result externref)))
 (global $copy (mut externref) (ref.null extern))
 (export "copy" (global $copy))
 (func (export "run") global.get $value call $echo global.set $copy)
)
