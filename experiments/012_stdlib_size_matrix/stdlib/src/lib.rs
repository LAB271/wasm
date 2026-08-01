//! MVL-style stdlib for WASM size experiments.
//!
//! This is intentionally larger than needed to measure dead code elimination.
//! Feature flags control which modules are compiled.

#![no_std]
#![allow(unused_imports)]

extern crate alloc;
use alloc::string::String;
use alloc::vec::Vec;

// ══════════════════════════════════════════════════════════════════════════════
// STRINGS MODULE
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "strings")]
pub mod strings {
    use alloc::string::String;
    use alloc::vec::Vec;

    /// String length in bytes.
    #[inline]
    pub fn len(s: &str) -> usize {
        s.len()
    }

    /// Concatenate two strings.
    pub fn concat(a: &str, b: &str) -> String {
        let mut result = String::with_capacity(a.len() + b.len());
        result.push_str(a);
        result.push_str(b);
        result
    }

    /// Split string by delimiter.
    pub fn split<'a>(s: &'a str, delim: &str) -> Vec<&'a str> {
        s.split(delim).collect()
    }

    /// Trim whitespace from both ends.
    pub fn trim(s: &str) -> &str {
        s.trim()
    }

    /// ASCII uppercase (non-Unicode).
    pub fn to_upper_ascii(s: &str) -> String {
        s.chars()
            .map(|c| {
                if c >= 'a' && c <= 'z' {
                    ((c as u8) - 32) as char
                } else {
                    c
                }
            })
            .collect()
    }

    /// ASCII lowercase (non-Unicode).
    pub fn to_lower_ascii(s: &str) -> String {
        s.chars()
            .map(|c| {
                if c >= 'A' && c <= 'Z' {
                    ((c as u8) + 32) as char
                } else {
                    c
                }
            })
            .collect()
    }

    /// Find substring, returns byte offset or None.
    pub fn find(haystack: &str, needle: &str) -> Option<usize> {
        haystack.find(needle)
    }

    /// Extract substring by byte range.
    pub fn substring(s: &str, start: usize, end: usize) -> &str {
        &s[start..end.min(s.len())]
    }

    /// Check if string starts with prefix.
    pub fn starts_with(s: &str, prefix: &str) -> bool {
        s.starts_with(prefix)
    }

    /// Check if string ends with suffix.
    pub fn ends_with(s: &str, suffix: &str) -> bool {
        s.ends_with(suffix)
    }

    /// Replace all occurrences.
    pub fn replace(s: &str, from: &str, to: &str) -> String {
        s.replace(from, to)
    }

    /// Repeat string n times.
    pub fn repeat(s: &str, n: usize) -> String {
        s.repeat(n)
    }

    /// Check if string is empty.
    #[inline]
    pub fn is_empty(s: &str) -> bool {
        s.is_empty()
    }

    /// Parse integer from string.
    pub fn parse_int(s: &str) -> Option<i64> {
        let s = s.trim();
        if s.is_empty() {
            return None;
        }
        let (neg, digits) = if s.starts_with('-') {
            (true, &s[1..])
        } else if s.starts_with('+') {
            (false, &s[1..])
        } else {
            (false, s)
        };
        let mut result: i64 = 0;
        for b in digits.bytes() {
            if b < b'0' || b > b'9' {
                return None;
            }
            result = result.checked_mul(10)?.checked_add((b - b'0') as i64)?;
        }
        if neg {
            Some(-result)
        } else {
            Some(result)
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// UNICODE MODULE (adds significant size)
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "unicode")]
pub mod unicode {
    use alloc::string::String;
    use alloc::vec::Vec;

    // Embedded Unicode case mapping tables (simplified - real ones are larger)
    // This is a subset for demonstration; real tables are 50-150KB

    /// Simple uppercase mapping table (code point ranges).
    /// Format: (start, end, offset)
    static UPPER_MAP: &[(u32, u32, i32)] = &[
        // Latin lowercase a-z → A-Z
        (0x0061, 0x007A, -32),
        // Latin Extended-A (selected)
        (0x00E0, 0x00F6, -32), // à-ö → À-Ö
        (0x00F8, 0x00FE, -32), // ø-þ → Ø-Þ
        // Greek lowercase
        (0x03B1, 0x03C1, -32), // α-ρ → Α-Ρ
        (0x03C3, 0x03C9, -32), // σ-ω → Σ-Ω
        // Cyrillic lowercase
        (0x0430, 0x044F, -32), // а-я → А-Я
    ];

