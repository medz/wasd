(component
  (type $exit-interface (instance
    (type $exit-with-code-type (func (param "status-code" u8)))
    (export "exit-with-code" (func (type $exit-with-code-type)))))
  (import "wasi:cli/exit@0.2.12"
    (instance $exit (type $exit-interface)))
  (alias export $exit "exit-with-code" (func $exit-with-code))
  (core func $exit-with-code-core
    (canon lower (func $exit-with-code)))
  (core instance $exit-core
    (export "exit-with-code" (func $exit-with-code-core)))

  (core module $main
    (import "exit" "exit-with-code"
      (func $exit-with-code (param i32)))
    (func (export "run") (result i32)
      i32.const 7
      call $exit-with-code
      i32.const 0))
  (core instance $main-instance
    (instantiate $main (with "exit" (instance $exit-core))))
  (alias core export $main-instance "run" (core func $run-core))

  (type $run-type (func (result (result))))
  (func $run (type $run-type) (canon lift (core func $run-core)))
  (instance $run-interface (export "run" (func $run)))
  (export "wasi:cli/run@0.2.12" (instance $run-interface))
)
