//! Leg 6 — `externref`. The collection stays host-side; the guest gets an
//! opaque handle and calls back through imports for every element.
//!
//! `bytes_copied` is genuinely 0 for every op here. `marshal` is the cost of
//! wrapping the host value in a GC-managed `ExternRef`, which is O(1) per
//! collection, not O(n) per element.

use crate::data::{self, *};
use crate::{bench, Cell};
use anyhow::Result;
use std::collections::{HashMap, HashSet};
use wasmtime::{Engine, ExternRef, Linker, Module, Rooted, Store};

const PATH: &str = "../output/wat_externref.wasm";

/// Whatever the host already had. No wire format, no copy, no agreement.
pub enum HV {
    Str(String),
    VecU32(Vec<u32>),
    VecStr(Vec<String>),
    Map(HashMap<String, u32>),
    Set(HashSet<u32>),
}

type Ref = Option<Rooted<ExternRef>>;

fn linker(engine: &Engine) -> Result<Linker<()>> {
    use wasmtime::{bail, Caller, Result as WResult};
    let mut l: Linker<()> = Linker::new(engine);

    l.func_wrap(
        "host",
        "str_bytes_len",
        |c: Caller<'_, ()>, r: Ref| -> WResult<i32> {
            match hv(&c, &r)? {
                HV::Str(s) => Ok(s.len() as i32),
                _ => bail!("not a string"),
            }
        },
    )?;

    // UTF-8 decode of one scalar at a byte offset -> (cp << 32) | next_offset.
    l.func_wrap(
        "host",
        "str_cp_at",
        |c: Caller<'_, ()>, r: Ref, off: i32| -> WResult<i64> {
            match hv(&c, &r)? {
                HV::Str(s) => match s[off as usize..].chars().next() {
                    Some(ch) => Ok(((ch as i64) << 32) | (off as i64 + ch.len_utf8() as i64)),
                    None => bail!("offset past end of string"),
                },
                _ => bail!("not a string"),
            }
        },
    )?;

    l.func_wrap("host", "vec_len", |c: Caller<'_, ()>, r: Ref| -> WResult<i32> {
        match hv(&c, &r)? {
            HV::VecU32(v) => Ok(v.len() as i32),
            HV::VecStr(v) => Ok(v.len() as i32),
            _ => bail!("not a vec"),
        }
    })?;

    l.func_wrap(
        "host",
        "vec_get_u32",
        |c: Caller<'_, ()>, r: Ref, i: i32| -> WResult<i32> {
            match hv(&c, &r)? {
                HV::VecU32(v) => Ok(v[i as usize] as i32),
                _ => bail!("not a u32 vec"),
            }
        },
    )?;

    l.func_wrap(
        "host",
        "map_get_i",
        |c: Caller<'_, ()>, m: Ref, p: Ref, i: i32| -> WResult<i64> {
            let probes = match hv(&c, &p)? {
                HV::VecStr(v) => v,
                _ => bail!("probes is not a string vec"),
            };
            let map = match hv(&c, &m)? {
                HV::Map(m) => m,
                _ => bail!("not a map"),
            };
            Ok(match map.get(&probes[i as usize]) {
                Some(&v) => v as i64,
                None => -1,
            })
        },
    )?;

    l.func_wrap(
        "host",
        "set_has",
        |c: Caller<'_, ()>, r: Ref, x: i32| -> WResult<i32> {
            match hv(&c, &r)? {
                HV::Set(s) => Ok(s.contains(&(x as u32)) as i32),
                _ => bail!("not a set"),
            }
        },
    )?;

    Ok(l)
}

fn hv<'a>(c: &'a wasmtime::Caller<'_, ()>, r: &Ref) -> wasmtime::Result<&'a HV> {
    let r = match r.as_ref() {
        Some(r) => r,
        None => wasmtime::bail!("null externref"),
    };
    match r.data(c)?.and_then(|d| d.downcast_ref::<HV>()) {
        Some(v) => Ok(v),
        None => wasmtime::bail!("externref is not a HV"),
    }
}

