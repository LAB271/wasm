//! Leg 5 — Component Model / WIT, hosted by wasmtime's component API.
//!
//! The canonical ABI copies *inside* the call: there is no point at which the
//! host has written the data and has not yet called. So `marshal` here is not
//! measured by a separate loop like the linear-memory legs — it is derived from
//! a `noop-*` export with the identical signature that ignores its argument.
//! That is stated in the README rather than quietly folded into a total.

use crate::data::{self, *};
use crate::{bench, Cell};
use anyhow::Result;
use wasmtime::component::{Component, Linker};
use wasmtime::{Config, Engine, Store};

const PATH: &str = "../output/component.wasm";

pub fn run(op: &str, warmup: usize, rounds: usize) -> Result<Cell> {
    let mut config = Config::new();
    config.wasm_component_model(true);
    let engine = Engine::new(&config)?;
    let component =
        Component::from_file(&engine, PATH)?;
    let linker: Linker<()> = Linker::new(&engine);
    let mut store = Store::new(&engine, ());
    let instance = linker.instantiate(&mut store, &component)?;

    match op {
        "str" => {
            let strs = data::strings();
            let bytes: u64 = strs.iter().map(|s| s.len() as u64).sum();
            let reference = strs.iter().fold(0u64, |a, s| a.wrapping_add(ref_str_stats(s)));
            let f = instance
                .get_typed_func::<(&str,), (u64,)>(&mut store, "str-stats")?;
            let nf = instance
                .get_typed_func::<(&str,), (u64,)>(&mut store, "noop-str")?;

            let (marshal, _) = bench(warmup, rounds, || {
                let mut acc = 0u64;
                for s in &strs {
                    acc = acc.wrapping_add(nf.call(&mut store, (s.as_str(),))?.0);
                }
                Ok(acc)
            })?;
            let (total, checksum) = bench(warmup, rounds, || {
                let mut acc = 0u64;
                for s in &strs {
                    acc = acc.wrapping_add(f.call(&mut store, (s.as_str(),))?.0);
                }
                Ok(acc)
            })?;
            anyhow::ensure!(
                checksum == reference,
                "component str parity FAILED: {checksum:#x} != {reference:#x}"
            );
            let call = derive(&total, &marshal);
            Ok(Cell {
                leg: "component",
                op: "str".into(),
                bytes_copied: bytes,
                marshal: Some(marshal),
                call,
                total,
                checksum,
                note: format!("{} strings, utf8; call = total - noop", N_STRINGS),
            })
        }

        "callcost" => {
            let nf = instance.get_typed_func::<(&str,), (u64,)>(&mut store, "noop-str")?;
            let (call, checksum) = bench(warmup, rounds, || {
                let mut acc = 0u64;
                for _ in 0..N_STRINGS {
                    acc = acc.wrapping_add(nf.call(&mut store, ("x",))?.0);
                }
                Ok(acc)
            })?;
            Ok(Cell {
                leg: "component",
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
                note: format!("{} calls, 1-char string via canonical ABI", N_STRINGS),
            })
        }

        // Second call-cost probe with a *list* rather than a string argument, to
        // check whether the per-call overhead is really fixed or is mostly the
        // string path's `cabi_realloc` round-trip.
        "callcost_list" => {
            let nf = instance.get_typed_func::<(&[u32],), (u64,)>(&mut store, "noop-list-u32")?;
            let one = [7u32];
            let (call, checksum) = bench(warmup, rounds, || {
                let mut acc = 0u64;
                for _ in 0..N_STRINGS {
                    acc = acc.wrapping_add(nf.call(&mut store, (one.as_slice(),))?.0);
                }
                Ok(acc)
            })?;
            Ok(Cell {
                leg: "component",
                op: "callcost_list".into(),
                bytes_copied: 0,
                marshal: None,
                call: crate::Timing { median_ns: call.median_ns, min_ns: call.min_ns, max_ns: call.max_ns },
                total: call,
                checksum,
                note: format!("{} calls, 1-element list<u32> via canonical ABI", N_STRINGS),
            })
        }

        "list" => {
            let xs = data::list_u32();
            let reference = ref_list_sum(&xs);
            let f = instance
                .get_typed_func::<(&[u32],), (u64,)>(&mut store, "list-sum-u32")?;
            let nf = instance
                .get_typed_func::<(&[u32],), (u64,)>(&mut store, "noop-list-u32")?;
            let (marshal, _) = bench(warmup, rounds, || {
                let r = nf.call(&mut store, (xs.as_slice(),))?.0;
                Ok(r)
            })?;
            let (total, checksum) = bench(warmup, rounds, || {
                let r = f.call(&mut store, (xs.as_slice(),))?.0;
                Ok(r)
            })?;
            anyhow::ensure!(
                checksum == reference,
                "component list parity FAILED: {checksum:#x} != {reference:#x}"
            );
            let call = derive(&total, &marshal);
            Ok(Cell {
                leg: "component",
                op: "list".into(),
                bytes_copied: (xs.len() * 4) as u64,
                marshal: Some(marshal),
                call,
                total,
                checksum,
                note: format!("{} u32; call = total - noop", N_LIST),
            })
        }

        "map_sorted" => {
            let entries = data::map_entries();
            let probes = data::map_probes(&entries);
            let reference = ref_map_lookup(&entries, &probes);
            // Canonical ABI copy: 12 bytes per tuple element (ptr+len+u32,
            // 4-byte aligned) plus the key bytes, and 8 bytes per probe plus
            // its bytes.
            let bytes = entries.iter().map(|e| e.0.len() as u64 + 12).sum::<u64>()
                + probes.iter().map(|p| p.len() as u64 + 8).sum::<u64>();
            let f = instance
                .get_typed_func::<(&[(String, u32)], &[String]), (u64,)>(
                    &mut store,
                    "map-lookup-sorted",
                )?;
            let nf = instance
                .get_typed_func::<(&[(String, u32)], &[String]), (u64,)>(&mut store, "noop-map")?;
            let (marshal, _) = bench(warmup, rounds, || {
                let r = nf.call(&mut store, (entries.as_slice(), probes.as_slice()))?.0;
                Ok(r)
            })?;
            let (total, checksum) = bench(warmup, rounds, || {
                let r = f.call(&mut store, (entries.as_slice(), probes.as_slice()))?.0;
                Ok(r)
            })?;
            anyhow::ensure!(
                checksum == reference,
                "component map parity FAILED: {checksum:#x} != {reference:#x}"
            );
            let call = derive(&total, &marshal);
            Ok(Cell {
                leg: "component",
                op: "map_sorted".into(),
                bytes_copied: bytes,
                marshal: Some(marshal),
                call,
                total,
                checksum,
                note: format!("{} entries / {} probes; call = total - noop", MAP_ENTRIES, MAP_PROBES),
            })
        }

        "set_sorted" | "set_bitset" => {
            let members = data::set_members();
            let probes = data::set_probes();
            let reference = ref_set_count(&members, &probes);
            let nf = instance
                .get_typed_func::<(&[u32], &[u32]), (u64,)>(&mut store, "noop-set")?;
            if op == "set_sorted" {
                let f = instance
                    .get_typed_func::<(&[u32], &[u32]), (u64,)>(&mut store, "set-count-sorted")?;
                let (marshal, _) = bench(warmup, rounds, || {
                    let r = nf.call(&mut store, (members.as_slice(), probes.as_slice()))?.0;
                    Ok(r)
                })?;
                let (total, checksum) = bench(warmup, rounds, || {
                    let r = f.call(&mut store, (members.as_slice(), probes.as_slice()))?.0;
                    Ok(r)
                })?;
                anyhow::ensure!(
                    checksum == reference,
                    "component set_sorted parity FAILED: {checksum} != {reference}"
                );
                let call = derive(&total, &marshal);
                return Ok(Cell {
                    leg: "component",
                    op: "set_sorted".into(),
                    bytes_copied: ((members.len() + probes.len()) * 4) as u64,
                    marshal: Some(marshal),
                    call,
                    total,
                    checksum,
                    note: "call = total - noop".into(),
                });
            }
            let words = data::set_bitset_words(&members);
            let f = instance
                .get_typed_func::<(&[u64], &[u32]), (u64,)>(&mut store, "set-count-bitset")?;
            // noop-set takes list<u32>; approximate the lowering cost with an
            // equally sized u32 list so the subtraction stays honest.
            let words_as_u32: Vec<u32> = vec![0u32; words.len() * 2];
            let (marshal, _) = bench(warmup, rounds, || {
                let r = nf
                    .call(&mut store, (words_as_u32.as_slice(), probes.as_slice()))?
                    .0;
                Ok(r)
            })?;
            let (total, checksum) = bench(warmup, rounds, || {
                let r = f.call(&mut store, (words.as_slice(), probes.as_slice()))?.0;
                Ok(r)
            })?;
            anyhow::ensure!(
                checksum == reference,
                "component set_bitset parity FAILED: {checksum} != {reference}"
            );
            let call = derive(&total, &marshal);
            Ok(Cell {
                leg: "component",
                op: "set_bitset".into(),
                bytes_copied: (words.len() * 8 + probes.len() * 4) as u64,
                marshal: Some(marshal),
                call,
                total,
                checksum,
                note: "call = total - noop(equal-byte u32 list)".into(),
            })
        }

        other => anyhow::bail!("component leg has no op {other}"),
    }
}

/// `call` for this leg is a derived quantity, not a measurement. Clamped at 0
/// so a noise-dominated cell reports zero rather than a negative time.
fn derive(total: &crate::Timing, marshal: &crate::Timing) -> crate::Timing {
    crate::Timing {
        median_ns: (total.median_ns - marshal.median_ns).max(0.0),
        min_ns: (total.min_ns - marshal.max_ns).max(0.0),
        max_ns: (total.max_ns - marshal.min_ns).max(0.0),
    }
}