    /// Check if character is whitespace (Unicode-aware).
    pub fn is_whitespace(c: char) -> bool {
        matches!(
            c,
            ' ' | '\t'
                | '\n'
                | '\r'
                | '\x0B'
                | '\x0C'
                | '\u{00A0}'
                | '\u{1680}'
                | '\u{2000}'..='\u{200A}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202F}'
                | '\u{205F}'
                | '\u{3000}'
        )
    }

    /// Check if character is alphanumeric (Unicode-aware).
    pub fn is_alphanumeric(c: char) -> bool {
        c.is_alphanumeric()
    }

    /// Convert character to uppercase using embedded tables.
    pub fn char_to_upper(c: char) -> char {
        let cp = c as u32;
        for &(start, end, offset) in UPPER_MAP {
            if cp >= start && cp <= end {
                return char::from_u32((cp as i32 + offset) as u32).unwrap_or(c);
            }
        }
        c
    }

    /// Convert string to uppercase (Unicode-aware).
    pub fn to_upper(s: &str) -> String {
        s.chars().map(char_to_upper).collect()
    }

    /// Convert character to lowercase using embedded tables.
    pub fn char_to_lower(c: char) -> char {
        let cp = c as u32;
        // Inverse of UPPER_MAP
        for &(start, end, offset) in UPPER_MAP {
            let upper_start = (start as i32 + offset) as u32;
            let upper_end = (end as i32 + offset) as u32;
            if cp >= upper_start && cp <= upper_end {
                return char::from_u32((cp as i32 - offset) as u32).unwrap_or(c);
            }
        }
        c
    }

    /// Convert string to lowercase (Unicode-aware).
    pub fn to_lower(s: &str) -> String {
        s.chars().map(char_to_lower).collect()
    }

    /// Count Unicode characters (not bytes).
    pub fn char_count(s: &str) -> usize {
        s.chars().count()
    }

    /// Get character at index (0-based).
    pub fn char_at(s: &str, idx: usize) -> Option<char> {
        s.chars().nth(idx)
    }

    /// Get all characters as a vector.
    pub fn chars(s: &str) -> Vec<char> {
        s.chars().collect()
    }

    /// Normalize NFC (stub - real implementation needs tables).
    pub fn normalize_nfc(s: &str) -> String {
        // Real NFC normalization requires large tables
        // This is a stub that just returns the input
        String::from(s)
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// COLLECTIONS MODULE
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "collections")]
pub mod collections {
    use alloc::vec::Vec;

    /// Map over a vector.
    pub fn map<T, U, F>(xs: Vec<T>, f: F) -> Vec<U>
    where
        F: Fn(T) -> U,
    {
        xs.into_iter().map(f).collect()
    }

    /// Filter a vector.
    pub fn filter<T, F>(xs: Vec<T>, predicate: F) -> Vec<T>
    where
        F: Fn(&T) -> bool,
    {
        xs.into_iter().filter(predicate).collect()
    }

    /// Fold/reduce a vector.
    pub fn fold<T, U, F>(xs: Vec<T>, init: U, f: F) -> U
    where
        F: Fn(U, T) -> U,
    {
        xs.into_iter().fold(init, f)
    }

    /// Zip two vectors.
    pub fn zip<T, U>(xs: Vec<T>, ys: Vec<U>) -> Vec<(T, U)> {
        xs.into_iter().zip(ys).collect()
    }

    /// Flatten nested vectors.
    pub fn flatten<T>(xss: Vec<Vec<T>>) -> Vec<T> {
        xss.into_iter().flatten().collect()
    }

    /// Sort a vector (requires Ord).
    pub fn sort<T: Ord>(mut xs: Vec<T>) -> Vec<T> {
        xs.sort();
        xs
    }

    /// Remove consecutive duplicates.
    pub fn dedup<T: PartialEq>(mut xs: Vec<T>) -> Vec<T> {
        xs.dedup();
        xs
    }

    /// Reverse a vector.
    pub fn reverse<T>(mut xs: Vec<T>) -> Vec<T> {
        xs.reverse();
        xs
    }

