//! Unicode string library with multiple implementation strategies.
//!
//! Feature flags control which strategy is used:
//! - `embedded`: Full Unicode tables compiled into WASM (largest, most portable)
//! - `host`: Delegate to JS host via imports (smallest, browser-only)
//! - `ascii`: ASCII-only fallback (tiny, limited functionality)

#![no_std]

extern crate alloc;
#[allow(unused_imports)]
use alloc::string::String;
#[allow(unused_imports)]
use alloc::vec::Vec;

// ══════════════════════════════════════════════════════════════════════════════
// EMBEDDED UNICODE TABLES (Leg 1)
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "embedded")]
mod embedded {
    use alloc::string::String;

    // ─── Unicode Case Mapping Tables ──────────────────────────────────────────
    // These are simplified; real tables from unicode-case crate are larger.
    // Format: (code_point, uppercase_code_point)

    /// Simple case mappings for common scripts.
    /// Real Unicode tables have ~1,400 entries; this is a representative subset.
    static UPPER_MAP: &[(u32, u32)] = &[
        // Latin lowercase a-z → A-Z
        (0x0061, 0x0041), (0x0062, 0x0042), (0x0063, 0x0043), (0x0064, 0x0044),
        (0x0065, 0x0045), (0x0066, 0x0046), (0x0067, 0x0047), (0x0068, 0x0048),
        (0x0069, 0x0049), (0x006A, 0x004A), (0x006B, 0x004B), (0x006C, 0x004C),
        (0x006D, 0x004D), (0x006E, 0x004E), (0x006F, 0x004F), (0x0070, 0x0050),
        (0x0071, 0x0051), (0x0072, 0x0052), (0x0073, 0x0053), (0x0074, 0x0054),
        (0x0075, 0x0055), (0x0076, 0x0056), (0x0077, 0x0057), (0x0078, 0x0058),
        (0x0079, 0x0059), (0x007A, 0x005A),
        // Latin Extended-A
        (0x00E0, 0x00C0), // à → À
        (0x00E1, 0x00C1), // á → Á
        (0x00E2, 0x00C2), // â → Â
        (0x00E3, 0x00C3), // ã → Ã
        (0x00E4, 0x00C4), // ä → Ä
        (0x00E5, 0x00C5), // å → Å
        (0x00E6, 0x00C6), // æ → Æ
        (0x00E7, 0x00C7), // ç → Ç
        (0x00E8, 0x00C8), // è → È
        (0x00E9, 0x00C9), // é → É
        (0x00EA, 0x00CA), // ê → Ê
        (0x00EB, 0x00CB), // ë → Ë
        (0x00EC, 0x00CC), // ì → Ì
        (0x00ED, 0x00CD), // í → Í
        (0x00EE, 0x00CE), // î → Î
        (0x00EF, 0x00CF), // ï → Ï
        (0x00F0, 0x00D0), // ð → Ð
        (0x00F1, 0x00D1), // ñ → Ñ
        (0x00F2, 0x00D2), // ò → Ò
        (0x00F3, 0x00D3), // ó → Ó
        (0x00F4, 0x00D4), // ô → Ô
        (0x00F5, 0x00D5), // õ → Õ
        (0x00F6, 0x00D6), // ö → Ö
        (0x00F8, 0x00D8), // ø → Ø
        (0x00F9, 0x00D9), // ù → Ù
        (0x00FA, 0x00DA), // ú → Ú
        (0x00FB, 0x00DB), // û → Û
        (0x00FC, 0x00DC), // ü → Ü
        (0x00FD, 0x00DD), // ý → Ý
        (0x00FE, 0x00DE), // þ → Þ
        (0x00FF, 0x0178), // ÿ → Ÿ
        // Greek lowercase α-ω → Α-Ω
        (0x03B1, 0x0391), // α → Α
        (0x03B2, 0x0392), // β → Β
        (0x03B3, 0x0393), // γ → Γ
        (0x03B4, 0x0394), // δ → Δ
        (0x03B5, 0x0395), // ε → Ε
        (0x03B6, 0x0396), // ζ → Ζ
        (0x03B7, 0x0397), // η → Η
        (0x03B8, 0x0398), // θ → Θ
        (0x03B9, 0x0399), // ι → Ι
        (0x03BA, 0x039A), // κ → Κ
        (0x03BB, 0x039B), // λ → Λ
        (0x03BC, 0x039C), // μ → Μ
        (0x03BD, 0x039D), // ν → Ν
        (0x03BE, 0x039E), // ξ → Ξ
        (0x03BF, 0x039F), // ο → Ο
        (0x03C0, 0x03A0), // π → Π
        (0x03C1, 0x03A1), // ρ → Ρ
        (0x03C3, 0x03A3), // σ → Σ
        (0x03C4, 0x03A4), // τ → Τ
        (0x03C5, 0x03A5), // υ → Υ
        (0x03C6, 0x03A6), // φ → Φ
        (0x03C7, 0x03A7), // χ → Χ
        (0x03C8, 0x03A8), // ψ → Ψ
        (0x03C9, 0x03A9), // ω → Ω
        // Cyrillic lowercase а-я → А-Я
        (0x0430, 0x0410), (0x0431, 0x0411), (0x0432, 0x0412), (0x0433, 0x0413),
        (0x0434, 0x0414), (0x0435, 0x0415), (0x0436, 0x0416), (0x0437, 0x0417),
        (0x0438, 0x0418), (0x0439, 0x0419), (0x043A, 0x041A), (0x043B, 0x041B),
        (0x043C, 0x041C), (0x043D, 0x041D), (0x043E, 0x041E), (0x043F, 0x041F),
        (0x0440, 0x0420), (0x0441, 0x0421), (0x0442, 0x0422), (0x0443, 0x0423),
        (0x0444, 0x0424), (0x0445, 0x0425), (0x0446, 0x0426), (0x0447, 0x0427),
        (0x0448, 0x0428), (0x0449, 0x0429), (0x044A, 0x042A), (0x044B, 0x042B),
        (0x044C, 0x042C), (0x044D, 0x042D), (0x044E, 0x042E), (0x044F, 0x042F),
    ];

