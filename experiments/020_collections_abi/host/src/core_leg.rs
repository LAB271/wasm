//! Core-module legs: hand-written WAT, Rust-manual, AssemblyScript.
//!
//! All three expose the *same* export signatures deliberately, so one driver
//! covers them and any difference in the numbers is a difference in the ABI,
//! not in the harness. The single divergence is strings: AssemblyScript's
//! `string` is UTF-16, so its allocator entry point is `alloc_str(codeUnits)`
//! and the host writes 2 bytes per code unit instead of UTF-8.

use crate::data::{self, *};
use crate::{bench, Cell};
use anyhow::{Context, Result};
use wasmtime::{Engine, Instance, Linker, Memory, Module, Store, TypedFunc};

pub struct Ctx {
    store: Store<()>,
    memory: Memory,
    instance: Instance,
}

impl Ctx {
    fn f1(&mut self, name: &str) -> Result<TypedFunc<i32, i32>> {
        Ok(self.instance.get_typed_func(&mut self.store, name)?)
    }
    fn f2i64(&mut self, name: &str) -> Result<TypedFunc<(i32, i32), i64>> {
        Ok(self.instance.get_typed_func(&mut self.store, name)?)
    }
    fn f3i64(&mut self, name: &str) -> Result<TypedFunc<(i32, i32, i32), i64>> {
        Ok(self.instance.get_typed_func(&mut self.store, name)?)
    }
    fn f4i64(&mut self, name: &str) -> Result<TypedFunc<(i32, i32, i32, i32), i64>> {
        Ok(self.instance.get_typed_func(&mut self.store, name)?)
    }
    fn write(&mut self, ptr: i32, bytes: &[u8]) {
        let p = ptr as usize;
        self.memory.data_mut(&mut self.store)[p..p + bytes.len()].copy_from_slice(bytes);
    }
}

fn open(path: &str) -> Result<Ctx> {
    let engine = Engine::default();
    let module = Module::from_file(&engine, path)?;
    let mut store = Store::new(&engine, ());
    let mut linker: Linker<()> = Linker::new(&engine);
    // AssemblyScript emits an `abort` import unless every bounds check is
    // elided; satisfy it rather than fight it.
    linker.func_wrap("env", "abort", |_: i32, _: i32, _: i32, _: i32| -> () {
        panic!("guest called abort()")
    })?;
    let instance = linker.instantiate(&mut store, &module)?;
    let memory = instance
        .get_memory(&mut store, "memory")
        .context("guest exports no `memory`")?;
    Ok(Ctx {
        store,
        memory,
        instance,
    })
}

/// UTF-16LE code units, as AssemblyScript stores them.
fn utf16le(s: &str) -> Vec<u8> {
    let mut v = Vec::with_capacity(s.len() * 2);
    for u in s.encode_utf16() {
        v.extend_from_slice(&u.to_le_bytes());
    }
    v
}

fn u32s_le(xs: &[u32]) -> Vec<u8> {
    let mut v = Vec::with_capacity(xs.len() * 4);
    for &x in xs {
        v.extend_from_slice(&x.to_le_bytes());
    }
    v
}

fn u64s_le(xs: &[u64]) -> Vec<u8> {
    let mut v = Vec::with_capacity(xs.len() * 8);
    for &x in xs {
        v.extend_from_slice(&x.to_le_bytes());
    }
    v
}

pub fn run(
    leg: &'static str,
    path: &str,
    utf16: bool,
    op: &str,
    warmup: usize,
    rounds: usize,
) -> Result<Cell> {
    let mut c = open(path)?;
    match op {
        "str" => str_op(leg, &mut c, utf16, warmup, rounds),
        "callcost" => callcost_op(leg, &mut c, utf16, warmup, rounds),
        "list" => list_op(leg, &mut c, warmup, rounds),
        "map_sorted" => map_op(leg, &mut c, "map_lookup_sorted", warmup, rounds),
        "map_hash" => map_op(leg, &mut c, "map_lookup_hash", warmup, rounds),
        "map_handle" => map_handle_op(leg, &mut c, warmup, rounds),
        "set_bitset" => set_bitset_op(leg, &mut c, warmup, rounds),
        "set_sorted" => set_scalar_op(leg, &mut c, "set_count_sorted", warmup, rounds),
        "set_hash" => set_scalar_op(leg, &mut c, "set_count_hash", warmup, rounds),
        other => anyhow::bail!("core leg has no op {other}"),
    }
}

