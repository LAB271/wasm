;; 020 leg 6 — `externref`: don't marshal at all.
;;
;; This module has NO MEMORY. Not a small one — none. The collections stay in
;; the host's own representation (Rust `String`, `Vec<u32>`, `HashMap`,
;; `HashSet`); the guest holds an opaque reference and reaches through imports
;; for every element it needs. Zero bytes are copied across the boundary.
;;
;; The price is one host call per element instead of one per collection, so this
;; trades a linear copy for a linear number of crossings. Whether that is a good
;; trade is exactly what the numbers in the README answer.
;;
;; `externref` is a WASM 2.0 / reference-types opaque handle. The guest cannot
;; inspect it, cannot store it in linear memory, and cannot forge one.

(module
  ;; UTF-8 code point at byte offset -> (cp << 32) | next_offset.
  (import "host" "str_bytes_len" (func $str_bytes_len (param externref) (result i32)))
  (import "host" "str_cp_at"     (func $str_cp_at (param externref i32) (result i64)))
  (import "host" "vec_len"       (func $vec_len (param externref) (result i32)))
  (import "host" "vec_get_u32"   (func $vec_get_u32 (param externref i32) (result i32)))
  ;; map lookup by probe index: -1 when absent, else the u32 value.
  (import "host" "map_get_i"     (func $map_get_i (param externref externref i32) (result i64)))
  (import "host" "set_has"       (func $set_has (param externref i32) (result i32)))

  (func $fnv (param $h i32) (param $v i32) (result i32)
    (local $i i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (i32.const 4)))
        (local.set $h
          (i32.mul
            (i32.xor (local.get $h)
              (i32.and (i32.shr_u (local.get $v)
                                  (i32.mul (local.get $i) (i32.const 8)))
                       (i32.const 255)))
            (i32.const 0x01000193)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $h))

  ;; STRING — one host call per code point.
  (func (export "str_stats") (param $s externref) (result i64)
    (local $off i32) (local $len i32) (local $h i32) (local $n i32) (local $r i64)
    (local.set $h (i32.const 0x811c9dc5))
    (local.set $len (call $str_bytes_len (local.get $s)))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $off) (local.get $len)))
        (local.set $r (call $str_cp_at (local.get $s) (local.get $off)))
        (local.set $h (call $fnv (local.get $h)
                             (i32.wrap_i64 (i64.shr_u (local.get $r) (i64.const 32)))))
        (local.set $off (i32.wrap_i64 (local.get $r)))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (br $l)))
    (i64.or (i64.shl (i64.extend_i32_u (local.get $n)) (i64.const 32))
            (i64.extend_i32_u (local.get $h))))

  ;; LIST — one host call per element.
  (func (export "list_sum_u32") (param $v externref) (result i64)
    (local $i i32) (local $n i32) (local $x i32) (local $h i32) (local $acc i64)
    (local.set $h (i32.const 0x811c9dc5))
    (local.set $n (call $vec_len (local.get $v)))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $x (call $vec_get_u32 (local.get $v) (local.get $i)))
        (local.set $acc (i64.add (local.get $acc) (i64.extend_i32_u (local.get $x))))
        (local.set $h (call $fnv (local.get $h) (local.get $x)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (i64.xor (local.get $acc)
             (i64.shl (i64.extend_i32_u (local.get $h)) (i64.const 32))))

  ;; MAP — the map never leaves the host. One host call per probe.
  (func (export "map_lookup") (param $m externref) (param $p externref) (result i64)
    (local $i i32) (local $n i32) (local $r i64) (local $acc i64) (local $hits i64)
    (local.set $n (call $vec_len (local.get $p)))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $r (call $map_get_i (local.get $m) (local.get $p) (local.get $i)))
        (if (i64.ge_s (local.get $r) (i64.const 0))
          (then
            (local.set $acc (i64.add (local.get $acc) (local.get $r)))
            (local.set $hits (i64.add (local.get $hits) (i64.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (i64.xor (local.get $acc) (i64.shl (local.get $hits) (i64.const 40))))

  ;; SET — same shape, membership only.
  (func (export "set_count") (param $s externref) (param $p externref) (result i64)
    (local $i i32) (local $n i32) (local $hits i64)
    (local.set $n (call $vec_len (local.get $p)))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $hits
          (i64.add (local.get $hits)
                   (i64.extend_i32_u (call $set_has (local.get $s)
                                           (call $vec_get_u32 (local.get $p) (local.get $i))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $hits))
)
