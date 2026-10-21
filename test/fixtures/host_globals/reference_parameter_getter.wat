(module
  (type $unary (func (param i32) (result i32)))
  (table 1 funcref)
  (func (export "stash") (param funcref)
    i32.const 0
    local.get 0
    table.set)
  (func (export "call") (param i32) (result i32)
    local.get 0
    i32.const 0
    call_indirect (type $unary))  (func $hidden_stash (param funcref)
    i32.const 0 local.get 0 table.set)
  (elem declare func $hidden_stash)
  (func (export "reference") (result funcref) ref.func $hidden_stash)
)
