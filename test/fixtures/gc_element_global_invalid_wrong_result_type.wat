(module
  (type $a (array (mut f32)))
  (type $other (array (mut f64)))
  (global $seed f32 (f32.const 1))
  (elem (ref $other) (array.new $a (global.get $seed) (i32.const 1))))
