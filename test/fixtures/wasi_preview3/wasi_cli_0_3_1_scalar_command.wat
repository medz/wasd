(component
  (type $clock-interface (instance
    (type $resolution-type (func (result u64)))
    (export "get-resolution" (func (type $resolution-type)))))
  (import "wasi:clocks/monotonic-clock@0.3.1"
    (instance $clock (type $clock-interface)))
  (alias export $clock "get-resolution" (func $get-resolution))
  (core func $resolution-core (canon lower (func $get-resolution)))

  (type $exit-interface (instance
    (type $exit-type (func (param "status-code" u8)))
    (export "exit-with-code" (func (type $exit-type)))))
  (import "wasi:cli/exit@0.3.1" (instance $exit (type $exit-interface)))
  (alias export $exit "exit-with-code" (func $exit-with-code))
  (core func $exit-core (canon lower (func $exit-with-code)))

  (type $run-result (result))
  (canon task.return (result $run-result) (core func $task-return))
  (core module $main
    (import "" "get-resolution" (func $get-resolution (result i64)))
    (import "" "exit-with-code" (func $exit (param i32)))
    (import "" "task.return" (func $task-return (param i32)))
    (func (export "run") (result i32)
      call $get-resolution
      i64.const 1000
      i64.ne
      if unreachable end
      ;; EXIT
      i32.const 0
      call $task-return
      i32.const 0)
    (func (export "legacy-run") (result i32)
      i32.const 1
      call $task-return
      i32.const 0)
    (func (export "callback") (param i32 i32 i32) (result i32)
      unreachable))
  (core instance $builtins
    (export "get-resolution" (func $resolution-core))
    (export "exit-with-code" (func $exit-core))
    (export "task.return" (func $task-return)))
  (core instance $main-instance
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main-instance "run" (core func $run-core))
  (alias core export $main-instance "legacy-run" (core func $legacy-core))
  (alias core export $main-instance "callback" (core func $callback-core))
  (func $run async (result $run-result)
    (canon lift (core func $run-core) async (callback $callback-core)))
  (func $legacy-run async (result $run-result)
    (canon lift (core func $legacy-core) async (callback $callback-core)))
  (instance $run-instance (export "run" (func $run)))
  (instance $legacy-instance (export "run" (func $legacy-run)))
  ;; EXPORTS
  (export "wasi:cli/run@0.3.1" (instance $run-instance)))
