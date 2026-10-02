(module
  (type $a (array (mut f32)))
  (type $other (array (mut f64)))
  (global $seed f32 (f32.const 1))
  (elem (ref $a) (array.new $a (global.get 42) (i32.const 1))))
