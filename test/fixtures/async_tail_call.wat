;; wasm-tools parse test/fixtures/async_tail_call.wat -o test/fixtures/async_tail_call.wasm
(module
  (type $result (func (result i32)))
  (tag $error)
  (func $throw (export "throw") (type $result) (throw $error))
  (table 1 funcref)
  (elem (i32.const 0) $throw)
  (func (export "call") (type $result)
    (block $caught
      (try_table (catch $error $caught)
        (return (call $throw))))
    (i32.const 99))
  (func (export "tail") (type $result)
    (block $caught
      (try_table (catch $error $caught)
        (return_call $throw)))
    (i32.const 99))
  (func (export "tail-ref") (type $result)
    (block $caught
      (try_table (catch $error $caught)
        (return_call_ref $result (ref.func $throw))))
    (i32.const 99))
  (func (export "tail-indirect") (type $result)
    (block $caught
      (try_table (catch $error $caught)
        (return_call_indirect (type $result) (i32.const 0))))
    (i32.const 99))
)
