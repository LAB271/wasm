#!/bin/bash
# Architecture 1: container running a normal process.
# The baseline every other architecture in this experiment is compared against.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Architecture 1: container running a normal Linux process ==="
echo ""

# An absent or unreachable container engine is a missing prerequisite on this
# machine, not a finding about WASM — so it SKIPs (exit 0) and lets the rest of
# `make verify` run. Only a reachable engine that then misbehaves is a failure.
if ! command -v docker &>/dev/null; then
    echo "SKIP    no docker/podman CLI on PATH — install Docker Desktop, podman, or colima"
    exit 0
fi

echo "-- docker info (runtime, storage driver) --"
if ! info=$(docker info 2>&1); then
    echo "SKIP    container engine not reachable — \`docker info\` failed."
    echo "        Start it (\`podman machine start\` / \`colima start\`) and re-run."
    echo "        Architectures 2 and 3 need it too; the other legs still ran."
    exit 0
fi
echo "$info" | grep -iE "runtime|storage driver|server version" || true

# What `docker` actually is here matters: on this machine the CLI may be podman
# (or podman-docker), whose default runtime is crun rather than runc. Report what
# is really in use rather than asserting runc.
default_rt=$(echo "$info" | sed -n 's/.*Default Runtime: *//p' | head -1)
default_rt=${default_rt:-unknown}

echo ""
echo "-- docker run hello-world --"
# Capture first, then trim. Piping a running container straight into `head` gives
# it SIGPIPE, and `set -o pipefail` turns that into exit 141 as soon as the output
# is longer than the trim — exactly what happens when the image must be pulled.
if ! run_out=$(docker run --rm hello-world 2>&1); then
    echo "$run_out" | head -10
    echo ""
    echo "BROKEN  engine is reachable but \`docker run hello-world\` failed."
    echo "        Nothing was verified — this one really is a problem."
    exit 1
fi
# Docker's hello-world prints ~14 lines of prose about what it just proved.
# One line is enough to show it ran.
echo "$run_out" | grep -m1 -iE "hello from" || echo "$run_out" | head -1

echo ""
echo "RUNS    architecture 1 — container running a normal Linux process"
echo "        engine dispatches to '${default_rt}', which execs a real Linux"
echo "        process in namespaces/cgroups. The reference point that"
echo "        architectures 2 and 3 are measured against."
