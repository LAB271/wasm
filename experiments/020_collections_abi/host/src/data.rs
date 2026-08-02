//! Deterministic workload generation. Every leg gets byte-identical input, so
//! the u64 checksums each leg returns are directly comparable — parity is
//! asserted before anything is timed.

/// Workload sizes. Kept in one place so the README can quote them.
pub const N_STRINGS: usize = 2_000;
pub const N_LIST: usize = 100_000;
pub const MAP_ENTRIES: usize = 1_000;
pub const MAP_PROBES: usize = 4_000;
pub const SET_DOMAIN: u32 = 65_536;
pub const SET_MEMBERS: usize = 4_096;
pub const SET_PROBES: usize = 65_536;

pub struct Lcg(u64);

impl Lcg {
    pub fn new(seed: u64) -> Self {
        Lcg(seed)
    }
    pub fn next_u32(&mut self) -> u32 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        (self.0 >> 33) as u32
    }
}

/// Mixed-width alphabet: 1-, 2-, 3- and 4-byte UTF-8 scalars. Ensures byte
/// length != code-point length != UTF-16 code-unit length, so no leg can pass
/// parity by accident.
const ALPHABET: &[char] = &[
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's',
    't', 'u', 'v', 'w', 'x', 'y', 'z', ' ', '0', '1', '2', // 1 byte
    'é', 'ü', 'ß', 'ñ', 'λ', 'Ω', // 2 bytes
    '日', '本', '語', '€', // 3 bytes
    '👍', '🎯', '🧪', // 4 bytes (surrogate pair in UTF-16)
];

pub fn strings() -> Vec<String> {
    let mut r = Lcg::new(0x5eed_1234);
    (0..N_STRINGS)
        .map(|_| {
            let len = 8 + (r.next_u32() % 33) as usize; // 8..40 code points
            (0..len)
                .map(|_| ALPHABET[(r.next_u32() as usize) % ALPHABET.len()])
                .collect()
        })
        .collect()
}

pub fn list_u32() -> Vec<u32> {
    let mut r = Lcg::new(0xabcd_0001);
    (0..N_LIST).map(|_| r.next_u32() & 0x00ff_ffff).collect()
}

/// Sorted, unique ASCII keys + values. Sorted because two of the three map
/// strategies (binary search, canonical-ABI list<tuple>) need it and the third
/// does not care.
pub fn map_entries() -> Vec<(String, u32)> {
    let mut r = Lcg::new(0x1111_2222);
    let mut v: Vec<(String, u32)> = (0..MAP_ENTRIES)
        .map(|i| {
            let key: String = (0..12)
                .map(|_| (b'a' + (r.next_u32() % 26) as u8) as char)
                .collect();
            (format!("{key}{i:04}"), r.next_u32() & 0xffff)
        })
        .collect();
    v.sort_by(|a, b| a.0.cmp(&b.0));
    v.dedup_by(|a, b| a.0 == b.0);
    v
}

/// Half hits, half misses — a realistic lookup mix, and it stops any leg from
/// short-circuiting.
pub fn map_probes(entries: &[(String, u32)]) -> Vec<String> {
    let mut r = Lcg::new(0x3333_4444);
    (0..MAP_PROBES)
        .map(|i| {
            if i % 2 == 0 {
                entries[(r.next_u32() as usize) % entries.len()].0.clone()
            } else {
                let key: String = (0..12)
                    .map(|_| (b'A' + (r.next_u32() % 26) as u8) as char)
                    .collect();
                format!("{key}{i:04}")
            }
        })
        .collect()
}

pub fn set_members() -> Vec<u32> {
    let mut r = Lcg::new(0x7777_8888);
    let mut v: Vec<u32> = (0..SET_MEMBERS).map(|_| r.next_u32() % SET_DOMAIN).collect();
    v.sort_unstable();
    v.dedup();
    v
}

pub fn set_probes() -> Vec<u32> {
    (0..SET_PROBES as u32).collect()
}

pub fn set_bitset_words(members: &[u32]) -> Vec<u64> {
    let nwords = (SET_DOMAIN as usize + 63) / 64;
    let mut w = vec![0u64; nwords];
    for &m in members {
        w[(m >> 6) as usize] |= 1u64 << (m & 63);
    }
    w
}

// ---------------------------------------------------------------------------
// svec — the string-vector wire format shared by the linear-memory legs.
//   u32 count | u32 offsets[count+1] | UTF-8 blob
// Offsets are absolute within the allocation, so the guest needs no base fixup
// beyond the header size. This is an invented format; that is the point.
// ---------------------------------------------------------------------------

pub fn svec_encode<S: AsRef<str>>(items: &[S]) -> Vec<u8> {
    let count = items.len();
    let header = 4 + 4 * (count + 1);
    let mut out = Vec::with_capacity(header + items.iter().map(|s| s.as_ref().len()).sum::<usize>());
    out.extend_from_slice(&(count as u32).to_le_bytes());
    let mut off = header as u32;
    for s in items {
        out.extend_from_slice(&off.to_le_bytes());
        off += s.as_ref().len() as u32;
    }
    out.extend_from_slice(&off.to_le_bytes());
    for s in items {
        out.extend_from_slice(s.as_ref().as_bytes());
    }
    out
}

// ---------------------------------------------------------------------------
// Reference checksums, computed natively. Every leg must reproduce these.
// ---------------------------------------------------------------------------

const FNV_OFFSET: u32 = 0x811c_9dc5;
const FNV_PRIME: u32 = 0x0100_0193;

pub fn fnv_u32(mut h: u32, v: u32) -> u32 {
    for b in v.to_le_bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(FNV_PRIME);
    }
    h
}

pub fn ref_str_stats(s: &str) -> u64 {
    let mut h = FNV_OFFSET;
    let mut n = 0u32;
    for c in s.chars() {
        h = fnv_u32(h, c as u32);
        n += 1;
    }
    ((n as u64) << 32) | (h as u64)
}

pub fn ref_list_sum(xs: &[u32]) -> u64 {
    let mut h = FNV_OFFSET;
    let mut acc = 0u64;
    for &x in xs {
        acc = acc.wrapping_add(x as u64);
        h = fnv_u32(h, x);
    }
    acc ^ ((h as u64) << 32)
}

pub fn ref_map_lookup(entries: &[(String, u32)], probes: &[String]) -> u64 {
    let mut acc = 0u64;
    let mut hits = 0u32;
    for p in probes {
        if let Ok(i) = entries.binary_search_by(|e| e.0.as_str().cmp(p.as_str())) {
            acc = acc.wrapping_add(entries[i].1 as u64);
            hits += 1;
        }
    }
    acc ^ ((hits as u64) << 40)
}

pub fn ref_set_count(members: &[u32], probes: &[u32]) -> u64 {
    probes
        .iter()
        .filter(|p| members.binary_search(p).is_ok())
        .count() as u64
}
