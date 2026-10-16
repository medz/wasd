(component
  (core module $m
    (memory (export "mem") 1)
    (global $next (mut i32) (i32.const 97))
    (func (export "next") (result i32)
      (i32.store (i32.const 0) (i32.const 8))
      (i32.store (i32.const 4) (i32.const 1))
      (i32.store8 (i32.const 8) (global.get $next))
      (global.set $next (i32.add (global.get $next) (i32.const 1)))
      (i32.const 0)))
  (core instance $i (instantiate $m))
  (func (export "next") (result string)
    (canon lift (core func $i "next") (memory (core memory $i "mem")))))
