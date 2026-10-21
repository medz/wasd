(module
  (type $short (func (param externref) (result externref)))
  (type $explicit (func (param (ref null extern)) (result (ref null extern))))
  (import "host" "echo" (func $short_echo (type $short)))
  (import "host" "echo" (func $explicit_echo (type $explicit)))
  (func (export "run") (param externref) (result externref)
    local.get 0 call $short_echo call $explicit_echo))
