(module
 (global $value (mut externref) (ref.null extern))
 (export "value" (global $value))
 (func (export "get") (result externref) global.get $value)
 (func (export "set") (param externref) local.get 0 global.set $value)
)
