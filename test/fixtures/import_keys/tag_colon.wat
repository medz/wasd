(module (import "a" "b::c" (tag $first (param i32))) (import "a::b" "c" (tag $second (param i32))) (export "first" (tag $first)) (export "second" (tag $second)))
