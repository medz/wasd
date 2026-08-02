(module
  (import "wasi:http/types@0.2.12" "[constructor]fields"
    (func $new_fields (result i32)))
  (import "wasi:http/types@0.2.12" "[constructor]outgoing-response"
    (func $new_response (param i32) (result i32)))
  (import "wasi:http/types@0.2.12" "[static]response-outparam.set"
    (func $set_response
      (param i32 i32 i32 i32 i64 i32 i32 i32 i32)))

  (memory (export "memory") 1)

  (func (export "wasi:http/incoming-handler@0.2.12#handle")
    (param $request i32) (param $response_out i32)
    local.get $response_out
    i32.const 0
    call $new_fields
    call $new_response
    i32.const 0
    i64.const 0
    i32.const 0
    i32.const 0
    i32.const 0
    i32.const 0
    call $set_response)

  (func (export "cabi_post_wasi:http/incoming-handler@0.2.12#handle")
    unreachable)
)
