(module (global $value (mut f64) (f64.const nan:0x123456789abc)) (export "value" (global $value)) (func (export "bits") (result i64) (i64.reinterpret_f64 (global.get $value))))
