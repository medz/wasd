(module
 (import "host" "f" (func $f (param i64) (result i32)))
 (import "host" "started" (func $started))
 (global (export "reference") funcref (ref.func $f))
 (start $started))
