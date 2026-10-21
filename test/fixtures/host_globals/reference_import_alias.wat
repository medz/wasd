(module
 (import "host" "f" (func $f (param i32) (result i32)))
 (global (export "reference") funcref (ref.func $f))
 (export "direct" (func $f))
 (func (export "get") (result funcref) ref.func $f)
 (func (export "call") (param i32) (result i32) local.get 0 call $f))
