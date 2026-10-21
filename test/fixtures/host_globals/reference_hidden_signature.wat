(module
 (func $target)
 (elem declare func $target)
 (global $calls (mut i32) (i32.const 0))
 (export "calls" (global $calls))
 (func $hidden (result (ref func))
  global.get $calls i32.const 1 i32.add global.set $calls
  ref.func $target)
 (global (export "reference") funcref (ref.func $hidden))
)
