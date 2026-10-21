(module
  (import "host" "started" (func $started))
  (memory (import "host" "memory") 1)
  (table $values 1 4 (ref null struct))
  (export "values" (table $values))
  (data (i32.const 0) "t")
  (func $start call $started)
  (start $start)
)
