#!/usr/bin/env bash
set -euo pipefail

PORT=5001
NAME="leg1-flask"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect container runtime: honour $CONTAINER_CMD if set, else auto-detect
if [ -z "${CONTAINER_CMD:-}" ]; then
  if command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
    CONTAINER_CMD="podman"
  elif command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    CONTAINER_CMD="docker"
  else
    echo "✗ No running container runtime found (podman or docker)" >&2
    echo "  Run: ./install.sh --start   (to start podman machine)" >&2
    exit 1
  fi
fi
echo "→ Using container runtime: $CONTAINER_CMD"

# Stop any existing container with this name
$CONTAINER_CMD rm -f "$NAME" &>/dev/null || true

# Build
echo "→ Building image..."
$CONTAINER_CMD build -t "$NAME" "$DIR"

# Run detached
echo "→ Starting container on port $PORT..."
$CONTAINER_CMD run -d --name "$NAME" -p "$PORT:5001" "$NAME"

# Wait for readiness
echo -n "→ Waiting for HTTP..."
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT/" &>/dev/null; then
    echo " ready"
    curl -s "http://127.0.0.1:$PORT/" | python3 -m json.tool
    exit 0
  fi
  sleep 0.5
done
echo " timeout" >&2
exit 1
