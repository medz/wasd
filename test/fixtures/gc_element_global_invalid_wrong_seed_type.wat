(module
  (type $a (array (mut f32)))
  (type $other (array (mut f64)))
  (global $seed f64 (f64.const 1))
  (elem (ref $a) (array.new $a (global.get $seed) (i32.const 1))))