    /// Unicode whitespace characters.
    static WHITESPACE: &[u32] = &[
        0x0009, // Tab
        0x000A, // Line Feed
        0x000B, // Vertical Tab
        0x000C, // Form Feed
        0x000D, // Carriage Return
        0x0020, // Space
        0x0085, // Next Line
        0x00A0, // Non-breaking Space
        0x1680, // Ogham Space Mark
        0x2000, // En Quad
        0x2001, // Em Quad
        0x2002, // En Space
        0x2003, // Em Space
        0x2004, // Three-Per-Em Space
        0x2005, // Four-Per-Em Space
        0x2006, // Six-Per-Em Space
        0x2007, // Figure Space
        0x2008, // Punctuation Space
        0x2009, // Thin Space
        0x200A, // Hair Space
        0x2028, // Line Separator
        0x2029, // Paragraph Separator
        0x202F, // Narrow No-Break Space
        0x205F, // Medium Mathematical Space
        0x3000, // Ideographic Space
    ];

    /// Look up uppercase mapping using binary search.
    fn lookup_upper(cp: u32) -> Option<u32> {
        // Binary search for efficiency
        let mut lo = 0;
        let mut hi = UPPER_MAP.len();
        while lo < hi {
            let mid = (lo + hi) / 2;
            if UPPER_MAP[mid].0 < cp {
                lo = mid + 1;
            } else if UPPER_MAP[mid].0 > cp {
                hi = mid;
            } else {
                return Some(UPPER_MAP[mid].1);
            }
        }
        None
    }

    /// Convert character to uppercase.
    pub fn char_to_upper(c: char) -> char {
        let cp = c as u32;
        match lookup_upper(cp) {
            Some(upper) => char::from_u32(upper).unwrap_or(c),
            None => c,
        }
    }

    /// Convert string to uppercase.
    pub fn to_upper(s: &str) -> String {
        s.chars().map(char_to_upper).collect()
    }

    /// Convert character to lowercase.
    pub fn char_to_lower(c: char) -> char {
        let cp = c as u32;
        // Reverse lookup: find entry where uppercase == cp
        for &(lower, upper) in UPPER_MAP {
            if upper == cp {
                return char::from_u32(lower).unwrap_or(c);
            }
        }
        c
    }

    /// Convert string to lowercase.
    pub fn to_lower(s: &str) -> String {
        s.chars().map(char_to_lower).collect()
    }

    /// Check if character is whitespace.
    pub fn is_whitespace(c: char) -> bool {
        let cp = c as u32;
        // Binary search
        let mut lo = 0;
        let mut hi = WHITESPACE.len();
        while lo < hi {
            let mid = (lo + hi) / 2;
            if WHITESPACE[mid] < cp {
                lo = mid + 1;
            } else if WHITESPACE[mid] > cp {
                hi = mid;
            } else {
                return true;
            }
        }
        false
    }

    /// Count Unicode characters (not bytes).
    pub fn char_count(s: &str) -> usize {
        s.chars().count()
    }

    /// Get character at index.
    pub fn char_at(s: &str, idx: usize) -> Option<char> {
        s.chars().nth(idx)
    }
}

#[cfg(feature = "embedded")]
pub use embedded::*;

// ══════════════════════════════════════════════════════════════════════════════
// HOST DELEGATION (Leg 2)
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "host")]
mod host {
    use alloc::string::String;
    use alloc::vec::Vec;

