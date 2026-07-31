// The payload — deliberately trivial and import-free, mirroring the
// article's own example ("amount * 1.15, add a markup"). The point of this
// experiment is measuring instantiate+call+teardown overhead in a native
// host, not marshalling cost or runtime-import cost (those are what
// experiments 007/008 already measure) — a zero-import module isolates
// exactly the cost this experiment exists to find.
#[no_mangle]
pub extern "C" fn transform(amount_cents: i64) -> i64 {
    amount_cents + (amount_cents * 15 / 100)
}
