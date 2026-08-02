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
docker info 2>&1 | grep -iE "runtime|storage driver|server version" || true

echo ""
echo "-- docker run hello-world --"
docker run --rm hello-world 2>&1 | head -5

echo ""
echo "Baseline confirmed: docker daemon dispatches to runc, which execs a normal"
echo "Linux process (containerized). This is the reference point architectures"
echo "2 and 3 are compared against."
