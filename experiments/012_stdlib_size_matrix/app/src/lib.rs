//! Mastermind game logic for WASM.
//!
//! A simplified port of mvl-lang/mvl/examples/mastermind to Rust.
//! Uses the stdlib for string parsing and random number generation.

#![no_std]

extern crate alloc;
use alloc::string::String;
use alloc::vec::Vec;

use mvl_stdlib::random;
use mvl_stdlib::strings;

// ══════════════════════════════════════════════════════════════════════════════
// Types
// ══════════════════════════════════════════════════════════════════════════════

/// Scoring result for one guess.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Feedback {
    pub blacks: u8,
    pub whites: u8,
}

/// Outcome of parsing a guess line.
pub enum GuessResult {
    Guess(Vec<u8>),
    Invalid,
    Empty,
}

// ══════════════════════════════════════════════════════════════════════════════
// Game Logic
// ══════════════════════════════════════════════════════════════════════════════

/// Generate a random secret code of 4 colors (1-6).
pub fn generate_secret() -> Vec<u8> {
    alloc::vec![
        random::int_range(1, 6) as u8,
        random::int_range(1, 6) as u8,
        random::int_range(1, 6) as u8,
        random::int_range(1, 6) as u8,
    ]
}

/// Count positions where guess matches secret exactly.
fn count_blacks(secret: &[u8], guess: &[u8]) -> u8 {
    let mut n = 0u8;
    for i in 0..secret.len().min(guess.len()) {
        if secret[i] == guess[i] {
            n += 1;
        }
    }
    n
}

/// Count occurrences of `color` in `xs` at positions where `xs[i] != other[i]`.
fn count_color_at_mismatch(xs: &[u8], other: &[u8], color: u8) -> u8 {
    let mut n = 0u8;
    for i in 0..xs.len().min(other.len()) {
        if xs[i] == color && xs[i] != other[i] {
            n += 1;
        }
    }
    n
}

/// Score `guess` against `secret` (classic Mastermind rules).
pub fn score_guess(secret: &[u8], guess: &[u8]) -> Feedback {
    let blacks = count_blacks(secret, guess);
    let mut whites = 0u8;
    for color in 1..=6 {
        let in_secret = count_color_at_mismatch(secret, guess, color);
        let in_guess = count_color_at_mismatch(guess, secret, color);
        whites += in_secret.min(in_guess);
    }
    Feedback { blacks, whites }
}

// ══════════════════════════════════════════════════════════════════════════════
// Parsing
// ══════════════════════════════════════════════════════════════════════════════

/// Parse a guess line like "1 2 3 4" into a code.
pub fn parse_guess(input: &str) -> GuessResult {
    let trimmed = strings::trim(input);
    if strings::is_empty(trimmed) {
        return GuessResult::Empty;
    }

    let parts = strings::split(trimmed, " ");
    let non_empty: Vec<&str> = parts.into_iter().filter(|s| !s.is_empty()).collect();

    if non_empty.len() != 4 {
        return GuessResult::Invalid;
    }

    let mut code = Vec::with_capacity(4);
    for part in non_empty {
        match strings::parse_int(part) {
            Some(n) if n >= 1 && n <= 6 => code.push(n as u8),
            _ => return GuessResult::Invalid,
        }
    }

    GuessResult::Guess(code)
}

// ══════════════════════════════════════════════════════════════════════════════
// Display
// ══════════════════════════════════════════════════════════════════════════════

/// Display name for a color number (1-6).
pub fn color_name(n: u8) -> &'static str {
    match n {
        1 => "red",
        2 => "green",
        3 => "blue",
        4 => "yellow",
        5 => "orange",
        6 => "purple",
        _ => "?",
    }
}

/// Render a code as e.g. "red green blue yellow".
pub fn render_code(code: &[u8]) -> String {
    let names: Vec<&str> = code.iter().map(|&n| color_name(n)).collect();
    let mut result = String::new();
    for (i, name) in names.iter().enumerate() {
        if i > 0 {
            result.push(' ');
        }
        result.push_str(name);
    }
    result
}

/// Render scoring feedback as e.g. "blacks: 2  whites: 1".
pub fn render_feedback(fb: Feedback) -> String {
    let mut result = String::from("blacks: ");
    result.push((fb.blacks + b'0') as char);
    result.push_str("  whites: ");
    result.push((fb.whites + b'0') as char);
    result
}

