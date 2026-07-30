// Same unconditional-loop premise as loop_pure, but also grows a Vec each
// iteration — tests whether memory growth changes termination behavior
// (e.g. if the engine can only reach a "safepoint" it can safely stop at
// between certain operations, allocation-heavy code might hit safepoints
// at a different rate than pure arithmetic does).
//
// Chunk size and tick frequency are chosen to keep total growth bounded
// over a realistic multi-hundred-ms test window (see README for the
// measured growth rate) rather than racing the loop's own allocator into
// an OOM trap before the external terminate() call ever happens — that
// would test "did the program crash itself", not "does terminate() work".
const TICK_EVERY: u64 = 10_000;
const CHUNK_BYTES: usize = 32;

#[link(wasm_import_module = "env")]
extern "C" {
    fn heartbeat_tick();
}

fn main() {
    let mut store: Vec<Vec<u8>> = Vec::new();
    let mut i: u64 = 0;
    loop {
        store.push(vec![0u8; CHUNK_BYTES]);
        i = i.wrapping_add(1);
        if i % TICK_EVERY == 0 {
            unsafe { heartbeat_tick() };
        }
        std::hint::black_box(store.len());
    }
}
