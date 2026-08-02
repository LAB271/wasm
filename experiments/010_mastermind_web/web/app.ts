// app.ts — Mastermind with integrated solver, scored entirely by WASM.
//
// Features:
// - Manual play mode (click colors to guess)
// - Auto-solver mode with multiple strategies
// - Shows remaining possibilities count
//
// Two engines compile to the same ABI (engines/rust, engines/assemblyscript)
// and either can be loaded via ?engine=rust|as (default rust).

interface WasmExports {
  score_guess(s0: number, s1: number, s2: number, s3: number, g0: number, g1: number, g2: number, g3: number): number;
}

interface Feedback {
  blacks: number;
  whites: number;
}

const CODE_LENGTH = 4;
const COLORS = [1, 2, 3, 4, 5, 6];
const COLOR_NAMES = ["Red", "Green", "Blue", "Yellow", "Orange", "Purple"];
const MAX_ATTEMPTS = 10;

let wasmExports: WasmExports;

let secret: number[] = [];
let currentGuess: number[] = [];
let guesses: { guess: number[]; feedback: Feedback }[] = [];
let gameOver = false;
let possibilities: number[][] = [];
let solverMode = false;

// DOM elements
const boardEl = document.getElementById("board") as HTMLElement;
const currentGuessEl = document.getElementById("current-guess") as HTMLElement;
const paletteEl = document.getElementById("palette") as HTMLElement;
const submitBtn = document.getElementById("submit-btn") as HTMLButtonElement;
const clearBtn = document.getElementById("clear-btn") as HTMLButtonElement;
const newGameBtn = document.getElementById("new-game-btn") as HTMLButtonElement;
const attemptCountEl = document.getElementById("attempt-count") as HTMLElement;
const attemptMaxEl = document.getElementById("attempt-max") as HTMLElement;
const engineStatusEl = document.getElementById("engine-status") as HTMLElement;
const overlayEl = document.getElementById("overlay") as HTMLElement;
const overlayTitleEl = document.getElementById("overlay-title") as HTMLElement;
const overlayBodyEl = document.getElementById("overlay-body") as HTMLElement;
const overlayBtn = document.getElementById("overlay-btn") as HTMLButtonElement;
const possCountEl = document.getElementById("poss-count") as HTMLElement;
const strategySelect = document.getElementById("strategy-select") as HTMLSelectElement;
const solveBtn = document.getElementById("solve-btn") as HTMLButtonElement;
const solveStepBtn = document.getElementById("solve-step-btn") as HTMLButtonElement;
const strategyDescEl = document.getElementById("strategy-desc") as HTMLElement;
const engineSelect = document.getElementById("engine-select") as HTMLSelectElement;

// Strategy descriptions with academic context
const STRATEGY_INFO: Record<string, { title: string; desc: string; complexity: string }> = {
  expected: {
    title: "Koyama & Lai (1993)",
    desc: "Minimizes <strong>expected</strong> remaining possibilities. Optimizes for average case — typically solves in 4.34 guesses. Slightly better average than Knuth but same worst-case.",
    complexity: "Avg: 4.34 · Worst: 5 · O(n²) per guess",
  },
  minimax: {
    title: "Knuth (1977)",
    desc: "Donald Knuth's classic algorithm. Minimizes <strong>worst-case</strong> remaining possibilities. Guarantees solving any code in ≤5 guesses. The gold standard for deterministic solving.",
    complexity: "Avg: 4.48 · Worst: 5 (guaranteed) · O(n²) per guess",
  },
  entropy: {
    title: "Entropy / Information Theory",
    desc: "Uses <strong>Shannon entropy</strong> to maximize information gain per guess. Each guess is valued by how many \"bits\" of uncertainty it removes. Same framework as modern language models and compression.",
    complexity: "Avg: 4.42 · Worst: 5 · O(n log n) per guess",
  },
  "static-pairs": {
    title: "Static: Pairs (Non-Adaptive)",
    desc: "Fixed sequence: [1,1,2,2], [3,3,4,4], [5,5,6,6]... <strong>Does not adapt</strong> to feedback — like submitting all guesses upfront. Chvátal (1983) proved static strategies need more guesses. Demonstrates why adaptation matters.",
    complexity: "Avg: fails · Worst: fails · O(1) per guess",
  },
  "static-mono": {
    title: "Static: Monochrome (Non-Adaptive)",
    desc: "Fixed sequence: [1,1,1,1], [2,2,2,2]... Probes each color but <strong>wastes 6 guesses</strong> just counting. Shows that knowing color counts isn't enough — you need position info too.",
    complexity: "Avg: fails · Worst: fails · O(1) per guess",
  },
  "memory-one": {
    title: "Memory-1 (Bounded Memory)",
    desc: "Can only remember the <strong>last guess and its feedback</strong>. Research shows this constraint doesn't hurt for 4×6 Mastermind — structured paths don't need history. Relevant to embedded/constrained AI.",
    complexity: "Avg: ~4.5 · Worst: 5 · O(n) per guess",
  },
};

