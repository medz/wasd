(component
  (type $http-types (instance
    (export "fields" (type $fields (sub resource)))
    (export "request" (type $request (sub resource)))
    (export "response" (type $response (sub resource)))
    (type $error-code (variant (case "internal-error")))
    (export "error-code" (type $public-error (eq $error-code)))
    (type $get-headers-type
      (func (param "self" (borrow $request)) (result (own $fields))))
    (export "[method]request.get-headers" (func (type $get-headers-type)))
    (type $trailers-result (result (option (own $fields)) (error $public-error)))
    (type $trailers-future (future $trailers-result))
    (type $transmission-result (result (error $public-error)))
    (type $transmission-future (future $transmission-result))
    (type $new-type (func
      (param "headers" (own $fields))
      (param "contents" (option (stream u8)))
      (param "trailers" $trailers-future)
      (result (tuple (own $response) $transmission-future))))
    (export "[static]response.new" (func (type $new-type)))
    (type $status-type (func
      (param "self" (borrow $response)) (param "status-code" u16)
      (result (result))))
    (export "[method]response.set-status-code" (func (type $status-type)))))
  (import "wasi:http/types@0.3.1" (instance $types (type $http-types)))
  (alias export $types "fields" (type $fields))
  (alias export $types "request" (type $request))
  (alias export $types "response" (type $response))
  (alias export $types "error-code" (type $error-code))
  (alias export $types "[method]request.get-headers" (func $get-headers))
  (alias export $types "[static]response.new" (func $new-response))
  (alias export $types "[method]response.set-status-code" (func $set-status))

  (core module $memory-module (memory (export "memory") 1))
  (core instance $memory-instance (instantiate $memory-module))
  (alias core export $memory-instance "memory" (core memory $memory))
  (core func $get-headers-core (canon lower (func $get-headers)))
  (core func $new-response-core
    (canon lower (func $new-response) (memory $memory)))
  (core func $set-status-core (canon lower (func $set-status)))
  (core func $drop-request (canon resource.drop $request))
  (core func $drop-fields (canon resource.drop $fields))
  (type $trailers-result (result (option (own $fields)) (error $error-code)))
  (type $trailers-future (future $trailers-result))
  (core func $future-new (canon future.new $trailers-future))
  (core func $future-write
    (canon future.write $trailers-future (memory $memory) async))
  (type $transmission-result (result (error $error-code)))
  (type $transmission-future (future $transmission-result))
  (core func $drop-transmission
    (canon future.drop-readable $transmission-future))
  (type $handle-result (result (own $response) (error $error-code)))
  (canon task.return (result $handle-result) (core func $task-return))

  (core module $main
    (import "" "memory" (memory 1))
    (import "" "get-headers" (func $get-headers (param i32) (result i32)))
    (import "" "new-response" (func $new-response (param i32 i32 i32 i32 i32)))
    (import "" "set-status" (func $set-status (param i32 i32) (result i32)))
    (import "" "drop-request" (func $drop-request (param i32)))
    (import "" "drop-fields" (func $drop-fields (param i32)))
    (import "" "future.new" (func $future-new (result i64)))
    (import "" "future.write" (func $future-write (param i32 i32) (result i32)))
    (import "" "drop-transmission" (func $drop-transmission (param i32)))
    (import "" "task.return" (func $task-return (param i32 i32)))
    (func (export "handle") (param $request i32) (result i32)
      (local $pair i64) (local $headers i32) (local $response i32)
      local.get $request
      call $get-headers
      local.set $headers
      call $future-new
      local.tee $pair
      i64.const 32
      i64.shr_u
      i32.wrap_i64
      i32.const 0
      call $future-write
      drop
      local.get $headers
      i32.const 0
      i32.const 0
      local.get $pair
      i32.wrap_i64
      i32.const 32
      call $new-response
      i32.const 32
      i32.load
      local.tee $response
      i32.const 204
      call $set-status
      drop
      i32.const 36
      i32.load
      call $drop-transmission
      local.get $request
      call $drop-request
      i32.const 0
      local.get $response
      call $task-return
      i32.const 0)
    (func (export "handle-error") (param $request i32) (result i32)
      local.get $request
      call $get-headers
      call $drop-fields
      local.get $request
      call $drop-request
      i32.const 1
      i32.const 0
      call $task-return
      i32.const 0)
    (func (export "callback") (param i32 i32 i32) (result i32)
      unreachable))
  (core instance $builtins
    (export "memory" (memory $memory))
    (export "get-headers" (func $get-headers-core))
    (export "new-response" (func $new-response-core))
    (export "set-status" (func $set-status-core))
    (export "drop-request" (func $drop-request))
    (export "drop-fields" (func $drop-fields))
    (export "future.new" (func $future-new))
    (export "future.write" (func $future-write))
    (export "drop-transmission" (func $drop-transmission))
    (export "task.return" (func $task-return)))
  (core instance $main-instance
    (instantiate $main (with "" (instance $builtins))))
  (alias core export $main-instance "handle" (core func $handle-core))
  (alias core export $main-instance "handle-error" (core func $error-core))
  (alias core export $main-instance "callback" (core func $callback-core))
  (type $handle-type (func async
    (param "request" (own $request)) (result $handle-result)))
  (func $handle (type $handle-type)
    (canon lift (core func $handle-core) async (callback $callback-core)))
  (func $handle-error (type $handle-type)
    (canon lift (core func $error-core) async (callback $callback-core)))
  (instance $handler
    (export "request" (type $request))
    (export "response" (type $response))
    (export "error-code" (type $error-code))
    (export "handle" (func $handle)))
  (instance $error-handler
    (export "request" (type $request))
    (export "response" (type $response))
    (export "error-code" (type $error-code))
    (export "handle" (func $handle-error)))
  ;; EXPORTS
  (export "wasi:http/handler@0.3.1" (instance $handler)))