    /// Take first n elements.
    pub fn take<T>(xs: Vec<T>, n: usize) -> Vec<T> {
        xs.into_iter().take(n).collect()
    }

    /// Drop first n elements.
    pub fn drop<T>(xs: Vec<T>, n: usize) -> Vec<T> {
        xs.into_iter().skip(n).collect()
    }

    /// Find first element matching predicate.
    pub fn find<T, F>(xs: Vec<T>, predicate: F) -> Option<T>
    where
        F: Fn(&T) -> bool,
    {
        xs.into_iter().find(predicate)
    }

    /// Check if any element matches.
    pub fn any<T, F>(xs: &[T], predicate: F) -> bool
    where
        F: Fn(&T) -> bool,
    {
        xs.iter().any(predicate)
    }

    /// Check if all elements match.
    pub fn all<T, F>(xs: &[T], predicate: F) -> bool
    where
        F: Fn(&T) -> bool,
    {
        xs.iter().all(predicate)
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// MATH MODULE
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "math")]
pub mod math {
    /// Absolute value.
    #[inline]
    pub fn abs(x: i64) -> i64 {
        if x < 0 {
            -x
        } else {
            x
        }
    }

    /// Absolute value for floats.
    #[inline]
    pub fn abs_f(x: f64) -> f64 {
        if x < 0.0 {
            -x
        } else {
            x
        }
    }

    /// Minimum of two values.
    #[inline]
    pub fn min(a: i64, b: i64) -> i64 {
        if a < b {
            a
        } else {
            b
        }
    }

    /// Maximum of two values.
    #[inline]
    pub fn max(a: i64, b: i64) -> i64 {
        if a > b {
            a
        } else {
            b
        }
    }

    /// Clamp value to range.
    #[inline]
    pub fn clamp(x: i64, lo: i64, hi: i64) -> i64 {
        if x < lo {
            lo
        } else if x > hi {
            hi
        } else {
            x
        }
    }

    /// Integer square root (floor).
    pub fn isqrt(n: u64) -> u64 {
        if n == 0 {
            return 0;
        }
        let mut x = n;
        let mut y = (x + 1) / 2;
        while y < x {
            x = y;
            y = (x + n / x) / 2;
        }
        x
    }

    /// Integer power.
    pub fn pow(base: i64, exp: u32) -> i64 {
        let mut result = 1i64;
        let mut b = base;
        let mut e = exp;
        while e > 0 {
            if e & 1 == 1 {
                result = result.wrapping_mul(b);
            }
            b = b.wrapping_mul(b);
            e >>= 1;
        }
        result
    }

    /// Greatest common divisor.
    pub fn gcd(mut a: u64, mut b: u64) -> u64 {
        while b != 0 {
            let t = b;
            b = a % b;
            a = t;
        }
        a
    }

    /// Least common multiple.
    pub fn lcm(a: u64, b: u64) -> u64 {
        if a == 0 || b == 0 {
            0
        } else {
            a / gcd(a, b) * b
        }
    }

    /// Check if number is prime (simple trial division).
    pub fn is_prime(n: u64) -> bool {
        if n < 2 {
            return false;
        }
        if n == 2 {
            return true;
        }
        if n % 2 == 0 {
            return false;
        }
        let sqrt = isqrt(n);
        let mut i = 3;
        while i <= sqrt {
            if n % i == 0 {
                return false;
            }
            i += 2;
        }
        true
    }

    // Floating-point functions (software implementations for no_std)

    /// Approximate square root using Newton-Raphson.
    pub fn sqrt(x: f64) -> f64 {
        if x < 0.0 {
            return f64::NAN;
        }
        if x == 0.0 {
            return 0.0;
        }
        let mut guess = x / 2.0;
        for _ in 0..20 {
            guess = (guess + x / guess) / 2.0;
        }
        guess
    }

    /// Approximate natural logarithm.
    pub fn ln(x: f64) -> f64 {
        if x <= 0.0 {
            return f64::NAN;
        }
        // Simple series expansion for ln(1+y) where y = (x-1)/(x+1)
        let y = (x - 1.0) / (x + 1.0);
        let y2 = y * y;
        let mut sum = y;
        let mut term = y;
        for n in 1..50 {
            term *= y2;
            sum += term / (2 * n + 1) as f64;
        }
        2.0 * sum
    }