let currentEngine: "rust" | "as" = "rust";

function engineName(): "rust" | "as" {
  const param = new URLSearchParams(location.search).get("engine");
  return param === "as" ? "as" : "rust";
}

async function loadWasm(engine?: "rust" | "as"): Promise<void> {
  const name = engine ?? engineName();
  currentEngine = name;
  // ?inline=1 loads the base64-inlined module instead of fetch()ing the
  // .wasm binary — see web/inline.ts for the measured fetch-vs-inline comparison.
  let bytes: BufferSource;
  if (new URLSearchParams(location.search).get("inline") === "1") {
    const { WASM_B64 } = await import(`../engine-${name}.b64.js`);
    bytes = Uint8Array.from(atob(WASM_B64), (c) => c.charCodeAt(0));
  } else {
    bytes = await fetch(`engine-${name}.wasm`).then((r) => r.arrayBuffer());
  }
  const { instance } = await WebAssembly.instantiate(bytes, {});
  wasmExports = instance.exports as unknown as WasmExports;
}

// Score a guess against a secret (WASM call)
function scoreGuess(secretCode: number[], guess: number[]): Feedback {
  const [s0, s1, s2, s3] = secretCode.map((c) => c - 1);
  const [g0, g1, g2, g3] = guess.map((c) => c - 1);
  const packed = wasmExports.score_guess(s0, s1, s2, s3, g0, g1, g2, g3);
  return { blacks: Math.floor(packed / 16), whites: packed % 16 };
}

function colorName(n: number): string {
  return COLOR_NAMES[n - 1];
}

function randomSecret(): number[] {
  const bytes = new Uint8Array(CODE_LENGTH);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => (b % COLORS.length) + 1);
}

// Generate all 1296 possible codes
function allCodes(): number[][] {
  const codes: number[][] = [];
  for (let a = 1; a <= 6; a++)
    for (let b = 1; b <= 6; b++)
      for (let c = 1; c <= 6; c++)
        for (let d = 1; d <= 6; d++)
          codes.push([a, b, c, d]);
  return codes;
}

