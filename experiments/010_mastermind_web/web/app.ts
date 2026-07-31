// app.ts — Mastermind, scored entirely by a WASM module compiled from
// mvl-lang/mvl/examples/mastermind/code.mvl (pure, total, zero-effect MVL
// source — see vendor/code.mvl and README.md for exactly what was kept,
// what was excluded, and why).
//
// Two compiler bugs make this file's design what it is, not incidentally:
//   - parse_guess/render_code trap on call (`unreachable` — "contained
//     unsupported constructs") -> the UI is click-to-pick colored pegs,
//     never free-text input, so parse_guess is simply never needed.
//   - render_feedback fails to assemble at all (undefined
//     $mvl_int_to_string) -> blacks/whites are rendered as pegs directly
//     from the raw Feedback struct fields, never as a formatted string.
import { createMvlRuntime } from "./mvl-runtime.js";

interface WasmExports {
  score_guess(secretHandle: number, guessHandle: number): number;
  color_name(n: bigint): [number, number];
  memory?: WebAssembly.Memory;
}

interface Feedback {
  blacks: number;
  whites: number;
}

const CODE_LENGTH = 4;
const COLORS = [1, 2, 3, 4, 5, 6];
const MAX_ATTEMPTS = 10;

let wasmExports: WasmExports;
let wasmMemory: WebAssembly.Memory;
let runtimeHandles: ReturnType<typeof createMvlRuntime>["runtime"];

let secret: number[] = [];
let currentGuess: number[] = [];
let history: { guess: number[]; feedback: Feedback }[] = [];
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

async function loadWasm(): Promise<void> {
  const { memory, runtime } = createMvlRuntime();
  const bytes = await fetch("code.wasm").then((r) => r.arrayBuffer());
  const { instance } = await WebAssembly.instantiate(bytes, { runtime });
  wasmExports = instance.exports as unknown as WasmExports;
  wasmMemory = (instance.exports.memory as WebAssembly.Memory | undefined) ?? memory;
  runtimeHandles = runtime;
}

function makeArrayHandle(values: number[]): number {
  const h = runtimeHandles._mvl_array_new(8, values.length);
  for (const v of values) runtimeHandles._mvl_array_push_i64(h, BigInt(v));
  return h;
}

// The one call that matters: hands two arrays to the compiled WASM module
// and reads back a Feedback struct written directly into linear memory
// (blacks at +0, whites at +8 — see README.md for how this ABI was
// reverse-engineered from score_guess's actual WAT body).
function scoreGuess(secretCode: number[], guess: number[]): Feedback {
  const secretHandle = makeArrayHandle(secretCode);
  const guessHandle = makeArrayHandle(guess);
  const fbPtr = wasmExports.score_guess(secretHandle, guessHandle);
  const dv = new DataView(wasmMemory.buffer);
  const blacks = Number(dv.getBigInt64(fbPtr + 0, true));
  const whites = Number(dv.getBigInt64(fbPtr + 8, true));
  return { blacks, whites };
}

function colorName(n: number): string {
  const [ptr, len] = wasmExports.color_name(BigInt(n));
  return new TextDecoder().decode(new Uint8Array(wasmMemory.buffer, ptr, len));
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
  history.forEach((h, i) => renderRow(i, h.guess, h.feedback));
  attemptCountEl.textContent = String(history.length);
}

function showOverlay(won: boolean): void {
  overlayEl.classList.remove("hidden");
  overlayTitleEl.textContent = won ? "Cracked it!" : "Out of attempts";
  overlayTitleEl.className = won ? "win" : "lose";
  overlayBodyEl.textContent = won
    ? `Solved in ${history.length} ${history.length === 1 ? "guess" : "guesses"}. The secret was ${secret.map(colorName).join(", ")}.`
    : `The secret was ${secret.map(colorName).join(", ")}.`;
}

function hideOverlay(): void {
  overlayEl.classList.add("hidden");
}

function submitGuess(): void {
  if (gameOver || currentGuess.length !== CODE_LENGTH) return;
  const guess = [...currentGuess];
  const feedback = scoreGuess(secret, guess); // <- the WASM call
  history.push({ guess, feedback });
  currentGuess = [];
  renderBoard();
  renderCurrentGuess();

  if (feedback.blacks === CODE_LENGTH) {
    gameOver = true;
    showOverlay(true);
  } else if (history.length >= MAX_ATTEMPTS) {
    gameOver = true;
    showOverlay(false);
  }
}

function newGame(): void {
  secret = randomSecret();
  currentGuess = [];
  history = [];
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
    engineStatusEl.textContent = "wasm ready";
    engineStatusEl.className = "ready";
    renderPalette();
    newGame();
  } catch (err) {
    engineStatusEl.textContent = "wasm load failed";
    console.error(err);
  }
}

void main();