pub fn run(op: &str, warmup: usize, rounds: usize) -> Result<Cell> {
    let engine = Engine::default();
    let module = Module::from_file(&engine, PATH)?;
    let mut store = Store::new(&engine, ());
    let instance = linker(&engine)?.instantiate(&mut store, &module)?;

    match op {
        "str" => {
            let strs = data::strings();
            let reference = strs.iter().fold(0u64, |a, s| a.wrapping_add(ref_str_stats(s)));
            let f = instance
                .get_typed_func::<(Ref,), i64>(&mut store, "str_stats")?;

            let (marshal, _) = bench(warmup, rounds, || {
                let mut acc = 0u64;
                for s in &strs {
                    ExternRef::new(&mut store, HV::Str(s.clone()))?;
                    acc += 1;
                }
                Ok(acc)
            })?;

            let refs: Vec<Ref> = strs
                .iter()
                .map(|s| Ok(Some(ExternRef::new(&mut store, HV::Str(s.clone()))?)))
                .collect::<Result<_>>()?;
            let (call, checksum) = bench(warmup, rounds, || {
                let mut acc = 0u64;
                for r in &refs {
                    acc = acc.wrapping_add(f.call(&mut store, (*r,))? as u64);
                }
                Ok(acc)
            })?;
            anyhow::ensure!(
                checksum == reference,
                "externref str parity FAILED: {checksum:#x} != {reference:#x}"
            );
            let (total, _) = bench(warmup, rounds, || {
                let mut acc = 0u64;
                for s in &strs {
                    let r = ExternRef::new(&mut store, HV::Str(s.clone()))?;
                    acc = acc.wrapping_add(f.call(&mut store, (Some(r),))? as u64);
                }
                Ok(acc)
            })?;
            Ok(Cell {
                leg: "externref",
                op: "str".into(),
                bytes_copied: 0,
                marshal: Some(marshal),
                call,
                total,
                checksum,
                note: format!("{} strings, 1 host call per code point", N_STRINGS),
            })
        }

        "list" => {
            let xs = data::list_u32();
            let reference = ref_list_sum(&xs);
            let f = instance
                .get_typed_func::<(Ref,), i64>(&mut store, "list_sum_u32")?;
            let (marshal, _) = bench(warmup, rounds, || {
                ExternRef::new(&mut store, HV::VecU32(xs.clone()))?;
                Ok(1)
            })?;
            let r = Some(ExternRef::new(&mut store, HV::VecU32(xs.clone()))?);
            let (call, checksum) =
                bench(warmup, rounds, || Ok(f.call(&mut store, (r,))? as u64))?;
            anyhow::ensure!(
                checksum == reference,
                "externref list parity FAILED: {checksum:#x} != {reference:#x}"
            );
            let (total, _) = bench(warmup, rounds, || {
                let r = ExternRef::new(&mut store, HV::VecU32(xs.clone()))?;
                Ok(f.call(&mut store, (Some(r),))? as u64)
            })?;
            Ok(Cell {
                leg: "externref",
                op: "list".into(),
                bytes_copied: 0,
                marshal: Some(marshal),
                call,
                total,
                checksum,
                note: format!("{} u32, 1 host call per element", N_LIST),
            })
        }

        "map_host" => {
            let entries = data::map_entries();
            let probes = data::map_probes(&entries);
            let reference = ref_map_lookup(&entries, &probes);
            let map: HashMap<String, u32> = entries.iter().cloned().collect();
            let f = instance
                .get_typed_func::<(Ref, Ref), i64>(&mut store, "map_lookup")?;
            let (marshal, _) = bench(warmup, rounds, || {
                ExternRef::new(&mut store, HV::Map(map.clone()))?;
                ExternRef::new(&mut store, HV::VecStr(probes.clone()))?;
                Ok(2)
            })?;
            let m = Some(ExternRef::new(&mut store, HV::Map(map.clone()))?);
            let p = Some(ExternRef::new(&mut store, HV::VecStr(probes.clone()))?);
            let (call, checksum) =
                bench(warmup, rounds, || Ok(f.call(&mut store, (m, p))? as u64))?;
            anyhow::ensure!(
                checksum == reference,
                "externref map parity FAILED: {checksum:#x} != {reference:#x}"
            );
            let (total, _) = bench(warmup, rounds, || {
                let m = ExternRef::new(&mut store, HV::Map(map.clone()))?;
                let p = ExternRef::new(&mut store, HV::VecStr(probes.clone()))?;
                Ok(f.call(&mut store, (Some(m), Some(p)))? as u64)
            })?;
            Ok(Cell {
                leg: "externref",
                op: "map_host".into(),
                bytes_copied: 0,
                marshal: Some(marshal),
                call,
                total,
                checksum,
                note: format!("{} entries / {} probes, host-side HashMap", MAP_ENTRIES, MAP_PROBES),
            })
        }

        "set_host" => {
            let members = data::set_members();
            let probes = data::set_probes();
            let reference = ref_set_count(&members, &probes);
            let set: HashSet<u32> = members.iter().copied().collect();
            let f = instance
                .get_typed_func::<(Ref, Ref), i64>(&mut store, "set_count")?;
            let (marshal, _) = bench(warmup, rounds, || {
                ExternRef::new(&mut store, HV::Set(set.clone()))?;
                ExternRef::new(&mut store, HV::VecU32(probes.clone()))?;
                Ok(2)
            })?;
            let s = Some(ExternRef::new(&mut store, HV::Set(set.clone()))?);
            let p = Some(ExternRef::new(&mut store, HV::VecU32(probes.clone()))?);
            let (call, checksum) =
                bench(warmup, rounds, || Ok(f.call(&mut store, (s, p))? as u64))?;
            anyhow::ensure!(
                checksum == reference,
                "externref set parity FAILED: {checksum} != {reference}"
            );
            let (total, _) = bench(warmup, rounds, || {
                let s = ExternRef::new(&mut store, HV::Set(set.clone()))?;
                let p = ExternRef::new(&mut store, HV::VecU32(probes.clone()))?;
                Ok(f.call(&mut store, (Some(s), Some(p)))? as u64)
            })?;
            Ok(Cell {
                leg: "externref",
                op: "set_host".into(),
                bytes_copied: 0,
                marshal: Some(marshal),
                call,
                total,
                checksum,
                note: format!("{} members / {} probes, host-side HashSet", SET_MEMBERS, SET_PROBES),
            })
        }

        other => anyhow::bail!("externref leg has no op {other}"),
    }
}
