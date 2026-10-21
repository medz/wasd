(module
  (table $values 2 4 externref)
  (export "values" (table $values))
  (export "alias" (table $values))
  (func (export "get") (param i32) (result externref) local.get 0 table.get $values)
  (func (export "set") (param i32 externref) local.get 0 local.get 1 table.set $values)
)