// ══════════════════════════════════════════════════════════════════════════════
// WASM Exports
// ══════════════════════════════════════════════════════════════════════════════

/// Initialize the RNG with a seed.
#[unsafe(no_mangle)]
pub extern "C" fn init(seed: u64) {
    random::seed(seed);
}

/// Generate a new secret and return it as a 4-byte value.
/// Each byte is a color 1-6.
#[unsafe(no_mangle)]
pub extern "C" fn new_game() -> u32 {
    let secret = generate_secret();
    ((secret[0] as u32) << 24)
        | ((secret[1] as u32) << 16)
        | ((secret[2] as u32) << 8)
        | (secret[3] as u32)
}

/// Score a guess against a secret.
/// Both are packed as 4-byte values.
/// Returns (blacks << 8) | whites.
#[unsafe(no_mangle)]
pub extern "C" fn score(secret: u32, guess: u32) -> u16 {
    let s = [
        ((secret >> 24) & 0xFF) as u8,
        ((secret >> 16) & 0xFF) as u8,
        ((secret >> 8) & 0xFF) as u8,
        (secret & 0xFF) as u8,
    ];
    let g = [
        ((guess >> 24) & 0xFF) as u8,
        ((guess >> 16) & 0xFF) as u8,
        ((guess >> 8) & 0xFF) as u8,
        (guess & 0xFF) as u8,
    ];
    let fb = score_guess(&s, &g);
    ((fb.blacks as u16) << 8) | (fb.whites as u16)
}

// ══════════════════════════════════════════════════════════════════════════════
// Panic Handler
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

// Global allocator
#[cfg(not(test))]
mod alloc_impl {
    use core::alloc::{GlobalAlloc, Layout};

    struct BumpAllocator;

    static mut HEAP: [u8; 16384] = [0; 16384];
    static mut HEAP_PTR: usize = 0;

    unsafe impl GlobalAlloc for BumpAllocator {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            let align = layout.align();
            let size = layout.size();
            let ptr = HEAP_PTR;
            let aligned = (ptr + align - 1) & !(align - 1);
            let new_ptr = aligned + size;
            if new_ptr > HEAP.len() {
                core::ptr::null_mut()
            } else {
                HEAP_PTR = new_ptr;
                HEAP.as_mut_ptr().add(aligned)
            }
        }

        unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {
            // Bump allocator doesn't deallocate
        }
    }

    #[global_allocator]
    static ALLOCATOR: BumpAllocator = BumpAllocator;
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_score_all_correct() {
        let fb = score_guess(&[1, 2, 3, 4], &[1, 2, 3, 4]);
        assert_eq!(fb, Feedback { blacks: 4, whites: 0 });
    }

    #[test]
    fn test_score_all_wrong_position() {
        let fb = score_guess(&[1, 2, 3, 4], &[4, 3, 2, 1]);
        assert_eq!(fb, Feedback { blacks: 0, whites: 4 });
    }

    #[test]
    fn test_score_mixed() {
        let fb = score_guess(&[1, 2, 3, 4], &[1, 3, 2, 5]);
        assert_eq!(fb, Feedback { blacks: 1, whites: 2 });
    }

    #[test]
    fn test_score_with_repeats() {
        let fb = score_guess(&[1, 1, 2, 2], &[1, 2, 1, 2]);
        assert_eq!(fb, Feedback { blacks: 2, whites: 2 });
    }

    #[test]
    fn test_parse_valid() {
        match parse_guess("1 2 3 4") {
            GuessResult::Guess(code) => assert_eq!(code, vec![1, 2, 3, 4]),
            _ => panic!("Expected valid guess"),
        }
    }

    #[test]
    fn test_parse_invalid_count() {
        match parse_guess("1 2 3") {
            GuessResult::Invalid => {}
            _ => panic!("Expected invalid"),
        }
    }

    #[test]
    fn test_parse_invalid_range() {
        match parse_guess("1 2 3 7") {
            GuessResult::Invalid => {}
            _ => panic!("Expected invalid"),
        }
    }

    #[test]
    fn test_parse_empty() {
        match parse_guess("   ") {
            GuessResult::Empty => {}
            _ => panic!("Expected empty"),
        }
    }
}
