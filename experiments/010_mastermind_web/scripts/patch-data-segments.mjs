#!/usr/bin/env node
// patch-data-segments.mjs — work around a confirmed mvl WASM-backend bug:
// dead-code elimination drops (data ...) segments for string literals used
// only by `pub` functions unreached from `main()`, even though the
// function itself is still exported and still references the (now-empty)
// offsets via `i32.const`. See build.sh's top comment and README.md for
// the full writeup and how this was confirmed (adding a throwaway main()
// that calls color_name makes the segments reappear, at different
// offsets since the whole layout shifts).
//
// This script re-derives the (ptr, len) pairs directly from color_name's
// own compiled body — in source order, `if n==1 {"red"} else if n==2
// {"green"} ... else {"?"}` compiles to a strict `i32.const <ptr> /
// i32.const <len>` pair per branch, in that same order — and injects the
// matching (data ...) segments. Reading them back out of the WAT rather
// than hardcoding offsets means this keeps working if a future mvl
// version changes the exact layout, as long as the branch order in
// code.mvl's color_name doesn't change.
import { readFileSync, writeFileSync } from "node:fs";

const watPath = process.argv[2];
if (!watPath) {
  console.error("Usage: node patch-data-segments.mjs <path/to/code.wat>");
  process.exit(2);
}

const wat = readFileSync(watPath, "utf-8");

const bodyMatch = wat.match(/\(func \$color_name [\s\S]*?\n  \)\n/);
if (!bodyMatch) {
  console.error("patch-data-segments: could not find $color_name in", watPath);
  process.exit(1);
}
const body = bodyMatch[0];

const consts = [...body.matchAll(/i32\.const (\d+)/g)].map((m) => Number(m[1]));
if (consts.length !== 14) {
  console.error(
    `patch-data-segments: expected 14 i32.const values (7 ptr/len pairs) in $color_name, found ${consts.length}. ` +
      "color_name's source shape changed — update this script's assumptions before trusting its output.",
  );
  process.exit(1);
}

// Must match code.mvl's color_name branch order exactly.
const LITERALS = ["red", "green", "blue", "yellow", "orange", "purple", "?"];

const segments = [];
for (let i = 0; i < LITERALS.length; i++) {
  const ptr = consts[i * 2];
  const len = consts[i * 2 + 1];
  const literal = LITERALS[i];
  if (len !== literal.length) {
    console.error(
      `patch-data-segments: branch ${i} length mismatch — WAT says len=${len}, expected literal "${literal}" (len=${literal.length}). Aborting rather than writing a wrong data segment.`,
    );
    process.exit(1);
  }
  segments.push(`  (data (i32.const ${ptr}) "${literal}")`);
}

if (wat.includes("(data (i32.const")) {
  console.error(
    "patch-data-segments: code.wat already has (data ...) segments — this script is meant for the DCE-dropped-segments case only. Refusing to double-patch.",
  );
  process.exit(1);
}

// Insert right before the final closing paren of the module.
const trimmed = wat.replace(/\)\s*$/, "");
const patched = `${trimmed}${segments.join("\n")}\n)\n`;
writeFileSync(watPath, patched);
console.log(`patch-data-segments: injected ${segments.length} data segments into ${watPath}`);
