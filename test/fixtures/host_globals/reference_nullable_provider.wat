;; wasm-tools parse canonicalizes nullable refs. The checked binary expands
;; both parameter/result refs in types 1 and 3 with the valid 0x63 prefix.
(module
  (type $extern_short (func (param externref) (result externref)))
  (type $extern_explicit (func (param (ref null extern)) (result (ref null extern))))
  (type $func_short (func (param funcref) (result funcref)))
  (type $func_explicit (func (param (ref null func)) (result (ref null func))))
  (func (export "extern_short") (type $extern_short) local.get 0)
  (func (export "extern_explicit") (type $extern_explicit) local.get 0)
  (func (export "func_short") (type $func_short) local.get 0)
  (func (export "func_explicit") (type $func_explicit) local.get 0)
)
