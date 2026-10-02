(module
 (func (export "b::fn") (result i32) i32.const 11)
 (memory (export "b::mem") 1 3)
 (table (export "b::table") 1 3 funcref)
 (global (export "b::global") i32 (i32.const 31))
 (tag (export "b::tag") (param i32)))
(register "a")
(module
 (func (export "fn") (result i32) i32.const 22)
 (memory (export "mem") 2 3)
 (table (export "table") 2 3 funcref)
 (global (export "global") i32 (i32.const 32))
 (tag (export "tag") (param i32)))
(register "a::b")
(module
 (import "a" "b::fn" (func $f1 (result i32)))
 (import "a::b" "fn" (func $f2 (result i32)))
 (import "a" "b::mem" (memory $m1 1 3))
 (import "a::b" "mem" (memory $m2 2 3))
 (import "a" "b::table" (table $t1 1 3 funcref))
 (import "a::b" "table" (table $t2 2 3 funcref))
 (import "a" "b::global" (global $g1 i32))
 (import "a::b" "global" (global $g2 i32))
 (import "a" "b::tag" (tag $tag1 (param i32)))
 (import "a::b" "tag" (tag $tag2 (param i32)))
 (func $checktag (result i32)
  (block $first (result i32)
   (block $second (result i32)
    (try_table (catch $tag2 $second) (catch $tag1 $first)
      i32.const 7 throw $tag1)
    unreachable)
   drop i32.const 1 return)
  drop i32.const 0)
 (func (export "run") (result i32)
  call $f1 i32.const 11 i32.ne if unreachable end
  call $f2 i32.const 22 i32.ne if unreachable end
  memory.size $m1 i32.const 1 i32.ne if unreachable end
  memory.size $m2 i32.const 2 i32.ne if unreachable end
  table.size $t1 i32.const 1 i32.ne if unreachable end
  table.size $t2 i32.const 2 i32.ne if unreachable end
  global.get $g1 i32.const 31 i32.ne if unreachable end
  global.get $g2 i32.const 32 i32.ne if unreachable end
  call $checktag if unreachable end
  i32.const 0))
(assert_return (invoke "run") (i32.const 0))
