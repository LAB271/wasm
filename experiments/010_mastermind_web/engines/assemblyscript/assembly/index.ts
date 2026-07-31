// Scores a Mastermind guess against a secret. Both are 4 pegs, colors 0-5.
// Returns blacks and whites packed as `blacks * 16 + whites` (each fits in
// 4 bits) -- same ABI as the Rust engine, so the UI can load either one.
//
// Colors are tracked as six scalar counters rather than an array: AS array
// indexing pulls in the runtime's bounds-check abort import, and this
// function has no other reason to need any host import at all.
export function score_guess(
  s0: i32,
  s1: i32,
  s2: i32,
  s3: i32,
  g0: i32,
  g1: i32,
  g2: i32,
  g3: i32,
): i32 {
  let blacks = 0;
  let sLeft0 = 0, sLeft1 = 0, sLeft2 = 0, sLeft3 = 0, sLeft4 = 0, sLeft5 = 0;
  let gLeft0 = 0, gLeft1 = 0, gLeft2 = 0, gLeft3 = 0, gLeft4 = 0, gLeft5 = 0;

  for (let i = 0; i < 4; i++) {
    const s = i == 0 ? s0 : i == 1 ? s1 : i == 2 ? s2 : s3;
    const g = i == 0 ? g0 : i == 1 ? g1 : i == 2 ? g2 : g3;
    if (s == g) {
      blacks++;
      continue;
    }
    if (s == 0) sLeft0++; else if (s == 1) sLeft1++; else if (s == 2) sLeft2++;
    else if (s == 3) sLeft3++; else if (s == 4) sLeft4++; else sLeft5++;
    if (g == 0) gLeft0++; else if (g == 1) gLeft1++; else if (g == 2) gLeft2++;
    else if (g == 3) gLeft3++; else if (g == 4) gLeft4++; else gLeft5++;
  }

  const min = (a: i32, b: i32): i32 => a < b ? a : b;
  const whites =
    min(sLeft0, gLeft0) + min(sLeft1, gLeft1) + min(sLeft2, gLeft2) +
    min(sLeft3, gLeft3) + min(sLeft4, gLeft4) + min(sLeft5, gLeft5);

  return blacks * 16 + whites;
}
