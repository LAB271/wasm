#!/usr/bin/env python3
"""Mastermind solver — run alongside the game to narrow down possibilities.

Takes all rounds as arguments. Each round is: guess(4 colors) + blacks + whites.

Usage:
    python3 solve.py 1 1 2 2 1 0                    # one round
    python3 solve.py 1 1 2 2 1 0  3 3 4 4 0 1       # two rounds
    python3 solve.py -c 8 1 1 2 2 1 0                # 8 colors instead of 6
"""

import sys
from collections import Counter
from itertools import product


def score(secret: tuple[int, ...], guess: tuple[int, ...]) -> tuple[int, int]:
    blacks = sum(s == g for s, g in zip(secret, guess))
    total_color_matches = sum((Counter(secret) & Counter(guess)).values())
    return blacks, total_color_matches - blacks


def filter_possible(
    possible: list[tuple[int, ...]],
    guess: tuple[int, ...],
    blacks: int,
    whites: int,
) -> list[tuple[int, ...]]:
    return [c for c in possible if score(c, guess) == (blacks, whites)]


def rank_candidates(
    possible: list[tuple[int, ...]], n: int = 10
) -> list[tuple[tuple[int, ...], int]]:
    results: list[tuple[tuple[int, ...], int]] = []
    for guess in possible:
        partitions: Counter[tuple[int, int]] = Counter()
        for code in possible:
            partitions[score(code, guess)] += 1
        worst_surviving = max(partitions.values())
        kills = len(possible) - worst_surviving
        results.append((guess, kills))
    results.sort(key=lambda x: -x[1])
    return results[:n]


def fmt(code: tuple[int, ...]) -> str:
    return " ".join(str(c) for c in code)


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Mastermind solver")
    parser.add_argument(
        "-p", "--positions", type=int, default=4, help="code length (default: 4)"
    )
    parser.add_argument(
        "-c", "--colors", type=int, default=6, help="number of colors (default: 6)"
    )
    parser.add_argument("rounds", nargs="*", type=int, help="c1..cN blacks whites [...]")
    args = parser.parse_args()

    positions: int = args.positions
    colors: int = args.colors
    nums: list[int] = args.rounds
    stride = positions + 2

    if not nums:
        parser.print_help()
        sys.exit(1)
    if len(nums) % stride != 0:
        print(f"Error: expected multiples of {stride} numbers (got {len(nums)})", file=sys.stderr)
        sys.exit(1)

    all_codes = list(product(range(1, colors + 1), repeat=positions))
    possible = list(all_codes)

    for i in range(0, len(nums), stride):
        guess = tuple(nums[i : i + positions])
        blacks = nums[i + positions]
        whites = nums[i + positions + 1]

        if not all(1 <= c <= colors for c in guess):
            print(f"Error: colors must be 1–{colors} (got {fmt(guess)})", file=sys.stderr)
            sys.exit(1)
        if blacks + whites > positions or blacks < 0 or whites < 0:
            print(f"Error: invalid feedback {blacks}B {whites}W", file=sys.stderr)
            sys.exit(1)

        possible = filter_possible(possible, guess, blacks, whites)
        rnd = i // stride + 1
        print(f"Round {rnd}: {fmt(guess)}  →  {blacks}B {whites}W  |  {len(possible)} left")

        if blacks == positions:
            print(f"\nSolved: {fmt(guess)}")
            return
        if not possible:
            print("\nNo codes match — check your feedback for errors.")
            sys.exit(1)

    print()
    if len(possible) == 1:
        print(f"Solution: {fmt(possible[0])}")
        return

    if len(possible) <= 20:
        print(f"All remaining: {', '.join(fmt(c) for c in possible)}")
        print()

    print(f"Top candidates (worst-case kills):")
    for i, (code, kills) in enumerate(rank_candidates(possible, 10), 1):
        pct = kills * 100 // len(possible)
        print(f"  {i:2d}. {fmt(code)}   kills {kills:>4d}/{len(possible)}  ({pct}%)")


if __name__ == "__main__":
    main()
