(module
  (table $values (import "host" "table") 2 4 externref)
  (export "values" (table $values))
  (export "alias" (table $values))
  (func (export "get") (param i32) (result externref) local.get 0 table.get $values)
  (func (export "set") (param i32 externref) local.get 0 local.get 1 table.set $values)
  (func (export "grow") (param i32 externref) (result i32) local.get 1 local.get 0 table.grow $values)
  (func (export "size") (result i32) table.size $values)
)
