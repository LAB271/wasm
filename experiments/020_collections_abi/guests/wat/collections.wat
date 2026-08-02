;; 020 leg 1 — hand-written WAT. The irreducible baseline.
;;
;; There is no string type, no list type, no map type and no set type in this
;; file, because there are none in WebAssembly. Every collection below is an
;; offset into a flat byte array plus a convention the two sides agreed on out
;; of band. Everything the other legs generate is a variation of what is here.
;;
;; Exports match the Rust-manual leg byte-for-byte in name and signature, so the
;; same host driver runs both and any difference in the numbers is the ABI, not
;; the harness.

(module
  (memory (export "memory") 1)

  ;; -------------------------------------------------------------------------
  ;; Allocator. A bump pointer is the smallest thing that satisfies the
  ;; convention: the host cannot write into linear memory without first asking
  ;; the guest where it may write. `dealloc` exists to match the Rust leg's
  ;; signature and does nothing -- a bump allocator cannot free, which is
  ;; exactly the ownership hole the ptr+len convention leaves open.
  ;; -------------------------------------------------------------------------
  (global $bump (mut i32) (i32.const 1024))

  (func $alloc (export "alloc") (param $n i32) (result i32)
    (local $p i32) (local $need i32) (local $have i32)
    (local.set $p (global.get $bump))
    (global.set $bump
      (i32.and (i32.add (i32.add (local.get $p) (local.get $n)) (i32.const 7))
               (i32.const -8)))
    (local.set $need
      (i32.div_u (i32.add (global.get $bump) (i32.const 65535)) (i32.const 65536)))
    (local.set $have (memory.size))
    (if (i32.gt_u (local.get $need) (local.get $have))
      (then (drop (memory.grow (i32.sub (local.get $need) (local.get $have))))))
    (local.get $p))

  (func (export "dealloc") (param i32) (param i32))

  ;; -------------------------------------------------------------------------
  ;; FNV-1a over one u32, little-endian. Shared checksum with every other leg.
  ;; -------------------------------------------------------------------------
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

  ;; -------------------------------------------------------------------------
  ;; STRINGS -- ptr + len, UTF-8, host-encoded, guest-decoded.
  ;; Returns (code_point_count << 32) | fnv1a. The UTF-8 decode below is the
  ;; whole cost of "a string" at this level: 20 lines of branching on the lead
  ;; byte. Nothing in WASM does it for you.
  ;; -------------------------------------------------------------------------
  (func (export "str_stats") (param $ptr i32) (param $len i32) (result i64)
    (local $i i32) (local $h i32) (local $n i32)
    (local $b0 i32) (local $cp i32)
    (local.set $h (i32.const 0x811c9dc5))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $b0 (i32.load8_u (i32.add (local.get $ptr) (local.get $i))))
        (block $decoded
          ;; 1-byte: 0xxxxxxx
          (if (i32.lt_u (local.get $b0) (i32.const 0x80))
            (then
              (local.set $cp (local.get $b0))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $decoded)))
          ;; 2-byte: 110xxxxx 10xxxxxx
          (if (i32.lt_u (local.get $b0) (i32.const 0xE0))
            (then
              (local.set $cp
                (i32.or (i32.shl (i32.and (local.get $b0) (i32.const 0x1F)) (i32.const 6))
                        (i32.and (i32.load8_u (i32.add (local.get $ptr)
                                   (i32.add (local.get $i) (i32.const 1))))
                                 (i32.const 0x3F))))
              (local.set $i (i32.add (local.get $i) (i32.const 2)))
              (br $decoded)))
          ;; 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
          (if (i32.lt_u (local.get $b0) (i32.const 0xF0))
            (then
              (local.set $cp
                (i32.or
                  (i32.or (i32.shl (i32.and (local.get $b0) (i32.const 0x0F)) (i32.const 12))
                          (i32.shl (i32.and (i32.load8_u (i32.add (local.get $ptr)
                                     (i32.add (local.get $i) (i32.const 1))))
                                   (i32.const 0x3F)) (i32.const 6)))
                  (i32.and (i32.load8_u (i32.add (local.get $ptr)
                             (i32.add (local.get $i) (i32.const 2))))
                           (i32.const 0x3F))))
              (local.set $i (i32.add (local.get $i) (i32.const 3)))
              (br $decoded)))
          ;; 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
          (local.set $cp
            (i32.or
              (i32.or (i32.shl (i32.and (local.get $b0) (i32.const 0x07)) (i32.const 18))
                      (i32.shl (i32.and (i32.load8_u (i32.add (local.get $ptr)
                                 (i32.add (local.get $i) (i32.const 1))))
                               (i32.const 0x3F)) (i32.const 12)))
              (i32.or (i32.shl (i32.and (i32.load8_u (i32.add (local.get $ptr)
                                 (i32.add (local.get $i) (i32.const 2))))
                               (i32.const 0x3F)) (i32.const 6))
                      (i32.and (i32.load8_u (i32.add (local.get $ptr)
                                 (i32.add (local.get $i) (i32.const 3))))
                               (i32.const 0x3F)))))
          (local.set $i (i32.add (local.get $i) (i32.const 4))))
        (local.set $h (call $fnv (local.get $h) (local.get $cp)))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (br $l)))
    (i64.or (i64.shl (i64.extend_i32_u (local.get $n)) (i64.const 32))
            (i64.extend_i32_u (local.get $h))))

  ;; -------------------------------------------------------------------------
  ;; LISTS -- homogeneous numeric. The host's bytes already ARE the guest's
  ;; representation, so there is no decode step at all. This is the only
  ;; collection for which that is true.
  ;; -------------------------------------------------------------------------
  (func (export "list_sum_u32") (param $ptr i32) (param $len i32) (result i64)
    (local $i i32) (local $h i32) (local $x i32) (local $acc i64)
    (local.set $h (i32.const 0x811c9dc5))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $x (i32.load (i32.add (local.get $ptr)
                                         (i32.mul (local.get $i) (i32.const 4)))))
        (local.set $acc (i64.add (local.get $acc) (i64.extend_i32_u (local.get $x))))
        (local.set $h (call $fnv (local.get $h) (local.get $x)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (i64.xor (local.get $acc)
             (i64.shl (i64.extend_i32_u (local.get $h)) (i64.const 32))))

  ;; -------------------------------------------------------------------------
  ;; svec accessors. Wire format: u32 count | u32 offsets[count+1] | UTF-8 blob.
  ;; Offsets are absolute within the allocation.
  ;; -------------------------------------------------------------------------
  (func $svec_count (param $base i32) (result i32)
    (i32.load (local.get $base)))

  (func $svec_off (param $base i32) (param $i i32) (result i32)
    (i32.load (i32.add (local.get $base)
                       (i32.add (i32.const 4) (i32.mul (local.get $i) (i32.const 4))))))

  ;; memcmp-with-length: lexicographic byte order, then shorter-first.
  (func $scmp (param $ap i32) (param $al i32) (param $bp i32) (param $bl i32) (result i32)
    (local $i i32) (local $n i32) (local $x i32) (local $y i32)
    (local.set $n (select (local.get $al) (local.get $bl)
                          (i32.lt_u (local.get $al) (local.get $bl))))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $x (i32.load8_u (i32.add (local.get $ap) (local.get $i))))
        (local.set $y (i32.load8_u (i32.add (local.get $bp) (local.get $i))))
        (if (i32.ne (local.get $x) (local.get $y))
          (then (return (select (i32.const -1) (i32.const 1)
                                (i32.lt_u (local.get $x) (local.get $y))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (if (i32.lt_u (local.get $al) (local.get $bl)) (then (return (i32.const -1))))
    (if (i32.gt_u (local.get $al) (local.get $bl)) (then (return (i32.const 1))))
    (i32.const 0))

  ;; -------------------------------------------------------------------------
  ;; MAPS -- there is no map. This is a sorted key svec, a parallel u32 value
  ;; array, and a binary search written out by hand. That is the entire
  ;; "map ABI" for core WASM.
  ;; -------------------------------------------------------------------------
  (func (export "map_lookup_sorted")
        (param $keys i32) (param $vals i32) (param $probes i32) (result i64)
    (local $n i32) (local $m i32) (local $i i32)
    (local $lo i32) (local $hi i32) (local $mid i32)
    (local $pp i32) (local $pl i32) (local $kp i32) (local $kl i32)
    (local $acc i64) (local $hits i64)
    (local.set $n (call $svec_count (local.get $keys)))
    (local.set $m (call $svec_count (local.get $probes)))
    (block $outer
      (loop $ol
        (br_if $outer (i32.ge_u (local.get $i) (local.get $m)))
        (local.set $pp (i32.add (local.get $probes)
                                (call $svec_off (local.get $probes) (local.get $i))))
        (local.set $pl (i32.sub (call $svec_off (local.get $probes)
                                      (i32.add (local.get $i) (i32.const 1)))
                                (call $svec_off (local.get $probes) (local.get $i))))
        (local.set $lo (i32.const 0))
        (local.set $hi (local.get $n))
        (block $bdone
          (loop $bl
            (br_if $bdone (i32.ge_u (local.get $lo) (local.get $hi)))
            (local.set $mid (i32.div_u (i32.add (local.get $lo) (local.get $hi)) (i32.const 2)))
            (local.set $kp (i32.add (local.get $keys)
                                    (call $svec_off (local.get $keys) (local.get $mid))))
            (local.set $kl (i32.sub (call $svec_off (local.get $keys)
                                          (i32.add (local.get $mid) (i32.const 1)))
                                    (call $svec_off (local.get $keys) (local.get $mid))))
            (if (i32.lt_s (call $scmp (local.get $kp) (local.get $kl)
                                      (local.get $pp) (local.get $pl))
                          (i32.const 0))
              (then (local.set $lo (i32.add (local.get $mid) (i32.const 1))))
              (else (local.set $hi (local.get $mid))))
            (br $bl)))
        (if (i32.lt_u (local.get $lo) (local.get $n))
          (then
            (local.set $kp (i32.add (local.get $keys)
                                    (call $svec_off (local.get $keys) (local.get $lo))))
            (local.set $kl (i32.sub (call $svec_off (local.get $keys)
                                          (i32.add (local.get $lo) (i32.const 1)))
                                    (call $svec_off (local.get $keys) (local.get $lo))))
            (if (i32.eqz (call $scmp (local.get $kp) (local.get $kl)
                                     (local.get $pp) (local.get $pl)))
              (then
                (local.set $acc
                  (i64.add (local.get $acc)
                           (i64.extend_i32_u (i32.load (i32.add (local.get $vals)
                             (i32.mul (local.get $lo) (i32.const 4)))))))
                (local.set $hits (i64.add (local.get $hits) (i64.const 1)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $ol)))
    (i64.xor (local.get $acc) (i64.shl (local.get $hits) (i64.const 40))))

  ;; -------------------------------------------------------------------------
  ;; SETS -- the bitset case. `i64.shr_u` + `i64.and` are MVP instructions;
  ;; 64 members per word, no allocation, no comparison, no branching.
  ;; -------------------------------------------------------------------------
  (func (export "set_count_bitset")
        (param $words i32) (param $nwords i32) (param $probes i32) (param $m i32) (result i64)
    (local $i i32) (local $x i32) (local $w i32) (local $hits i64)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $m)))
        (local.set $x (i32.load (i32.add (local.get $probes)
                                         (i32.mul (local.get $i) (i32.const 4)))))
        (local.set $w (i32.shr_u (local.get $x) (i32.const 6)))
        (if (i32.lt_u (local.get $w) (local.get $nwords))
          (then
            (local.set $hits
              (i64.add (local.get $hits)
                (i64.and
                  (i64.shr_u
                    (i64.load (i32.add (local.get $words)
                                       (i32.mul (local.get $w) (i32.const 8))))
                    (i64.extend_i32_u (i32.and (local.get $x) (i32.const 63))))
                  (i64.const 1))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $hits))

  ;; Sorted u32 array + binary search: domain-independent, 4 bytes per member.
  (func (export "set_count_sorted")
        (param $mem i32) (param $n i32) (param $probes i32) (param $m i32) (result i64)
    (local $i i32) (local $x i32) (local $lo i32) (local $hi i32) (local $mid i32)
    (local $hits i64)
    (block $outer
      (loop $ol
        (br_if $outer (i32.ge_u (local.get $i) (local.get $m)))
        (local.set $x (i32.load (i32.add (local.get $probes)
                                         (i32.mul (local.get $i) (i32.const 4)))))
        (local.set $lo (i32.const 0))
        (local.set $hi (local.get $n))
        (block $bdone
          (loop $bl
            (br_if $bdone (i32.ge_u (local.get $lo) (local.get $hi)))
            (local.set $mid (i32.div_u (i32.add (local.get $lo) (local.get $hi)) (i32.const 2)))
            (if (i32.lt_u (i32.load (i32.add (local.get $mem)
                                             (i32.mul (local.get $mid) (i32.const 4))))
                          (local.get $x))
              (then (local.set $lo (i32.add (local.get $mid) (i32.const 1))))
              (else (local.set $hi (local.get $mid))))
            (br $bl)))
        (if (i32.lt_u (local.get $lo) (local.get $n))
          (then (if (i32.eq (i32.load (i32.add (local.get $mem)
                                               (i32.mul (local.get $lo) (i32.const 4))))
                            (local.get $x))
            (then (local.set $hits (i64.add (local.get $hits) (i64.const 1)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $ol)))
    (local.get $hits))
)
