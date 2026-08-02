//! 020 — collections ABI harness.
//!
//! One process per (leg, op) cell. Nothing is compared inside a process, which
//! is the fix for the ordering bias documented in issue #52 (see 008's
//! "-Oz vs -O3 — RETRACTED"). The runner script additionally sweeps the legs in
//! forward and reverse order and the README shows both.
//!
//! Usage:
//!   collections_host --leg <leg> --op <op> [--rounds N] [--warmup N] [--json]
//!
//! Every op asserts parity against a natively-computed reference checksum
//! before any timing happens; a mismatch is a hard error, never a warning.

mod component_leg;
mod core_leg;
mod data;
mod externref_leg;

use anyhow::{bail, Result};

pub struct Timing {
    pub median_ns: f64,
    pub min_ns: f64,
    pub max_ns: f64,
}

pub fn stats(mut v: Vec<f64>) -> Timing {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    Timing {
        median_ns: v[v.len() / 2],
        min_ns: v[0],
        max_ns: v[v.len() - 1],
    }
}

/// Run `f` warmup+rounds times, return per-round nanoseconds and the last
/// checksum it produced. The checksum is threaded out (and printed) so nothing
/// in the loop can be optimised away.
pub fn bench<F: FnMut() -> Result<u64>>(
    warmup: usize,
    rounds: usize,
    mut f: F,
) -> Result<(Timing, u64)> {
    for _ in 0..warmup {
        f()?;
    }
    let mut times = Vec::with_capacity(rounds);
    let mut sum = 0u64;
    for _ in 0..rounds {
        let t = std::time::Instant::now();
        let c = f()?;
        times.push(t.elapsed().as_nanos() as f64);
        sum = c;
    }
    Ok((stats(times), sum))
}

pub struct Cell {
    pub leg: &'static str,
    pub op: String,
    pub bytes_copied: u64,
    pub marshal: Option<Timing>,
    pub call: Timing,
    pub total: Timing,
    pub checksum: u64,
    pub note: String,
}

impl Cell {
    fn emit(&self, json: bool) {
        let m = |t: &Option<Timing>| match t {
            Some(t) => format!(
                "{{\"median_ns\":{:.0},\"min_ns\":{:.0},\"max_ns\":{:.0}}}",
                t.median_ns, t.min_ns, t.max_ns
            ),
            None => "null".to_string(),
        };
        let s = |t: &Timing| {
            format!(
                "{{\"median_ns\":{:.0},\"min_ns\":{:.0},\"max_ns\":{:.0}}}",
                t.median_ns, t.min_ns, t.max_ns
            )
        };
        if json {
            println!(
                "{{\"leg\":\"{}\",\"op\":\"{}\",\"bytes\":{},\"marshal\":{},\"call\":{},\"total\":{},\"checksum\":\"{}\",\"note\":\"{}\"}}",
                self.leg,
                self.op,
                self.bytes_copied,
                m(&self.marshal),
                s(&self.call),
                s(&self.total),
                self.checksum,
                self.note
            );
        } else {
            println!(
                "{:<14} {:<14} bytes={:<9} marshal={:>10} call={:>10} total={:>10}  ck={:#018x} {}",
                self.leg,
                self.op,
                self.bytes_copied,
                self.marshal
                    .as_ref()
                    .map(|t| format!("{:.0}ns", t.median_ns))
                    .unwrap_or_else(|| "fused".into()),
                format!("{:.0}ns", self.call.median_ns),
                format!("{:.0}ns", self.total.median_ns),
                self.checksum,
                self.note
            );
        }
    }
}

/// Write the exact workload (and the reference checksums) to disk so the Node
/// leg benchmarks byte-identical data instead of a reimplemented generator.
/// Reimplementing the LCG in JS would be one more place for the two sides to
/// silently disagree, which is the failure mode this whole experiment is about.
fn dump_workload(dir: &str) -> Result<()> {
    use std::io::Write;
    std::fs::create_dir_all(dir)?;
    let w = |name: &str, bytes: &[u8]| -> Result<()> {
        let mut f = std::fs::File::create(format!("{dir}/{name}"))?;
        f.write_all(bytes)?;
        Ok(())
    };
    let strs = data::strings();
    w("strings.txt", strs.join("\n").as_bytes())?;
    let xs = data::list_u32();
    w("list.bin", &xs.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>())?;
    let entries = data::map_entries();
    let probes = data::map_probes(&entries);
    w("map_keys.txt", entries.iter().map(|e| e.0.as_str()).collect::<Vec<_>>().join("\n").as_bytes())?;
    w("map_vals.bin", &entries.iter().flat_map(|e| e.1.to_le_bytes()).collect::<Vec<u8>>())?;
    w("map_probes.txt", probes.join("\n").as_bytes())?;
    let members = data::set_members();
    let sprobes = data::set_probes();
    let words = data::set_bitset_words(&members);
    w("set_members.bin", &members.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>())?;
    w("set_probes.bin", &sprobes.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>())?;
    w("set_words.bin", &words.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>())?;
    let ref_str: u64 = strs.iter().fold(0u64, |a, s| a.wrapping_add(data::ref_str_stats(s)));
    w(
        "reference.json",
        format!(
            "{{\"str\":\"{:#x}\",\"list\":\"{:#x}\",\"map\":\"{:#x}\",\"set\":\"{}\"}}",
            ref_str,
            data::ref_list_sum(&xs),
            data::ref_map_lookup(&entries, &probes),
            data::ref_set_count(&members, &sprobes)
        )
        .as_bytes(),
    )?;
    eprintln!("workload dumped to {dir}");
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mut leg = String::new();
    let mut op = String::new();
    let mut rounds = 9usize;
    let mut warmup = 3usize;
    let mut json = false;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--leg" => {
                leg = args[i + 1].clone();
                i += 2;
            }
            "--op" => {
                op = args[i + 1].clone();
                i += 2;
            }
            "--rounds" => {
                rounds = args[i + 1].parse()?;
                i += 2;
            }
            "--warmup" => {
                warmup = args[i + 1].parse()?;
                i += 2;
            }
            "--json" => {
                json = true;
                i += 1;
            }
            "--dump" => {
                dump_workload(&args[i + 1])?;
                return Ok(());
            }
            other => bail!("unknown arg {other}"),
        }
    }
    if leg.is_empty() || op.is_empty() {
        bail!("usage: collections_host --leg <leg> --op <op> [--rounds N] [--json]");
    }

    let cell = match leg.as_str() {
        "wat" => core_leg::run("wat", "../output/wat_collections.wasm", false, &op, warmup, rounds)?,
        "rust_manual" => core_leg::run(
            "rust_manual",
            "../output/rust_manual.wasm",
            false,
            &op,
            warmup,
            rounds,
        )?,
        "assemblyscript" => core_leg::run(
            "assemblyscript",
            "../output/assemblyscript.wasm",
            true,
            &op,
            warmup,
            rounds,
        )?,
        "externref" => externref_leg::run(&op, warmup, rounds)?,
        "component" => component_leg::run(&op, warmup, rounds)?,
        other => bail!("unknown leg {other}"),
    };
    cell.emit(json);
    Ok(())
}
