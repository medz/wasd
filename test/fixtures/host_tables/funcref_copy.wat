(module
  (table $source (import "host" "source") 1 4 funcref)
  (table $target (import "host" "target") 1 4 funcref)
  (func (export "copy")
    i32.const 0 i32.const 0 i32.const 1 table.copy $target $source)
)
