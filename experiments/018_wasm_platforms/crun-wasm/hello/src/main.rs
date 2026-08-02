// Minimal WASI command for the crun-wasm leg: proves the module is executed by
// crun's built-in wasmedge handler, not by a Linux process inside a container.
fn main() {
    println!("hello from wasm, run by crun+wasmedge — no Linux userspace in this container");
}