    /// Power function using exp(y * ln(x)).
    pub fn powf(x: f64, y: f64) -> f64 {
        if x == 0.0 {
            return 0.0;
        }
        exp(y * ln(x))
    }

    /// Approximate exponential function.
    pub fn exp(x: f64) -> f64 {
        let mut sum = 1.0;
        let mut term = 1.0;
        for n in 1..30 {
            term *= x / n as f64;
            sum += term;
        }
        sum
    }

    // Trigonometric functions (Taylor series)

    /// Approximate sine.
    pub fn sin(x: f64) -> f64 {
        // Reduce to [-π, π]
        let pi = 3.141592653589793;
        let mut x = x % (2.0 * pi);
        if x > pi {
            x -= 2.0 * pi;
        }
        if x < -pi {
            x += 2.0 * pi;
        }
        // Taylor series
        let x2 = x * x;
        let mut term = x;
        let mut sum = x;
        for n in 1..15 {
            term *= -x2 / ((2 * n) * (2 * n + 1)) as f64;
            sum += term;
        }
        sum
    }

    /// Approximate cosine.
    pub fn cos(x: f64) -> f64 {
        let pi = 3.141592653589793;
        sin(x + pi / 2.0)
    }

    /// Approximate tangent.
    pub fn tan(x: f64) -> f64 {
        sin(x) / cos(x)
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// RANDOM MODULE
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "random")]
pub mod random {
    use alloc::vec::Vec;

    /// Simple xorshift64 PRNG state.
    static mut SEED: u64 = 0x123456789ABCDEF0;

    /// Seed the PRNG.
    pub fn seed(s: u64) {
        unsafe {
            SEED = if s == 0 { 1 } else { s };
        }
    }

    /// Generate next random u64.
    pub fn next_u64() -> u64 {
        unsafe {
            let mut x = SEED;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            SEED = x;
            x
        }
    }

    /// Random integer in [min, max] inclusive.
    pub fn int_range(min: i64, max: i64) -> i64 {
        if min >= max {
            return min;
        }
        let range = (max - min + 1) as u64;
        min + (next_u64() % range) as i64
    }

    /// Random float in [0, 1).
    pub fn float() -> f64 {
        (next_u64() as f64) / (u64::MAX as f64)
    }

    /// Generate n random bytes.
    pub fn bytes(n: usize) -> Vec<u8> {
        let mut result = Vec::with_capacity(n);
        let mut remaining = n;
        while remaining > 0 {
            let r = next_u64();
            let take = remaining.min(8);
            for i in 0..take {
                result.push((r >> (i * 8)) as u8);
            }
            remaining -= take;
        }
        result
    }

    /// Shuffle a vector in place (Fisher-Yates).
    pub fn shuffle<T>(xs: &mut [T]) {
        let len = xs.len();
        if len < 2 {
            return;
        }
        for i in (1..len).rev() {
            let j = (next_u64() as usize) % (i + 1);
            xs.swap(i, j);
        }
    }

    /// Pick a random element from a slice.
    pub fn choice<T>(xs: &[T]) -> Option<&T> {
        if xs.is_empty() {
            None
        } else {
            let idx = (next_u64() as usize) % xs.len();
            Some(&xs[idx])
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// TIME MODULE (stubs for size measurement)
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "time")]
pub mod time {
    use alloc::string::String;

    /// Opaque instant type.
    #[derive(Clone, Copy)]
    pub struct Instant(u64);

    /// Get current time (stub - returns 0).
    pub fn now() -> Instant {
        // In real implementation, this would call WASI clock_time_get
        Instant(0)
    }

    /// Get epoch seconds from instant.
    pub fn epoch_seconds(t: Instant) -> i64 {
        (t.0 / 1_000_000_000) as i64
    }

    /// Sleep for duration (stub - no-op).
    pub fn sleep(_secs: u64, _nanos: u32) {
        // In real implementation, this would call WASI poll_oneoff
    }

