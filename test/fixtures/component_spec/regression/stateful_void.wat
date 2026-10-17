(component
  (core module $m
    (global $count (mut i32) (i32.const 0))
    (func (export "bump") (param i32)
      (global.set $count (i32.add (global.get $count) (local.get 0))))
    (func (export "count") (result i32) (global.get $count)))
  (core instance $i (instantiate $m))
  (func (export "bump") (param "amount" u32)
    (canon lift (core func $i "bump")))
  (func (export "count") (result u32)
    (canon lift (core func $i "count"))))
