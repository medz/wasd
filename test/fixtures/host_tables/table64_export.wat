(module
  (import "host" "started" (func $started))
  (memory (import "host" "memory") 1)
  (table $values i64 1 4 funcref)
  (export "values" (table $values))
  (data (i32.const 0) "t")
  (func $start call $started)
  (start $start)
)
