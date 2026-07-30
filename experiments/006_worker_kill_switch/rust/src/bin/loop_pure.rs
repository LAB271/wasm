// Genuinely unconditional: no exit condition, no I/O, no cooperative check
// of any flag. The only concession to observability is a heartbeat tick
// every TICK_EVERY iterations, via a custom (non-WASI) import — this is
// our own external proof-of-life, not a mechanism the loop uses to decide
// whether to keep running. Ticking every iteration would add FFI overhead
// per iteration and skew the loop's own behavior; ticking too rarely would
// make termination timing too coarse. 100_000 is a compromise: at even
// modest tens-of-millions-of-iterations/sec, this still ticks many times
// per second.
const TICK_EVERY: u64 = 100_000;

#[link(wasm_import_module = "env")]
extern "C" {
    fn heartbeat_tick();
}

fn main() {
    let mut i: u64 = 0;
    loop {
        i = i.wrapping_add(1);
        if i % TICK_EVERY == 0 {
            unsafe { heartbeat_tick() };
        }
        // std::hint::black_box prevents the optimizer from proving this
        // loop has no observable effect and eliminating it entirely.
        std::hint::black_box(i);
    }
}
