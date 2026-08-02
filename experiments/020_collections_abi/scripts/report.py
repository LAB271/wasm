#!/usr/bin/env python3
"""Turn results/*.jsonl into the markdown tables the README quotes.

Also prints the forward-vs-reverse ordering check, which is the evidence that
the per-cell-fresh-process scheme actually removed the bias issue #52 documents.
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent
RESULTS = HERE / "results"

LEG_ORDER = ["wat", "rust_manual", "rust_bindgen", "assemblyscript", "component", "externref"]
OP_GROUPS = {
    "call overhead": ["callcost", "callcost_list"],
    "strings": ["str"],
    "lists": ["list"],
    "maps": ["map_sorted", "map_hash", "map_handle", "map", "map_host"],
    "sets": ["set_bitset", "set_sorted", "set_hash", "set_host"],
}


def load(name):
    p = RESULTS / f"{name}.jsonl"
    if not p.exists():
        return {}
    out = {}
    for line in p.read_text().splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        r["checksum"] = int(r["checksum"])
        out[(r["leg"], r["op"])] = r
    return out


def us(ns):
    return "—" if ns is None else f"{ns / 1000:.1f}"


def main():
    fwd = load("forward")
    rev = load("reverse")
    if not fwd:
        print("no results — run ./run.sh both", file=sys.stderr)
        return 1

    for group, ops in OP_GROUPS.items():
        rows = [
            (leg, op, fwd[(leg, op)])
            for leg in LEG_ORDER
            for op in ops
            if (leg, op) in fwd
        ]
        if not rows:
            continue
        print(f"\n### {group}\n")
        print("| leg | variant | bytes copied | marshal µs | compute µs | total µs | spread (total) |")
        print("|---|---|---:|---:|---:|---:|---|")
        for leg, op, r in rows:
            m = r["marshal"]["median_ns"] if r["marshal"] else None
            t = r["total"]
            spread = f"{t['min_ns']/1000:.1f}–{t['max_ns']/1000:.1f}"
            print(
                f"| {leg} | {op} | {r['bytes']:,} | {us(m)} | "
                f"{us(r['call']['median_ns'])} | {us(t['median_ns'])} | {spread} |"
            )

    if rev:
        print("\n### ordering check — forward vs reverse pass\n")
        print("| leg | variant | total µs (forward) | total µs (reverse) | ratio |")
        print("|---|---|---:|---:|---:|")
        for k in fwd:
            if k not in rev:
                continue
            a = fwd[k]["total"]["median_ns"]
            b = rev[k]["total"]["median_ns"]
            print(f"| {k[0]} | {k[1]} | {a/1000:.1f} | {b/1000:.1f} | {a/b:.2f}x |")

    # Parity: every leg computing the same op must agree bit-for-bit.
    print("\n### parity\n")
    by_op = {}
    for (leg, op), r in fwd.items():
        if op.startswith("callcost"):
            continue
        family = next((g for g, ops in OP_GROUPS.items() if op in ops), op)
        by_op.setdefault(family, {})[f"{leg}:{op}"] = r["checksum"]
    ok = True
    for family, m in sorted(by_op.items()):
        vals = set(m.values())
        status = "all agree" if len(vals) == 1 else f"MISMATCH {m}"
        ok &= len(vals) == 1
        print(f"- **{family}** ({len(m)} cells): {status} — `{hex(next(iter(vals)))}`")
    print(f"\nparity overall: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