// ---------------------------------------------------------------------------
// STRINGS
// ---------------------------------------------------------------------------

fn str_op(
    leg: &'static str,
    c: &mut Ctx,
    utf16: bool,
    warmup: usize,
    rounds: usize,
) -> Result<Cell> {
    let strs = data::strings();
    let encoded: Vec<Vec<u8>> = strs
        .iter()
        .map(|s| if utf16 { utf16le(s) } else { s.as_bytes().to_vec() })
        .collect();
    // `len` in the guest's own unit: UTF-8 bytes, or UTF-16 code units.
    let lens: Vec<i32> = strs
        .iter()
        .map(|s| {
            if utf16 {
                s.encode_utf16().count() as i32
            } else {
                s.len() as i32
            }
        })
        .collect();
    let bytes: u64 = encoded.iter().map(|e| e.len() as u64).sum();
    let reference = strs
        .iter()
        .fold(0u64, |a, s| a.wrapping_add(ref_str_stats(s)));

    let alloc = c.f1(if utf16 { "alloc_str" } else { "alloc" })?;
    let stats_fn = c.f2i64("str_stats")?;

    // --- marshal only: allocate + copy, no call ---
    let (marshal, _) = bench(warmup, rounds, || {
        let mut acc = 0u64;
        for (i, e) in encoded.iter().enumerate() {
            let p = alloc.call(&mut c.store, lens[i])?;
            c.write(p, e);
            acc = acc.wrapping_add(p as u64);
        }
        Ok(acc)
    })?;

    // --- call only: inputs already resident ---
    let mut ptrs = Vec::with_capacity(encoded.len());
    for (i, e) in encoded.iter().enumerate() {
        let p = alloc.call(&mut c.store, lens[i])?;
        c.write(p, e);
        ptrs.push(p);
    }
    let (call, checksum) = bench(warmup, rounds, || {
        let mut acc = 0u64;
        for (i, &p) in ptrs.iter().enumerate() {
            acc = acc.wrapping_add(stats_fn.call(&mut c.store, (p, lens[i]))? as u64);
        }
        Ok(acc)
    })?;
    anyhow::ensure!(
        checksum == reference,
        "{leg} str parity FAILED: got {checksum:#x} want {reference:#x}"
    );

    // --- realistic combined loop ---
    let (total, _) = bench(warmup, rounds, || {
        let mut acc = 0u64;
        for (i, e) in encoded.iter().enumerate() {
            let p = alloc.call(&mut c.store, lens[i])?;
            c.write(p, e);
            acc = acc.wrapping_add(stats_fn.call(&mut c.store, (p, lens[i]))? as u64);
        }
        Ok(acc)
    })?;

    Ok(Cell {
        leg,
        op: "str".into(),
        bytes_copied: bytes,
        marshal: Some(marshal),
        call,
        total,
        checksum,
        note: format!(
            "{} strings, {}",
            N_STRINGS,
            if utf16 { "utf16" } else { "utf8" }
        ),
    })
}

