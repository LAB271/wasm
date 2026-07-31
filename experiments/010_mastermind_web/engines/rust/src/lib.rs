const COLORS: usize = 6;
const PEGS: usize = 4;

fn score(secret: [i32; PEGS], guess: [i32; PEGS]) -> (i32, i32) {
    let mut blacks = 0;
    let mut secret_leftover = [0i32; COLORS];
    let mut guess_leftover = [0i32; COLORS];

    for i in 0..PEGS {
        if secret[i] == guess[i] {
            blacks += 1;
        } else {
            secret_leftover[secret[i] as usize] += 1;
            guess_leftover[guess[i] as usize] += 1;
        }
    }

    let mut whites = 0;
    for c in 0..COLORS {
        whites += secret_leftover[c].min(guess_leftover[c]);
    }

    (blacks, whites)
}

/// Scores a Mastermind guess against a secret. Both are 4 pegs, colors 0-5.
/// Returns blacks and whites packed as `blacks * 16 + whites` (each fits in 4 bits).
#[no_mangle]
pub extern "C" fn score_guess(
    s0: i32,
    s1: i32,
    s2: i32,
    s3: i32,
    g0: i32,
    g1: i32,
    g2: i32,
    g3: i32,
) -> i32 {
    let (blacks, whites) = score([s0, s1, s2, s3], [g0, g1, g2, g3]);
    blacks * 16 + whites
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unpack(packed: i32) -> (i32, i32) {
        (packed / 16, packed % 16)
    }

    #[test]
    fn all_black() {
        assert_eq!(unpack(score_guess(0, 1, 2, 3, 0, 1, 2, 3)), (4, 0));
    }

    #[test]
    fn all_white_reversed() {
        assert_eq!(unpack(score_guess(0, 1, 2, 3, 3, 2, 1, 0)), (0, 4));
    }

    #[test]
    fn mixed_blacks_and_whites() {
        // secret 0,0,1,2 guess 0,1,1,3: pos0 and pos2 are black; leftover
        // secret {0,2}, leftover guess {1,3} share no colors -> 0 whites.
        assert_eq!(unpack(score_guess(0, 0, 1, 2, 0, 1, 1, 3)), (2, 0));
    }

    #[test]
    fn repeated_colors_cap_whites_by_multiset() {
        // secret 0,0,1,2 guess 0,0,0,0: pos0 and pos1 are black; leftover
        // secret {1,2} has no color-0 left, so the extra color-0 guesses
        // score nothing (whites are capped by the leftover multiset, not
        // just "color present somewhere").
        assert_eq!(unpack(score_guess(0, 0, 1, 2, 0, 0, 0, 0)), (2, 0));
    }

    #[test]
    fn no_match() {
        assert_eq!(unpack(score_guess(0, 0, 0, 0, 1, 1, 1, 1)), (0, 0));
    }
}
