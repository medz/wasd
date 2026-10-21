(module
  (type $short (func (param funcref) (result funcref)))
  (type $explicit (func (param (ref null func)) (result (ref null func))))
  (import "host" "echo" (func $short_echo (type $short)))
  (import "host" "echo" (func $explicit_echo (type $explicit)))
  (func (export "run") (param funcref) (result funcref)
    local.get 0 call $short_echo call $explicit_echo))
