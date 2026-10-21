(module
 (import "host" "value" (global (mut funcref)))
 (import "host" "started" (func $started))
 (memory (import "host" "memory") 1)
 (data (i32.const 0) "x")
 (func $start call $started) (start $start)
)
