// 020 leg 4 — AssemblyScript.
//
// AS is the interesting case because it did NOT copy Rust's conventions. Its
// `string` is UTF-16 (JS semantics), and every managed object carries a runtime
// header whose `rtSize` field lives at `ptr - 4`. That means:
//
//   * a host holding UTF-8 has to transcode on the way in, and
//   * an ASCII string costs 2 bytes per character in linear memory, not 1.
//
// In exchange, AS↔JS avoids the transcode Rust pays, because JS strings are
// already UTF-16 — see the README's strings section.
//
// Export names and signatures deliberately match the Rust-manual leg, except
// `alloc_str`, which has to exist because a UTF-16 string is not a byte buffer.

// --- allocation --------------------------------------------------------------

// Raw byte buffer. Pinned: nothing in linear memory references it, so an
// unpinned buffer is collectable the moment the next allocation runs the GC.
// "Who owns this?" has a different wrong answer in every toolchain.
export function alloc(size: i32): i32 {
  return __pin(__new(<usize>size, idof<ArrayBuffer>())) as i32;
}

// An AssemblyScript `string`. `codeUnits` UTF-16 units => `codeUnits * 2` bytes.
// The returned pointer IS the data pointer; the 4-byte `rtSize` header sits
// immediately below it at ptr-4, and the GC header below that.
export function alloc_str(codeUnits: i32): i32 {
  return __pin(__new(<usize>(codeUnits << 1), idof<string>())) as i32;
}

// Proof, not documentation: returns the byte length AS itself recorded in the
// object header for a string the host allocated and filled.
export function str_rtsize(ptr: i32): i32 {
  return load<u32>(<usize>ptr - 4) as i32;
}

// --- shared checksum ---------------------------------------------------------

// @ts-ignore: decorator
@inline
function fnv(h: u32, v: u32): u32 {
  for (let i: i32 = 0; i < 4; i++) {
    h ^= (v >>> (i << 3)) & 0xff;
    h = h * 0x01000193;
  }
  return h;
}

// --- STRINGS -----------------------------------------------------------------

export function str_stats(ptr: i32, len: i32): u64 {
  const s = changetype<string>(<usize>ptr);
  let h: u32 = 0x811c9dc5;
  let n: u32 = 0;
  let i: i32 = 0;
  while (i < len) {
    let c: u32 = <u32>s.charCodeAt(i);
    // UTF-16 surrogate pair -> one Unicode scalar. Rust's `chars()` gets this
    // for free from UTF-8; UTF-16 makes it the guest's problem.
    if (c >= 0xd800 && c < 0xdc00 && i + 1 < len) {
      const c2: u32 = <u32>s.charCodeAt(i + 1);
      if (c2 >= 0xdc00 && c2 < 0xe000) {
        c = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
        i += 2;
      } else {
        i += 1;
      }
    } else {
      i += 1;
    }
    h = fnv(h, c);
    n += 1;
  }
  return ((<u64>n) << 32) | (<u64>h);
}

// --- LISTS -------------------------------------------------------------------

export function list_sum_u32(ptr: i32, len: i32): u64 {
  const p = <usize>ptr;
  let h: u32 = 0x811c9dc5;
  let acc: u64 = 0;
  for (let i: i32 = 0; i < len; i++) {
    const x = load<u32>(p + (<usize>i << 2));
    acc += <u64>x;
    h = fnv(h, x);
  }
  return acc ^ ((<u64>h) << 32);
}

// --- svec: u32 count | u32 offsets[count+1] | UTF-8 blob ---------------------

// @ts-ignore: decorator
@inline
function svecCount(base: i32): i32 {
  return load<u32>(<usize>base) as i32;
}
// @ts-ignore: decorator
@inline
function svecOff(base: i32, i: i32): i32 {
  return load<u32>(<usize>base + 4 + (<usize>i << 2)) as i32;
}

// Byte-wise comparison, no decode. Lexicographic then shorter-first.
function scmp(ap: usize, al: i32, bp: usize, bl: i32): i32 {
  const n = al < bl ? al : bl;
  for (let i: i32 = 0; i < n; i++) {
    const x = load<u8>(ap + <usize>i);
    const y = load<u8>(bp + <usize>i);
    if (x != y) return x < y ? -1 : 1;
  }
  return al == bl ? 0 : (al < bl ? -1 : 1);
}

