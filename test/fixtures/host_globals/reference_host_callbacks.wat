(module
 (import "host" "tick" (func $tick))
 (import "host" "echo" (func $echo (param externref) (result externref)))
 (import "host" "fail" (func $fail))
 (global $calls (mut i32) (i32.const 0))
 (func (export "increment") (param i32) (result i32)
  call $tick
  global.get $calls i32.const 1 i32.add global.set $calls
  local.get 0 i32.const 1 i32.add)
 (func (export "roundtrip") (param externref) (result externref)
  local.get 0 call $echo)
 (func (export "fail") call $fail)
 (func (export "calls") (result i32) global.get $calls)
)
