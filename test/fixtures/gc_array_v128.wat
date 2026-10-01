;; Regenerate with wasm-tools 1.254.0:
;; wasm-tools parse test/fixtures/gc_array_v128.wat -o test/fixtures/gc_array_v128.wasm
(module
  (type $array (array (mut v128)))
  (data $bytes "\ff\00\01\02\03\04\05\06\07\08\09\0a\0b\0c\0d\0e\0f\10\11\12\13\14\15\16\17\18\19\1a\1b\1c\1d\1e\1f")
  (global $target (ref $array)
    (array.new $array (v128.const i32x4 0 0 0 0) (i32.const 3)))
  (func (export "new") (param $offset i32) (param $length i32) (param $index i32) (result v128)
    (array.get $array
      (array.new_data $array $bytes (local.get $offset) (local.get $length))
      (local.get $index)))
  (func (export "init") (param $destination i32) (param $source i32) (param $length i32)
    (array.init_data $array $bytes (global.get $target)
      (local.get $destination) (local.get $source) (local.get $length)))
  (func (export "get") (param $index i32) (result v128)
    (array.get $array (global.get $target) (local.get $index)))
  (func (export "drop") (data.drop $bytes))
  (func (export "new-empty") (param $offset i32) (result i32)
    (array.len (array.new_data $array $bytes (local.get $offset) (i32.const 0))))
)