    // Imports from JS host — resolved at WebAssembly.instantiate() time
    #[link(wasm_import_module = "host")]
    extern "C" {
        /// Convert string to uppercase via host.
        /// Input: (ptr, len) of UTF-8 string
        /// Output: writes result to out_ptr, returns length
        fn _host_to_upper(ptr: *const u8, len: usize, out_ptr: *mut u8, out_cap: usize) -> usize;

        /// Convert string to lowercase via host.
        fn _host_to_lower(ptr: *const u8, len: usize, out_ptr: *mut u8, out_cap: usize) -> usize;

        /// Check if character is whitespace via host.
        fn _host_is_whitespace(cp: u32) -> i32;

        /// Count grapheme clusters via host (for emoji etc).
        fn _host_char_count(ptr: *const u8, len: usize) -> usize;
    }

    /// Convert string to uppercase via host.
    pub fn to_upper(s: &str) -> String {
        // Allocate buffer for result (UTF-8 can expand 4x worst case)
        let mut buf = Vec::with_capacity(s.len() * 4);
        buf.resize(s.len() * 4, 0u8);

        let len = unsafe {
            _host_to_upper(s.as_ptr(), s.len(), buf.as_mut_ptr(), buf.capacity())
        };

        buf.truncate(len);
        String::from_utf8(buf).unwrap_or_else(|_| String::from(s))
    }

    /// Convert string to lowercase via host.
    pub fn to_lower(s: &str) -> String {
        let mut buf = Vec::with_capacity(s.len() * 4);
        buf.resize(s.len() * 4, 0u8);

        let len = unsafe {
            _host_to_lower(s.as_ptr(), s.len(), buf.as_mut_ptr(), buf.capacity())
        };

        buf.truncate(len);
        String::from_utf8(buf).unwrap_or_else(|_| String::from(s))
    }

    /// Check if character is whitespace via host.
    pub fn is_whitespace(c: char) -> bool {
        unsafe { _host_is_whitespace(c as u32) != 0 }
    }

    /// Count Unicode characters (delegates to host for grapheme accuracy).
    pub fn char_count(s: &str) -> usize {
        unsafe { _host_char_count(s.as_ptr(), s.len()) }
    }

    /// Character to uppercase.
    pub fn char_to_upper(c: char) -> char {
        let s: String = core::iter::once(c).collect();
        to_upper(&s).chars().next().unwrap_or(c)
    }

    /// Character to lowercase.
    pub fn char_to_lower(c: char) -> char {
        let s: String = core::iter::once(c).collect();
        to_lower(&s).chars().next().unwrap_or(c)
    }

    /// Get character at index.
    pub fn char_at(s: &str, idx: usize) -> Option<char> {
        s.chars().nth(idx)
    }
}

#[cfg(feature = "host")]
pub use host::*;

// ══════════════════════════════════════════════════════════════════════════════
// ASCII-ONLY FALLBACK (Legs 3 & 4)
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "ascii")]
mod ascii {
    use alloc::string::String;

    /// Convert character to uppercase (ASCII only).
    #[inline]
    pub fn char_to_upper(c: char) -> char {
        if c >= 'a' && c <= 'z' {
            ((c as u8) - 32) as char
        } else {
            c
        }
    }

    /// Convert string to uppercase (ASCII only).
    pub fn to_upper(s: &str) -> String {
        s.chars().map(char_to_upper).collect()
    }

    /// Convert character to lowercase (ASCII only).
    #[inline]
    pub fn char_to_lower(c: char) -> char {
        if c >= 'A' && c <= 'Z' {
            ((c as u8) + 32) as char
        } else {
            c
        }
    }

    /// Convert string to lowercase (ASCII only).
    pub fn to_lower(s: &str) -> String {
        s.chars().map(char_to_lower).collect()
    }

    /// Check if character is whitespace (ASCII only).
    #[inline]
    pub fn is_whitespace(c: char) -> bool {
        matches!(c, ' ' | '\t' | '\n' | '\r' | '\x0B' | '\x0C')
    }

    /// Count characters (just iterates chars - no grapheme awareness).
    pub fn char_count(s: &str) -> usize {
        s.chars().count()
    }

    /// Get character at index.
    pub fn char_at(s: &str, idx: usize) -> Option<char> {
        s.chars().nth(idx)
    }
}

#[cfg(feature = "ascii")]
pub use ascii::*;

// ══════════════════════════════════════════════════════════════════════════════
// WASM EXPORTS
// ══════════════════════════════════════════════════════════════════════════════

/// Shared memory for string I/O.
///
/// SAFETY: WASM is single-threaded, so static mut is safe here. The warnings
/// about mutable statics are for multi-threaded scenarios that don't apply.
#[allow(static_mut_refs)]
static mut BUFFER: [u8; 4096] = [0; 4096];