// --- MAPS --------------------------------------------------------------------

// Binary search over the host's UTF-8 bytes. No AS `string` is ever built, so
// no transcoding happens at all — the fastest thing AS can do with a map, and
// it involves none of AS's own collection types.
export function map_lookup_sorted(keys: i32, vals: i32, probes: i32): u64 {
  const n = svecCount(keys);
  const m = svecCount(probes);
  let acc: u64 = 0;
  let hits: u64 = 0;
  for (let i: i32 = 0; i < m; i++) {
    const pp = <usize>keysBase(probes, i);
    const pl = svecOff(probes, i + 1) - svecOff(probes, i);
    let lo = 0, hi = n;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      const kp = <usize>keysBase(keys, mid);
      const kl = svecOff(keys, mid + 1) - svecOff(keys, mid);
      if (scmp(kp, kl, pp, pl) < 0) lo = mid + 1; else hi = mid;
    }
    if (lo < n) {
      const kp = <usize>keysBase(keys, lo);
      const kl = svecOff(keys, lo + 1) - svecOff(keys, lo);
      if (scmp(kp, kl, pp, pl) == 0) {
        acc += <u64>load<u32>(<usize>vals + (<usize>lo << 2));
        hits += 1;
      }
    }
  }
  return acc ^ (hits << 40);
}

// @ts-ignore: decorator
@inline
function keysBase(base: i32, i: i32): i32 {
  return base + svecOff(base, i);
}

// AS's own `Map<string, u32>`. Every key must become a UTF-16 AS string first:
// 1000 transcodes on build plus 4000 on probe. This is the AS↔UTF-8 tax, and it
// is the mirror image of the advantage AS has when the host is JS.
export function map_lookup_hash(keys: i32, vals: i32, probes: i32): u64 {
  const n = svecCount(keys);
  const map = new Map<string, u32>();
  for (let i: i32 = 0; i < n; i++) {
    const kp = <usize>keysBase(keys, i);
    const kl = svecOff(keys, i + 1) - svecOff(keys, i);
    map.set(String.UTF8.decodeUnsafe(kp, <usize>kl, false), load<u32>(<usize>vals + (<usize>i << 2)));
  }
  const m = svecCount(probes);
  let acc: u64 = 0;
  let hits: u64 = 0;
  for (let i: i32 = 0; i < m; i++) {
    const pp = <usize>keysBase(probes, i);
    const pl = svecOff(probes, i + 1) - svecOff(probes, i);
    const key = String.UTF8.decodeUnsafe(pp, <usize>pl, false);
    if (map.has(key)) {
      acc += <u64>map.get(key);
      hits += 1;
    }
  }
  return acc ^ (hits << 40);
}

// --- SETS --------------------------------------------------------------------

export function set_count_bitset(words: i32, nwords: i32, probes: i32, m: i32): u64 {
  const w = <usize>words;
  const p = <usize>probes;
  let hits: u64 = 0;
  for (let i: i32 = 0; i < m; i++) {
    const x = load<u32>(p + (<usize>i << 2));
    const wi = x >>> 6;
    if (wi < <u32>nwords) {
      hits += (load<u64>(w + (<usize>wi << 3)) >>> (x & 63)) & 1;
    }
  }
  return hits;
}

export function set_count_sorted(members: i32, n: i32, probes: i32, m: i32): u64 {
  const s = <usize>members;
  const p = <usize>probes;
  let hits: u64 = 0;
  for (let i: i32 = 0; i < m; i++) {
    const x = load<u32>(p + (<usize>i << 2));
    let lo = 0, hi = n;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (load<u32>(s + (<usize>mid << 2)) < x) lo = mid + 1; else hi = mid;
    }
    if (lo < n && load<u32>(s + (<usize>lo << 2)) == x) hits += 1;
  }
  return hits;
}

export function set_count_hash(members: i32, n: i32, probes: i32, m: i32): u64 {
  const s = <usize>members;
  const p = <usize>probes;
  const set = new Set<u32>();
  for (let i: i32 = 0; i < n; i++) set.add(load<u32>(s + (<usize>i << 2)));
  let hits: u64 = 0;
  for (let i: i32 = 0; i < m; i++) {
    if (set.has(load<u32>(p + (<usize>i << 2)))) hits += 1;
  }
  return hits;
}
