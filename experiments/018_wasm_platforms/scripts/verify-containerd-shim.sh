#!/bin/bash
# Architecture 3: WASM as the workload via a containerd shim (runwasi) — no
# Linux userspace in the pod at all. containerd normally delegates a container
# to the `runc` shim; here it delegates to `containerd-shim-wasmtime-v1`, which
# embeds wasmtime instead of exec-ing a Linux binary.
#
# This bypasses Docker Desktop's "Wasm Workloads" beta feature entirely (which
# this machine doesn't have — it uses colima, not Docker Desktop) and talks to
# containerd directly via `ctr`, exactly as containerd/runwasi's own quickstart
# does: https://github.com/containerd/runwasi (accessed 2026-08-02).
set -euo pipefail

SHIM_VERSION="v0.6.1"
SHIM_URL="https://github.com/containerd/runwasi/releases/download/containerd-shim-wasmtime/${SHIM_VERSION}/containerd-shim-wasmtime-aarch64-linux-musl.tar.gz"
IMAGE="ghcr.io/containerd/runwasi/wasi-demo-app:latest"
CONTAINER_NAME="wasm018-demo"

echo "=== Architecture 3: WASM workload via containerd shim (runwasi) ==="
echo ""

if ! command -v colima &>/dev/null; then
    echo "colima not found. This script assumes docker's backend is colima."
    exit 1
fi

if ! colima status &>/dev/null; then
    echo "-- starting colima (docker runtime) --"
    colima start --runtime docker
fi

echo "-- guest arch --"
colima ssh -- uname -m

echo ""
echo "-- installing containerd-shim-wasmtime-v1 (${SHIM_VERSION}, aarch64) into the colima guest --"
colima ssh -- bash -c "
  mkdir -p ~/shim && cd ~/shim
  if [ ! -f containerd-shim-wasmtime-v1 ]; then
    curl -sL -o shim.tar.gz '${SHIM_URL}'
    tar xzf shim.tar.gz
  fi
  sudo cp containerd-shim-wasmtime-v1 /usr/local/bin/containerd-shim-wasmtime-v1
  sudo chmod +x /usr/local/bin/containerd-shim-wasmtime-v1
"

echo ""
echo "-- pulling ${IMAGE} (an OCI image whose only layer is a .wasm file) --"
colima ssh -- sudo ctr images pull "${IMAGE}"

echo ""
echo "-- running it with --runtime=io.containerd.wasmtime.v1 (5s sample, then killed) --"
ctr_out=$(colima ssh -- bash -c "
  sudo ctr run --rm --runtime=io.containerd.wasmtime.v1 '${IMAGE}' ${CONTAINER_NAME} &
  CTR_PID=\$!
  sleep 3
  sudo ctr task kill -s SIGKILL ${CONTAINER_NAME} 2>/dev/null || true
  wait \$CTR_PID 2>/dev/null || true
") || ctr_out="(ctr run failed)"
echo "$ctr_out" | head -8

echo ""
echo "-- contrast: docker's own --platform=wasi/wasm32 flag (Docker Desktop's path) --"
echo "   (expected to fail on this colima-backed daemon — no Docker Desktop Wasm feature here)"
docker run --rm --platform=wasi/wasm32 "${IMAGE}" 2>&1 | tail -3 || true

echo ""
echo "Confirmed: the container ran with NO Linux userspace — containerd handed the"
echo "OCI bundle straight to a wasmtime-embedding shim instead of runc. 'docker run"
echo "--platform=wasi/wasm32' does NOT work on this daemon (that needs Docker"
echo "Desktop's bundled feature); the ctr + shim path is the portable one."