/// Fixed cost of one export call carrying a 1-code-point string, repeated
/// N_STRINGS times. Isolates per-crossing overhead from anything size-related,
/// so the component leg's per-call cost can be compared like for like.
fn callcost_op(
    leg: &'static str,
    c: &mut Ctx,
    utf16: bool,
    warmup: usize,
    rounds: usize,
) -> Result<Cell> {
    let one = if utf16 { utf16le("x") } else { b"x".to_vec() };
    let alloc = c.f1(if utf16 { "alloc_str" } else { "alloc" })?;
    let stats_fn = c.f2i64("str_stats")?;
    let p = alloc.call(&mut c.store, 1)?;
    c.write(p, &one);
    let (call, checksum) = bench(warmup, rounds, || {
        let mut acc = 0u64;
        for _ in 0..N_STRINGS {
            acc = acc.wrapping_add(stats_fn.call(&mut c.store, (p, 1))? as u64);
        }
        Ok(acc)
    })?;
    Ok(Cell {
        leg,
        op: "callcost".into(),
        bytes_copied: 0,
        marshal: None,
        call: crate::Timing {
            median_ns: call.median_ns,
            min_ns: call.min_ns,
            max_ns: call.max_ns,
        },
        total: call,
        checksum,
        note: format!("{} calls, 1-code-point string, no marshalling", N_STRINGS),
    })
}

// ---------------------------------------------------------------------------
// LISTS
// ---------------------------------------------------------------------------

fn list_op(leg: &'static str, c: &mut Ctx, warmup: usize, rounds: usize) -> Result<Cell> {
    let xs = data::list_u32();
    let raw = u32s_le(&xs);
    let reference = ref_list_sum(&xs);
    let alloc = c.f1("alloc")?;
    let sum = c.f2i64("list_sum_u32")?;

    let (marshal, _) = bench(warmup, rounds, || {
        let p = alloc.call(&mut c.store, raw.len() as i32)?;
        c.write(p, &raw);
        Ok(p as u64)
    })?;

    let p = alloc.call(&mut c.store, raw.len() as i32)?;
    c.write(p, &raw);
    let (call, checksum) = bench(warmup, rounds, || {
        Ok(sum.call(&mut c.store, (p, xs.len() as i32))? as u64)
    })?;
    anyhow::ensure!(
        checksum == reference,
        "{leg} list parity FAILED: got {checksum:#x} want {reference:#x}"
    );

    let (total, _) = bench(warmup, rounds, || {
        let p = alloc.call(&mut c.store, raw.len() as i32)?;
        c.write(p, &raw);
        Ok(sum.call(&mut c.store, (p, xs.len() as i32))? as u64)
    })?;

    Ok(Cell {
        leg,
        op: "list".into(),
        bytes_copied: raw.len() as u64,
        marshal: Some(marshal),
        call,
        total,
        checksum,
        note: format!("{} u32", N_LIST),
    })
}

// ---------------------------------------------------------------------------
// MAPS
// ---------------------------------------------------------------------------

struct MapBlobs {
    keys: Vec<u8>,
    vals: Vec<u8>,
    probes: Vec<u8>,
    reference: u64,
}

fn map_blobs() -> MapBlobs {
    let entries = data::map_entries();
    let probes = data::map_probes(&entries);
    let keys: Vec<&str> = entries.iter().map(|e| e.0.as_str()).collect();
    let vals: Vec<u32> = entries.iter().map(|e| e.1).collect();
    MapBlobs {
        keys: svec_encode(&keys),
        vals: u32s_le(&vals),
        probes: svec_encode(&probes),
        reference: ref_map_lookup(&entries, &probes),
    }
}

