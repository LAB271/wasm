#!/bin/bash
# Architecture 1: container running a normal process.
# The baseline every other architecture in this experiment is compared against.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Architecture 1: container running a normal Linux process ==="
echo ""

if ! command -v docker &>/dev/null; then
    echo "docker not found — install Docker Desktop or colima+docker."
    exit 1
fi

echo "-- docker info (runtime, storage driver) --"
if ! info=$(docker info 2>&1); then
    echo "$info" | head -5
    echo ""
    echo "FAIL: \`docker info\` failed — the engine is not reachable."
    echo "      Start it (\`podman machine start\` / \`colima start\`) and re-run."
    exit 1
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
    echo "$run_out" | head -20
    echo ""
    echo "FAIL: \`docker run hello-world\` did not complete."
    echo "      Nothing was verified — do not read the baseline as confirmed."
    exit 1
fi
echo "$run_out" | head -5

echo ""
echo "Baseline confirmed: the container engine dispatches to '${default_rt}', which"
echo "execs a normal Linux process (containerized). This is the reference point"
echo "architectures 2 and 3 are compared against."
