#!/usr/bin/env bats
# 001's own tests: not the shared library's internals (those live in
# experiments/shared/tests/), but how *this* experiment wires that library to
# its own legs. Structural contracts that break silently when a leg is added,
# renamed, or abandoned.

setup() {
  DIR="$BATS_TEST_DIRNAME/.."
  BENCH="$DIR/benchmark.sh"
}

# ── the lib/ symlink actually delivers what benchmark.sh calls ────────────────

@test "the shared library is reachable by relative path (no symlink)" {
  [ ! -L "$DIR/lib" ]
  [ -f "$DIR/../shared/lib/bench.sh" ]
  grep -q 'source "\$SCRIPT_DIR/../shared/lib/bench.sh"' "$BENCH"
}

@test "every shared function benchmark.sh calls is actually defined in shared/lib/bench.sh" {
  source "$DIR/../shared/lib/bench.sh"
  for fn in require_port_free cold_start_ms wait_for_http rss_mb hey_stat \
            human_size kill_and_wait descendant_pids detect_container_cmd; do
    run declare -F "$fn"
    [ "$status" -eq 0 ] || { echo "benchmark.sh calls $fn but shared/lib/bench.sh does not define it"; return 1; }
  done
}

# ── legs and benchmark.sh agree with each other ──────────────────────────────

@test "every leg directory benchmark.sh references exists on disk" {
  for leg in $(grep -oE 'leg[0-9][a-z]?_[a-z_]+' "$BENCH" | sort -u); do
    [ -d "$DIR/$leg" ] || { echo "benchmark.sh references $leg but the directory is missing"; return 1; }
  done
}

@test "no orphaned leg directories (every leg on disk is driven by benchmark.sh)" {
  local orphans=""
  for d in "$DIR"/leg*/; do
    local leg; leg=$(basename "$d")
    grep -q "$leg" "$BENCH" || orphans="$orphans $leg"
  done
  [ -z "$orphans" ] || { echo "leg dirs never referenced by benchmark.sh:$orphans"; return 1; }
}

@test "every referenced leg has an executable run.sh" {
  for leg in $(grep -oE 'leg[0-9][a-z]?_[a-z_]+' "$BENCH" | sort -u); do
    [ -f "$DIR/$leg/run.sh" ] || { echo "$leg has no run.sh"; return 1; }
    [ -x "$DIR/$leg/run.sh" ] || { echo "$leg/run.sh is not executable"; return 1; }
  done
}

# ── port discipline: 001 assigns one port per leg and pre-flights each one ────

@test "no two legs are assigned the same port" {
  # Ports are declared via require_port_free, not PORT= assignments — an
  # earlier version of this test grepped PORT= , matched nothing, and passed
  # vacuously.
  local ports dupes
  ports=$(grep -oE 'require_port_free [0-9]{4}' "$BENCH" | grep -oE '[0-9]{4}' | sort)
  [ -n "$ports" ] || { echo "found no port declarations at all — test would pass vacuously"; return 1; }
  dupes=$(echo "$ports" | uniq -d)
  [ -z "$dupes" ] || { echo "duplicate port assignments: $dupes"; return 1; }
}

@test "every port 001 serves on is pre-flight checked with require_port_free" {
  local served checked missing=""
  served=$(grep -oE '\b50[0-9]{2}\b' "$BENCH" | sort -u)
  checked=$(grep -oE 'require_port_free [0-9]{4}' "$BENCH" | grep -oE '[0-9]{4}' | sort -u)
  for p in $served; do
    echo "$checked" | grep -qx "$p" || missing="$missing $p"
  done
  [ -z "$missing" ] || { echo "ports served without a require_port_free guard:$missing"; return 1; }
}