fn map_op(
    leg: &'static str,
    c: &mut Ctx,
    export: &str,
    warmup: usize,
    rounds: usize,
) -> Result<Cell> {
    let b = map_blobs();
    let bytes = (b.keys.len() + b.vals.len() + b.probes.len()) as u64;
    let alloc = c.f1("alloc")?;
    let lookup = c.f3i64(export)?;

    let mut marshal_into = |c: &mut Ctx| -> Result<(i32, i32, i32)> {
        let kp = alloc.call(&mut c.store, b.keys.len() as i32)?;
        c.write(kp, &b.keys);
        let vp = alloc.call(&mut c.store, b.vals.len() as i32)?;
        c.write(vp, &b.vals);
        let pp = alloc.call(&mut c.store, b.probes.len() as i32)?;
        c.write(pp, &b.probes);
        Ok((kp, vp, pp))
    };

    let (marshal, _) = bench(warmup, rounds, || {
        let (kp, _, _) = marshal_into(c)?;
        Ok(kp as u64)
    })?;

    let (kp, vp, pp) = marshal_into(c)?;
    let (call, checksum) = bench(warmup, rounds, || {
        Ok(lookup.call(&mut c.store, (kp, vp, pp))? as u64)
    })?;
    anyhow::ensure!(
        checksum == b.reference,
        "{leg} {export} parity FAILED: got {checksum:#x} want {:#x}",
        b.reference
    );

    let (total, _) = bench(warmup, rounds, || {
        let (kp, vp, pp) = marshal_into(c)?;
        Ok(lookup.call(&mut c.store, (kp, vp, pp))? as u64)
    })?;

    Ok(Cell {
        leg,
        op: export.replace("map_lookup_", "map_"),
        bytes_copied: bytes,
        marshal: Some(marshal),
        call,
        total,
        checksum,
        note: format!("{} entries / {} probes", MAP_ENTRIES, MAP_PROBES),
    })
}

/// Build the map once, keep it guest-side behind an integer handle, probe many
/// times. `marshal` here includes the build; `call` is the amortised query.
fn map_handle_op(leg: &'static str, c: &mut Ctx, warmup: usize, rounds: usize) -> Result<Cell> {
    let b = map_blobs();
    let bytes = (b.keys.len() + b.vals.len() + b.probes.len()) as u64;
    let alloc = c.f1("alloc")?;
    let build: TypedFunc<(i32, i32), i32> = c
        .instance
        .get_typed_func(&mut c.store, "map_build")?;
    let query = c.f2i64("map_query")?;

    let (marshal, _) = bench(warmup, rounds, || {
        let kp = alloc.call(&mut c.store, b.keys.len() as i32)?;
        c.write(kp, &b.keys);
        let vp = alloc.call(&mut c.store, b.vals.len() as i32)?;
        c.write(vp, &b.vals);
        let h = build.call(&mut c.store, (kp, vp))?;
        Ok(h as u64)
    })?;

    let kp = alloc.call(&mut c.store, b.keys.len() as i32)?;
    c.write(kp, &b.keys);
    let vp = alloc.call(&mut c.store, b.vals.len() as i32)?;
    c.write(vp, &b.vals);
    let h = build.call(&mut c.store, (kp, vp))?;
    let pp = alloc.call(&mut c.store, b.probes.len() as i32)?;
    c.write(pp, &b.probes);

    let (call, checksum) = bench(warmup, rounds, || {
        Ok(query.call(&mut c.store, (h, pp))? as u64)
    })?;
    anyhow::ensure!(
        checksum == b.reference,
        "{leg} map_handle parity FAILED: got {checksum:#x} want {:#x}",
        b.reference
    );

    let (total, _) = bench(warmup, rounds, || {
        let pp = alloc.call(&mut c.store, b.probes.len() as i32)?;
        c.write(pp, &b.probes);
        Ok(query.call(&mut c.store, (h, pp))? as u64)
    })?;

    Ok(Cell {
        leg,
        op: "map_handle".into(),
        bytes_copied: bytes,
        marshal: Some(marshal),
        call,
        total,
        checksum,
        note: "marshal = blobs + build; call = query only".into(),
    })
}

// ---------------------------------------------------------------------------
// SETS
// ---------------------------------------------------------------------------

