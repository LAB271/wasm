// app.ts — Mastermind, scored entirely by a WASM module. score_guess() is a
// pure function (blacks/whites in, packed int out) with no host imports at
// all, so loading it is just `WebAssembly.instantiate(bytes, {})` — no
// runtime shim, no linear-memory bookkeeping.
//
// Two engines compile to the same ABI (engines/rust, engines/assemblyscript)
// and either can be loaded via ?engine=rust|as (default rust) — see README.md.

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

function engineName(): "rust" | "as" {
  return new URLSearchParams(location.search).get("engine") === "as" ? "as" : "rust";
}

async function loadWasm(): Promise<void> {
  const bytes = await fetch(`engine-${engineName()}.wasm`).then((r) => r.arrayBuffer());
  const { instance } = await WebAssembly.instantiate(bytes, {});
  wasmExports = instance.exports as unknown as WasmExports;
}

// The one call that matters: colors are 1-6 in the UI, but the wasm ABI
// uses 0-5, and blacks/whites come back packed as `blacks * 16 + whites`.
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

function pegEl(color: number | null, size: "sm" | "lg" = "sm"): HTMLElement {
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
      if (gameOver || currentGuess.length >= CODE_LENGTH) return;
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
    const peg = pegEl(color, "lg");
    if (color !== null) {
      peg.addEventListener("click", () => {
        if (gameOver) return;
        currentGuess.splice(i, 1);
        renderCurrentGuess();
      });
    }
    currentGuessEl.appendChild(peg);
  }
  submitBtn.disabled = gameOver || currentGuess.length !== CODE_LENGTH;
}

function renderRow(index: number, guess: number[], feedback: Feedback | null): void {
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

  boardEl.appendChild(row);
}

function renderBoard(): void {
  boardEl.innerHTML = "";
  guesses.forEach((h, i) => renderRow(i, h.guess, h.feedback));
  attemptCountEl.textContent = String(guesses.length);
}

function showOverlay(won: boolean): void {
  overlayEl.classList.remove("hidden");
  overlayTitleEl.textContent = won ? "Cracked it!" : "Out of attempts";
  overlayTitleEl.className = won ? "win" : "lose";
  overlayBodyEl.textContent = won
    ? `Solved in ${guesses.length} ${guesses.length === 1 ? "guess" : "guesses"}. The secret was ${secret.map(colorName).join(", ")}.`
    : `The secret was ${secret.map(colorName).join(", ")}.`;
}

function hideOverlay(): void {
  overlayEl.classList.add("hidden");
}

function submitGuess(): void {
  if (gameOver || currentGuess.length !== CODE_LENGTH) return;
  const guess = [...currentGuess];
  const feedback = scoreGuess(secret, guess); // <- the WASM call
  guesses.push({ guess, feedback });
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

function newGame(): void {
  secret = randomSecret();
  currentGuess = [];
  guesses = [];
  gameOver = false;
  hideOverlay();
  renderBoard();
  renderCurrentGuess();
}

async function main(): Promise<void> {
  attemptMaxEl.textContent = String(MAX_ATTEMPTS);
  clearBtn.addEventListener("click", () => {
    if (gameOver) return;
    currentGuess = [];
    renderCurrentGuess();
  });
  submitBtn.addEventListener("click", submitGuess);
  newGameBtn.addEventListener("click", newGame);
  overlayBtn.addEventListener("click", newGame);

  try {
    await loadWasm();
    engineStatusEl.textContent = `wasm ready (${engineName()})`;
    engineStatusEl.className = "ready";
    renderPalette();
    newGame();
  } catch (err) {
    engineStatusEl.textContent = "wasm load failed";
    console.error(err);
  }
}

void main();
