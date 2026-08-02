#!/usr/bin/env python3
"""Count lines of glue code per leg.

"Glue" is defined mechanically here as: every function that exists ONLY to move
a collection across the boundary — allocation entry points, wire-format encoders
and decoders, and per-element host callbacks. The four algorithm bodies
(str_stats / list_sum / map lookup / set count) are NOT glue and are not counted;
they are the same in every leg.

Nobody reports this number, and it is a real cost: it is code you write, review,
test, and get wrong. Counted lines exclude blanks and comment-only lines.
Run `scripts/glue_loc.py --verbose` to see exactly which lines were counted.
"""
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent

# leg -> list of (file, [symbols], kind)
#   kind picks the brace/paren balancing rule.
SPEC = {
    "wat (hand-written)": [
        ("guests/wat/collections.wat", ["$alloc", '(export "dealloc")', "$svec_count", "$svec_off", "$scmp"], "wat"),
        ("host/src/core_leg.rs", ["fn write", "fn u32s_le", "fn u64s_le"], "brace"),
        ("host/src/data.rs", ["pub fn svec_encode"], "brace"),
    ],
    "rust_manual": [
        ("guests/rust_manual/src/lib.rs", ["pub extern \"C\" fn alloc", "pub extern \"C\" fn dealloc", "unsafe fn svec_parts", "unsafe fn svec_get"], "brace"),
        ("host/src/core_leg.rs", ["fn write", "fn u32s_le", "fn u64s_le"], "brace"),
        ("host/src/data.rs", ["pub fn svec_encode"], "brace"),
    ],
    "rust_bindgen (generated)": [
        ("guests/rust_bindgen/pkg/collections_bindgen.js", ["__GENERATED_JS__"], "wholefile"),
    ],
    "assemblyscript": [
        ("guests/assemblyscript/assembly/index.ts", ["export function alloc", "export function alloc_str", "function svecCount", "function svecOff", "function keysBase", "function scmp"], "brace"),
        ("host/src/core_leg.rs", ["fn write", "fn utf16le", "fn u32s_le", "fn u64s_le"], "brace"),
        ("host/src/data.rs", ["pub fn svec_encode"], "brace"),
    ],
    "component (WIT)": [
        ("guests/component/wit/collections.wit", ["__WIT__"], "wholefile"),
    ],
    "externref": [
        ("host/src/externref_leg.rs", ["fn linker", "fn hv"], "brace"),
    ],
}


def strip(lines):
    out = []
    for ln in lines:
        s = ln.strip()
        if not s:
            continue
        if s.startswith((";;", "//", "*", "/*", "#")):
            continue
        out.append(ln)
    return out


def extract(path, symbols, kind):
    text = (HERE / path).read_text().splitlines()
    if kind == "wholefile":
        return strip(text)
    got = []
    for sym in symbols:
        start = next((i for i, ln in enumerate(text) if sym in ln), None)
        if start is None:
            print(f"  !! symbol not found: {sym} in {path}", file=sys.stderr)
            continue
        depth = 0
        seen = False
        for i in range(start, len(text)):
            ln = text[i]
            code = re.sub(r'"[^"]*"', "", ln)
            if kind == "wat":
                depth += code.count("(") - code.count(")")
            else:
                depth += code.count("{") - code.count("}")
                if "{" in code:
                    seen = True
                elif not seen and ln.rstrip().endswith(";"):
                    got.append(ln)
                    break
            got.append(ln)
            if (kind == "wat" and depth <= 0 and i > start) or (kind != "wat" and seen and depth <= 0):
                break
    return strip(got)


def main():
    verbose = "--verbose" in sys.argv
    print("| leg | glue LoC | hand-written? | where |")
    print("|---|---:|---|---|")
    for leg, parts in SPEC.items():
        total = 0
        where = []
        for path, syms, kind in parts:
            lines = extract(path, syms, kind)
            total += len(lines)
            where.append(f"`{pathlib.Path(path).name}` {len(lines)}")
            if verbose:
                print(f"\n--- {leg} :: {path} ({len(lines)}) ---", file=sys.stderr)
                for ln in lines:
                    print("    " + ln, file=sys.stderr)
        hand = "generated" if "generated" in leg else ("declarative" if "WIT" in leg else "yes")
        print(f"| {leg} | {total} | {hand} | {', '.join(where)} |")


if __name__ == "__main__":
    main()