fn set_bitset_op(leg: &'static str, c: &mut Ctx, warmup: usize, rounds: usize) -> Result<Cell> {
    let members = data::set_members();
    let probes = data::set_probes();
    let words = data::set_bitset_words(&members);
    let wraw = u64s_le(&words);
    let praw = u32s_le(&probes);
    let reference = ref_set_count(&members, &probes);
    let alloc = c.f1("alloc")?;
    let count = c.f4i64("set_count_bitset")?;

    let (marshal, _) = bench(warmup, rounds, || {
        let wp = alloc.call(&mut c.store, wraw.len() as i32)?;
        c.write(wp, &wraw);
        let pp = alloc.call(&mut c.store, praw.len() as i32)?;
        c.write(pp, &praw);
        Ok((wp as u64) ^ (pp as u64))
    })?;

    let wp = alloc.call(&mut c.store, wraw.len() as i32)?;
    c.write(wp, &wraw);
    let pp = alloc.call(&mut c.store, praw.len() as i32)?;
    c.write(pp, &praw);
    let (call, checksum) = bench(warmup, rounds, || {
        Ok(count.call(
            &mut c.store,
            (wp, words.len() as i32, pp, probes.len() as i32),
        )? as u64)
    })?;
    anyhow::ensure!(
        checksum == reference,
        "{leg} set_bitset parity FAILED: got {checksum} want {reference}"
    );

    let (total, _) = bench(warmup, rounds, || {
        let wp = alloc.call(&mut c.store, wraw.len() as i32)?;
        c.write(wp, &wraw);
        let pp = alloc.call(&mut c.store, praw.len() as i32)?;
        c.write(pp, &praw);
        Ok(count.call(
            &mut c.store,
            (wp, words.len() as i32, pp, probes.len() as i32),
        )? as u64)
    })?;

    Ok(Cell {
        leg,
        op: "set_bitset".into(),
        bytes_copied: (wraw.len() + praw.len()) as u64,
        marshal: Some(marshal),
        call,
        total,
        checksum,
        note: format!(
            "{} members in domain {}, {} probes",
            members.len(),
            SET_DOMAIN,
            probes.len()
        ),
    })
}

fn set_scalar_op(
    leg: &'static str,
    c: &mut Ctx,
    export: &str,
    warmup: usize,
    rounds: usize,
) -> Result<Cell> {
    let members = data::set_members();
    let probes = data::set_probes();
    let mraw = u32s_le(&members);
    let praw = u32s_le(&probes);
    let reference = ref_set_count(&members, &probes);
    let alloc = c.f1("alloc")?;
    let count = c.f4i64(export)?;
    let (n, m) = (members.len() as i32, probes.len() as i32);

    let (marshal, _) = bench(warmup, rounds, || {
        let mp = alloc.call(&mut c.store, mraw.len() as i32)?;
        c.write(mp, &mraw);
        let pp = alloc.call(&mut c.store, praw.len() as i32)?;
        c.write(pp, &praw);
        Ok((mp as u64) ^ (pp as u64))
    })?;

    let mp = alloc.call(&mut c.store, mraw.len() as i32)?;
    c.write(mp, &mraw);
    let pp = alloc.call(&mut c.store, praw.len() as i32)?;
    c.write(pp, &praw);
    let (call, checksum) =
        bench(warmup, rounds, || {
            Ok(count.call(&mut c.store, (mp, n, pp, m))? as u64)
        })?;
    anyhow::ensure!(
        checksum == reference,
        "{leg} {export} parity FAILED: got {checksum} want {reference}"
    );

    let (total, _) = bench(warmup, rounds, || {
        let mp = alloc.call(&mut c.store, mraw.len() as i32)?;
        c.write(mp, &mraw);
        let pp = alloc.call(&mut c.store, praw.len() as i32)?;
        c.write(pp, &praw);
        Ok(count.call(&mut c.store, (mp, n, pp, m))? as u64)
    })?;

    Ok(Cell {
        leg,
        op: export.replace("set_count_", "set_"),
        bytes_copied: (mraw.len() + praw.len()) as u64,
        marshal: Some(marshal),
        call,
        total,
        checksum,
        note: format!("{} members, {} probes", members.len(), probes.len()),
    })
}