const BUFFER_LEN: usize = 4096;

/// Write a string to the shared buffer, returning length.
#[allow(static_mut_refs)]
fn write_to_buffer(s: &str) -> usize {
    let bytes = s.as_bytes();
    let len = bytes.len().min(BUFFER_LEN);
    unsafe {
        core::ptr::copy_nonoverlapping(bytes.as_ptr(), BUFFER.as_mut_ptr(), len);
    }
    len
}

/// Read a string from the shared buffer.
#[allow(static_mut_refs)]
fn read_from_buffer(len: usize) -> &'static str {
    unsafe {
        let slice = core::slice::from_raw_parts(BUFFER.as_ptr(), len.min(BUFFER_LEN));
        core::str::from_utf8_unchecked(slice)
    }
}

/// Get pointer to shared buffer.
#[unsafe(no_mangle)]
#[allow(static_mut_refs)]
pub extern "C" fn get_buffer_ptr() -> *mut u8 {
    unsafe { BUFFER.as_mut_ptr() }
}

/// Convert string in buffer to uppercase, return new length.
#[unsafe(no_mangle)]
pub extern "C" fn wasm_to_upper(len: usize) -> usize {
    let s = read_from_buffer(len);
    let result = to_upper(s);
    write_to_buffer(&result)
}

/// Convert string in buffer to lowercase, return new length.
#[unsafe(no_mangle)]
pub extern "C" fn wasm_to_lower(len: usize) -> usize {
    let s = read_from_buffer(len);
    let result = to_lower(s);
    write_to_buffer(&result)
}

/// Check if code point is whitespace.
#[unsafe(no_mangle)]
pub extern "C" fn wasm_is_whitespace(cp: u32) -> i32 {
    match char::from_u32(cp) {
        Some(c) => if is_whitespace(c) { 1 } else { 0 },
        None => 0,
    }
}

/// Count characters in string in buffer.
#[unsafe(no_mangle)]
pub extern "C" fn wasm_char_count(len: usize) -> usize {
    let s = read_from_buffer(len);
    char_count(s)
}

// ══════════════════════════════════════════════════════════════════════════════
// PANIC HANDLER
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[cfg(not(test))]
mod alloc_impl {
    use core::alloc::{GlobalAlloc, Layout};
    use core::sync::atomic::{AtomicUsize, Ordering};

    struct BumpAllocator;

    /// SAFETY: WASM is single-threaded, but we use atomics to satisfy the
    /// GlobalAlloc trait which requires thread safety.
    static mut HEAP: [u8; 32768] = [0; 32768];
    static HEAP_PTR: AtomicUsize = AtomicUsize::new(0);
    const HEAP_SIZE: usize = 32768;

    unsafe impl GlobalAlloc for BumpAllocator {
        #[allow(static_mut_refs)]
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            let align = layout.align();
            let size = layout.size();
            let ptr = HEAP_PTR.load(Ordering::Relaxed);
            let aligned = (ptr + align - 1) & !(align - 1);
            let new_ptr = aligned + size;
            if new_ptr > HEAP_SIZE {
                core::ptr::null_mut()
            } else {
                HEAP_PTR.store(new_ptr, Ordering::Relaxed);
                HEAP.as_mut_ptr().add(aligned)
            }
        }

        unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {}
    }

    #[global_allocator]
    static ALLOCATOR: BumpAllocator = BumpAllocator;
}

// ══════════════════════════════════════════════════════════════════════════════
// TESTS
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_to_upper_ascii() {
        assert_eq!(to_upper("hello"), "HELLO");
    }

    #[test]
    fn test_to_lower_ascii() {
        assert_eq!(to_lower("HELLO"), "hello");
    }

    #[test]
    fn test_is_whitespace_space() {
        assert!(is_whitespace(' '));
        assert!(is_whitespace('\t'));
        assert!(is_whitespace('\n'));
        assert!(!is_whitespace('a'));
    }

    #[test]
    fn test_char_count() {
        assert_eq!(char_count("hello"), 5);
    }

    #[cfg(feature = "embedded")]
    #[test]
    fn test_to_upper_unicode() {
        assert_eq!(to_upper("café"), "CAFÉ");
        assert_eq!(to_upper("naïve"), "NAÏVE");
    }

    #[cfg(feature = "embedded")]
    #[test]
    fn test_to_upper_greek() {
        assert_eq!(to_upper("αβγ"), "ΑΒΓ");
    }

    #[cfg(feature = "embedded")]
    #[test]
    fn test_unicode_whitespace() {
        assert!(is_whitespace('\u{00A0}')); // Non-breaking space
        assert!(is_whitespace('\u{3000}')); // Ideographic space
    }
}