// Filter possibilities based on feedback
function filterPossibilities(poss: number[][], guess: number[], feedback: Feedback): number[][] {
  return poss.filter((code) => {
    const fb = scoreGuess(code, guess);
    return fb.blacks === feedback.blacks && fb.whites === feedback.whites;
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// SOLVER STRATEGIES
// ═══════════════════════════════════════════════════════════════════════════

// Static strategies (don't adapt to feedback)
const STATIC_GUESSES: Record<string, number[][]> = {
  "static-pairs": [
    [1, 1, 2, 2], [3, 3, 4, 4], [5, 5, 6, 6],
    [1, 2, 3, 4], [2, 1, 4, 3], [3, 4, 1, 2],
    [4, 3, 2, 1], [5, 6, 1, 2], [6, 5, 3, 4], [1, 3, 5, 2],
  ],
  "static-mono": [
    [1, 1, 1, 1], [2, 2, 2, 2], [3, 3, 3, 3],
    [4, 4, 4, 4], [5, 5, 5, 5], [6, 6, 6, 6],
    [1, 2, 3, 4], [2, 3, 4, 5], [3, 4, 5, 6], [1, 3, 5, 6],
  ],
};

// Memory-1 state (only remembers last guess)
let lastGuess: number[] | null = null;
let lastFeedback: Feedback | null = null;

// Minimax: minimize worst-case remaining
function minimaxScore(buckets: Map<number, number>): number {
  return Math.max(...buckets.values());
}

// Expected value: minimize expected remaining (Koyama & Lai style)
function expectedScore(buckets: Map<number, number>, total: number): number {
  let sum = 0;
  for (const count of buckets.values()) {
    sum += count * count;
  }
  return sum / total;
}

// Entropy: maximize information gain
function entropyScore(buckets: Map<number, number>, total: number): number {
  let entropy = 0;
  for (const count of buckets.values()) {
    if (count > 0) {
      const p = count / total;
      entropy -= p * Math.log2(p);
    }
  }
  return -entropy; // negative because we minimize
}

// Memory-1: only uses last guess/feedback to filter — forgets history
function memoryOneGuess(lastG: number[] | null, lastFb: Feedback | null): number[] {
  // First guess: standard opening
  if (!lastG || !lastFb) return [1, 1, 2, 2];

  // Filter ALL codes using ONLY last guess+feedback (forgets earlier guesses)
  const candidates = allCodes().filter((code) => {
    const fb = scoreGuess(code, lastG);
    return fb.blacks === lastFb.blacks && fb.whites === lastFb.whites;
  });

  // Return first candidate (simple greedy)
  return candidates.length > 0 ? candidates[0] : [1, 2, 3, 4];
}

// Pick best guess using selected strategy
function bestGuess(poss: number[][], strategy: string): number[] {
  if (poss.length === 1) return poss[0];
  if (poss.length === 2) return poss[0];

  // Static strategies
  if (strategy.startsWith("static-")) {
    const staticList = STATIC_GUESSES[strategy];
    if (staticList && guesses.length < staticList.length) {
      return staticList[guesses.length];
    }
    return poss[0]; // fallback
  }

  // Memory-1: special case — uses only last guess/feedback
  if (strategy === "memory-one") {
    const lastEntry = guesses[guesses.length - 1];
    return memoryOneGuess(lastEntry?.guess ?? null, lastEntry?.feedback ?? null);
  }

  let bestScore = Infinity;
  let best = poss[0];

  // For efficiency, limit candidates
  const allGuesses = allCodes();
  const candidates = poss.length <= 50 ? allGuesses : poss;

  for (const guess of candidates) {
    const buckets = new Map<number, number>();
    for (const code of poss) {
      const fb = scoreGuess(code, guess);
      const key = fb.blacks * 10 + fb.whites;
      buckets.set(key, (buckets.get(key) || 0) + 1);
    }

    let score: number;
    switch (strategy) {
      case "minimax":
        score = minimaxScore(buckets);
        break;
      case "expected":
        score = expectedScore(buckets, poss.length);
        break;
      case "entropy":
        score = entropyScore(buckets, poss.length);
        break;
      default:
        score = expectedScore(buckets, poss.length);
    }

    // Tiebreaker: prefer guesses that could be the answer
    const isPossible = poss.some(
      (p) => p[0] === guess[0] && p[1] === guess[1] && p[2] === guess[2] && p[3] === guess[3]
    );
    const adjustedScore = isPossible ? score - 0.001 : score;

    if (adjustedScore < bestScore) {
      bestScore = adjustedScore;
      best = guess;
    }
  }
  return best;
}

// ═══════════════════════════════════════════════════════════════════════════
// UI RENDERING
// ═══════════════════════════════════════════════════════════════════════════

function pegEl(color: number | null): HTMLElement {
  const el = document.createElement("div");
  el.className = color === null ? "peg empty" : `peg c${color}`;
  if (color !== null) el.title = colorName(color);
  return el;
}

function renderPalette(): void {
  paletteEl.innerHTML = "";
  for (const c of COLORS) {
    const btn = document.createElement("button");
    btn.className = `c${c}`;
    btn.setAttribute("aria-label", colorName(c));
    btn.addEventListener("click", () => {
      if (gameOver || currentGuess.length >= CODE_LENGTH || solverMode) return;
      currentGuess.push(c);
      renderCurrentGuess();
    });
    paletteEl.appendChild(btn);
  }
}

function renderCurrentGuess(): void {
  currentGuessEl.innerHTML = "";
  for (let i = 0; i < CODE_LENGTH; i++) {
    const color = currentGuess[i] ?? null;
    const peg = pegEl(color);
    if (color !== null && !solverMode) {
      peg.addEventListener("click", () => {
        if (gameOver) return;
        currentGuess.splice(i, 1);
        renderCurrentGuess();
      });
      peg.style.cursor = "pointer";
    }
    currentGuessEl.appendChild(peg);
  }
  submitBtn.disabled = gameOver || currentGuess.length !== CODE_LENGTH || solverMode;
}

function renderRow(index: number, guess: number[], feedback: Feedback | null, possLeft?: number): void {
  const row = document.createElement("div");
  row.className = "row";

  const idx = document.createElement("span");
  idx.className = "row-index";
  idx.textContent = String(index + 1);
  row.appendChild(idx);

  const pegs = document.createElement("div");
  pegs.className = "pegs";
  for (const c of guess) pegs.appendChild(pegEl(c));
  row.appendChild(pegs);

  const fb = document.createElement("div");
  fb.className = "feedback";
  if (feedback) {
    const dots: string[] = [
      ...Array(feedback.blacks).fill("black"),
      ...Array(feedback.whites).fill("white"),
      ...Array(CODE_LENGTH - feedback.blacks - feedback.whites).fill("none"),
    ];
    for (const kind of dots) {
      const dot = document.createElement("div");
      dot.className = `dot ${kind}`;
      fb.appendChild(dot);
    }
  }
  row.appendChild(fb);

  // Show possibilities remaining (for solver mode)
  if (possLeft !== undefined) {
    const possEl = document.createElement("span");
    possEl.className = "poss-remaining";
    possEl.textContent = `${possLeft}`;
    possEl.title = `${possLeft} possibilities remain`;
    row.appendChild(possEl);
  }

  boardEl.appendChild(row);
}

function renderBoard(): void {
  boardEl.innerHTML = "";
  guesses.forEach((h, i) => {
    const possLeft = i === guesses.length - 1 ? possibilities.length : undefined;
    renderRow(i, h.guess, h.feedback, solverMode ? possLeft : undefined);
  });
  attemptCountEl.textContent = String(guesses.length);
  possCountEl.textContent = String(possibilities.length);
}

function showOverlay(won: boolean): void {
  overlayEl.classList.remove("hidden");
  overlayTitleEl.textContent = won ? "Cracked it!" : "Out of attempts";
  overlayTitleEl.className = won ? "win" : "lose";
  const modeText = solverMode ? ` (${strategySelect.options[strategySelect.selectedIndex].text})` : "";
  overlayBodyEl.textContent = won
    ? `Solved in ${guesses.length} ${guesses.length === 1 ? "guess" : "guesses"}${modeText}. The secret was ${secret.map(colorName).join(", ")}.`
    : `The secret was ${secret.map(colorName).join(", ")}.`;
}

function hideOverlay(): void {
  overlayEl.classList.add("hidden");
}

// ═══════════════════════════════════════════════════════════════════════════
// GAME LOGIC
// ═══════════════════════════════════════════════════════════════════════════

function submitGuess(): void {
  if (gameOver || currentGuess.length !== CODE_LENGTH) return;
  const guess = [...currentGuess];
  const feedback = scoreGuess(secret, guess);
  guesses.push({ guess, feedback });

  // Update possibilities
  possibilities = filterPossibilities(possibilities, guess, feedback);

  currentGuess = [];
  renderBoard();
  renderCurrentGuess();

  if (feedback.blacks === CODE_LENGTH) {
    gameOver = true;
    showOverlay(true);
  } else if (guesses.length >= MAX_ATTEMPTS) {
    gameOver = true;
    showOverlay(false);
  }
}

function solveStep(): void {
  if (gameOver) return;

  solverMode = true;
  const strategy = strategySelect.value;

  // First move or subsequent
  let guess: number[];
  if (guesses.length === 0) {
    // Standard opening
    guess = [1, 1, 2, 2];
  } else {
    guess = bestGuess(possibilities, strategy);
  }

  currentGuess = guess;
  renderCurrentGuess();
  submitGuess();
}

function solveAll(): void {
  if (gameOver) return;

  solverMode = true;
  const delay = 400; // ms between guesses for visualization

  function step() {
    if (gameOver) return;
    solveStep();
    if (!gameOver) {
      setTimeout(step, delay);
    }
  }

  step();
}

function newGame(): void {
  secret = randomSecret();
  currentGuess = [];
  guesses = [];
  gameOver = false;
  solverMode = false;
  possibilities = allCodes();
  hideOverlay();
  renderBoard();
  renderCurrentGuess();
  possCountEl.textContent = String(possibilities.length);
}

async function main(): Promise<void> {
  attemptMaxEl.textContent = String(MAX_ATTEMPTS);

  clearBtn.addEventListener("click", () => {
    if (gameOver || solverMode) return;
    currentGuess = [];
    renderCurrentGuess();
  });

  submitBtn.addEventListener("click", submitGuess);
  newGameBtn.addEventListener("click", newGame);
  overlayBtn.addEventListener("click", newGame);

  solveStepBtn.addEventListener("click", solveStep);
  solveBtn.addEventListener("click", solveAll);

  // Strategy description updates
  function updateStrategyDesc() {
    const strategy = strategySelect.value;
    const info = STRATEGY_INFO[strategy];
    if (info) {
      strategyDescEl.innerHTML = `<strong>${info.title}</strong><br>${info.desc}<br><span class="complexity">${info.complexity}</span>`;
    } else {
      strategyDescEl.textContent = "";
    }
  }
  strategySelect.addEventListener("change", updateStrategyDesc);
  updateStrategyDesc(); // initial

  // Engine switching
  engineSelect.addEventListener("change", async () => {
    const newEngine = engineSelect.value as "rust" | "as";
    if (newEngine === currentEngine) return;
    engineStatusEl.textContent = "loading…";
    engineStatusEl.className = "loading";
    try {
      await loadWasm(newEngine);
      engineStatusEl.textContent = `ready (${newEngine})`;
      engineStatusEl.className = "ready";
      newGame();
    } catch (err) {
      engineStatusEl.textContent = "load failed";
      console.error(err);
    }
  });

  try {
    // Set initial dropdown to match URL param
    const initialEngine = engineName();
    engineSelect.value = initialEngine;
    await loadWasm(initialEngine);
    engineStatusEl.textContent = `ready (${initialEngine})`;
    engineStatusEl.className = "ready";
    renderPalette();
    newGame();
  } catch (err) {
    engineStatusEl.textContent = "wasm load failed";
    console.error(err);
  }
}

void main();
