// mastermind-guest — the same Mastermind game as mvl-lang/mvl/examples/mastermind
// (main.mvl + code.mvl), reimplemented in pure Rust and compiled to
// wasm32-wasip1, to prove real interactive stdin works under WASM/WASI when a
// host actually wires fd_read — which is exactly the piece MVL's own
// `--backend=wasm` doesn't have (its `runtime` import namespace has no stdin
// at all; `stdin`/`read_line` are undefined under that backend, and code.mvl's
// own parse_guess traps on call anyway — see experiment 010's README).
//
// Scoring logic (`score_guess`) is a deliberate line-for-line port of
// code.mvl's count_blacks/count_color_at_mismatch/score_guess, not a
// reimplementation from the rules description — same restriction to
// mismatched positions on both sides, same min() to avoid double-counting.
//
// stdout is flushed after every write. Under WASI (not a TTY), Rust's stdout
// is block-buffered by default — a prompt printed without a flush can sit in
// the buffer while the process blocks on read_line, making an interactive
// session look hung. Verified this matters (see README's "flush" note).
use std::io::{self, BufRead, Write};

const CODE_LEN: usize = 4;
const NUM_COLORS: u8 = 6;
const MAX_ATTEMPTS: u32 = 10;

#[derive(Clone, Copy)]
struct Feedback {
    blacks: u8,
    whites: u8,
}

fn color_name(n: u8) -> &'static str {
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

fn render_code(code: &[u8; CODE_LEN]) -> String {
    code.iter().map(|&n| color_name(n)).collect::<Vec<_>>().join(" ")
}

fn render_feedback(fb: Feedback) -> String {
    format!("blacks: {}  whites: {}", fb.blacks, fb.whites)
}

// Direct port of code.mvl's count_blacks: positions where guess matches
// secret exactly.
fn count_blacks(secret: &[u8; CODE_LEN], guess: &[u8; CODE_LEN]) -> u32 {
    secret.iter().zip(guess.iter()).filter(|(s, g)| s == g).count() as u32
}

// Direct port of code.mvl's count_color_at_mismatch: occurrences of `color`
// in `xs`, restricted to positions where `xs` and `other` differ — applied
// to both sides in score_guess so black-peg positions are never counted
// twice for whites.
fn count_color_at_mismatch(xs: &[u8; CODE_LEN], other: &[u8; CODE_LEN], color: u8) -> u32 {
    xs.iter()
        .zip(other.iter())
        .filter(|(&x, &o)| x == color && x != o)
        .count() as u32
}

// Direct port of code.mvl's score_guess.
fn score_guess(secret: &[u8; CODE_LEN], guess: &[u8; CODE_LEN]) -> Feedback {
    let blacks = count_blacks(secret, guess);
    let mut whites = 0u32;
    for color in 1..=NUM_COLORS {
        let in_secret = count_color_at_mismatch(secret, guess, color);
        let in_guess = count_color_at_mismatch(guess, secret, color);
        whites += in_secret.min(in_guess);
    }
    Feedback { blacks: blacks as u8, whites: whites as u8 }
}

// Direct port of code.mvl's parse_guess: exactly four numbers in 1..=6,
// whitespace-separated. Anything else -> None (Invalid, does not consume
// an attempt) — matches main.mvl's read_guess semantics.
fn parse_guess(input: &str) -> Option<[u8; CODE_LEN]> {
    let parts: Vec<&str> = input.trim().split_whitespace().collect();
    if parts.len() != CODE_LEN {
        return None;
    }
    let mut code = [0u8; CODE_LEN];
    for (i, part) in parts.iter().enumerate() {
        let n: i32 = part.parse().ok()?;
        if !(1..=NUM_COLORS as i32).contains(&n) {
            return None;
        }
        code[i] = n as u8;
    }
    Some(code)
}

// No RNG crate — this is a spike, not a security-sensitive shuffle. Seeded
// from WASI's clock_time_get (via SystemTime, which wasmtime's default WASI
// implementation backs for real), not "random" in a cryptographic sense, but
// varies run to run same as code.mvl's std.random.int would.
struct Xorshift64(u64);
impl Xorshift64 {
    fn new(seed: u64) -> Self {
        Xorshift64(seed | 1)
    }
    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn range_1_to_6(&mut self) -> u8 {
        1 + (self.next_u64() % NUM_COLORS as u64) as u8
    }
}

fn seed_from_clock() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9E3779B97F4A7C15)
}

fn main() {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();

    macro_rules! say {
        ($($arg:tt)*) => {{
            writeln!(out, $($arg)*).ok();
            out.flush().ok(); // see top-of-file comment on WASI stdout buffering
        }};
    }

    say!("Mastermind (Rust, wasm32-wasip1, real WASI stdin)");
    say!("I picked a secret code of 4 colors (repeats allowed):");
    say!("  1 = red    2 = green  3 = blue");
    say!("  4 = yellow 5 = orange 6 = purple");
    say!("Guess with four numbers separated by spaces, e.g. `1 2 3 4`.");
    say!("Feedback: black = right color + position, white = right color only.");

    let mut rng = Xorshift64::new(seed_from_clock());
    let secret: [u8; CODE_LEN] = [
        rng.range_1_to_6(),
        rng.range_1_to_6(),
        rng.range_1_to_6(),
        rng.range_1_to_6(),
    ];

    let mut attempt: u32 = 1;
    loop {
        if attempt > MAX_ATTEMPTS {
            say!("Out of attempts -- the code was: {}", render_code(&secret));
            break;
        }

        say!("Attempt {} of {} -- your guess:", attempt, MAX_ATTEMPTS);
        out.flush().ok();

        let line = match lines.next() {
            None => {
                say!("Goodbye! The code was: {}", render_code(&secret));
                break;
            }
            Some(Err(_)) => {
                say!("Goodbye! The code was: {}", render_code(&secret));
                break;
            }
            Some(Ok(line)) => line,
        };

        if line.trim().is_empty() {
            say!("Goodbye! The code was: {}", render_code(&secret));
            break;
        }

        match parse_guess(&line) {
            None => {
                say!("Invalid guess -- enter four numbers 1-6, e.g. `1 2 3 4`.");
            }
            Some(guess) => {
                let fb = score_guess(&secret, &guess);
                say!("  -> {}", render_feedback(fb));
                if fb.blacks as usize == CODE_LEN {
                    say!("Cracked it in {} attempt(s)!", attempt);
                    break;
                }
                attempt += 1;
            }
        }
    }
}