    /// Format instant as ISO 8601 (stub).
    pub fn format_iso8601(t: Instant) -> String {
        let secs = epoch_seconds(t);
        // Simplified: just return epoch seconds as string
        let mut s = String::new();
        let mut n = if secs < 0 { -secs } else { secs } as u64;
        if n == 0 {
            return String::from("0");
        }
        while n > 0 {
            s.insert(0, ((n % 10) as u8 + b'0') as char);
            n /= 10;
        }
        if secs < 0 {
            s.insert(0, '-');
        }
        s
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// IO MODULE (stubs for size measurement)
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "io")]
pub mod io {
    use alloc::string::String;
    use alloc::vec::Vec;

    /// Read file contents (stub).
    pub fn read_file(_path: &str) -> Result<Vec<u8>, &'static str> {
        Err("not implemented in WASM")
    }

    /// Write file contents (stub).
    pub fn write_file(_path: &str, _contents: &[u8]) -> Result<(), &'static str> {
        Err("not implemented in WASM")
    }

    /// Append to file (stub).
    pub fn append_file(_path: &str, _contents: &[u8]) -> Result<(), &'static str> {
        Err("not implemented in WASM")
    }

    /// Check if path exists (stub).
    pub fn exists(_path: &str) -> bool {
        false
    }

    /// Check if path is a file (stub).
    pub fn is_file(_path: &str) -> bool {
        false
    }

    /// Check if path is a directory (stub).
    pub fn is_dir(_path: &str) -> bool {
        false
    }

    /// Create directory and parents (stub).
    pub fn create_dir_all(_path: &str) -> Result<(), &'static str> {
        Err("not implemented in WASM")
    }

    /// Remove file or directory (stub).
    pub fn remove(_path: &str) -> Result<(), &'static str> {
        Err("not implemented in WASM")
    }

    /// Get environment variable (stub).
    pub fn env_var(_name: &str) -> Option<String> {
        None
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// JSON MODULE (stubs for size measurement)
// ══════════════════════════════════════════════════════════════════════════════

#[cfg(feature = "json")]
pub mod json {
    use alloc::string::String;
    use alloc::vec::Vec;

    /// Simple JSON value type.
    #[derive(Clone, Debug)]
    pub enum Value {
        Null,
        Bool(bool),
        Number(f64),
        String(String),
        Array(Vec<Value>),
        // Object would need a map type
    }

    /// Parse JSON string (simplified - only handles primitives).
    pub fn parse(s: &str) -> Option<Value> {
        let s = s.trim();
        if s == "null" {
            Some(Value::Null)
        } else if s == "true" {
            Some(Value::Bool(true))
        } else if s == "false" {
            Some(Value::Bool(false))
        } else if s.starts_with('"') && s.ends_with('"') && s.len() >= 2 {
            Some(Value::String(String::from(&s[1..s.len() - 1])))
        } else if let Ok(n) = s.parse::<f64>() {
            Some(Value::Number(n))
        } else {
            None
        }
    }

    /// Stringify JSON value.
    pub fn stringify(v: &Value) -> String {
        match v {
            Value::Null => String::from("null"),
            Value::Bool(true) => String::from("true"),
            Value::Bool(false) => String::from("false"),
            Value::Number(n) => {
                // Simple float to string
                let mut s = String::new();
                let n = *n;
                if n < 0.0 {
                    s.push('-');
                }
                let n = if n < 0.0 { -n } else { n };
                let int_part = n as u64;
                // Just output integer part for simplicity
                let mut digits = Vec::new();
                let mut i = int_part;
                if i == 0 {
                    digits.push(b'0');
                }
                while i > 0 {
                    digits.push((i % 10) as u8 + b'0');
                    i /= 10;
                }
                for d in digits.into_iter().rev() {
                    s.push(d as char);
                }
                s
            }
            Value::String(s) => {
                let mut out = String::with_capacity(s.len() + 2);
                out.push('"');
                out.push_str(s);
                out.push('"');
                out
            }
            Value::Array(arr) => {
                let mut out = String::from("[");
                for (i, v) in arr.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push_str(&stringify(v));
                }
                out.push(']');
                out
            }
        }
    }
}

// Note: no #[panic_handler]/#[global_allocator] here. This crate is only ever
// linked in as a dependency of app/ (never built standalone to wasm), and
// app/src/lib.rs already provides both — defining them here too conflicts
// with app's definitions (duplicate lang items).
