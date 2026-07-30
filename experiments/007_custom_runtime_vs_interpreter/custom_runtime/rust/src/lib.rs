// The entire "language": one operation (string concatenation), backed by
// a hand-written JS import object — mirroring mvl-lang/mvl-playground's
// actual pattern (handle-based string ops via a custom "runtime" import
// namespace), at the smallest scale that still exercises the same shape.
// No WASI, no interpreter, no standard library runtime — wasm32-unknown-
// unknown, three imported functions, two static scratch buffers.

#[link(wasm_import_module = "runtime")]
extern "C" {
    fn string_new(ptr: i32, len: i32) -> i32;
    fn string_concat(h1: i32, h2: i32) -> i32;
    fn string_write(handle: i32, dest_ptr: i32) -> i32;
}

static mut INPUT_SCRATCH: [u8; 256] = [0; 256];
static mut OUTPUT_SCRATCH: [u8; 256] = [0; 256];
const PREFIX: &str = "Hello, ";

/// Where the host should write the input name's bytes before calling greet().
#[no_mangle]
pub extern "C" fn input_ptr() -> i32 {
    core::ptr::addr_of!(INPUT_SCRATCH) as i32
}

/// Where the host should read the result bytes after greet() returns.
#[no_mangle]
pub extern "C" fn output_ptr() -> i32 {
    core::ptr::addr_of!(OUTPUT_SCRATCH) as i32
}

/// name_len bytes have already been written at input_ptr(). Returns the
/// result length (bytes available at output_ptr()).
#[no_mangle]
pub extern "C" fn greet(name_len: i32) -> i32 {
    unsafe {
        let prefix_handle = string_new(PREFIX.as_ptr() as i32, PREFIX.len() as i32);
        let name_handle = string_new(core::ptr::addr_of!(INPUT_SCRATCH) as i32, name_len);
        let result_handle = string_concat(prefix_handle, name_handle);
        string_write(result_handle, core::ptr::addr_of!(OUTPUT_SCRATCH) as i32)
    }
}
