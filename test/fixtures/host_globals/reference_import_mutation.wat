(module
  (import "host" "relay" (func $relay (param i32) (result i32)))
  (import "host" "tick" (func $tick))
  (func (export "call") (param i32) (result i32)
    call $tick local.get 0 call $relay))
