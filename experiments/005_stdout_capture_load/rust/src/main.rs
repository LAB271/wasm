// Experiment 005 — prints N lines interleaved across stdout/stderr, each
// carrying a per-stream monotonic sequence number, so the browser-side
// harness can verify completeness and ordering rather than just counting
// lines received.
use std::env;

fn main() {
    let n: u64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);

    for i in 0..n {
        println!("OUT {i}");
        eprintln!("ERR {i}");
    }
}
