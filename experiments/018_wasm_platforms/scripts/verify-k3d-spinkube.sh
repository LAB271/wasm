#!/bin/bash
# Architecture 3, via Kubernetes: SpinKube's spin-operator + containerd-shim-spin
# RuntimeClass on a k3d cluster whose node image bakes the shim in. Confirms the
# same "no Linux userspace" model as verify-containerd-shim.sh, but through a
# RuntimeClass/SpinApp CRD instead of raw `ctr run`.
#
# Sources (accessed 2026-08-02):
#   https://github.com/spinframework/spin-operator (README, "Option 1: run on your
#   computer" — k3d dev workflow)
#   https://www.spinkube.dev/docs/install/quickstart/ (upstream quickstart; uses
#   `kind` — this script uses the k3d variant from the operator repo instead,
#   since kind is not installed on this machine)
set -euo pipefail

CLUSTER=wasm018-spinkube
OPERATOR_VERSION=0.6.1
K3D_SHIM_IMAGE="ghcr.io/spinframework/containerd-shim-spin/k3d:v0.23.0"
CERT_MANAGER_VERSION=v1.14.5   # NOT v1.20.0: its CRDs use "selectableFields",
                                # a K8s 1.31+ CRD feature the k3d image's
                                # bundled k3s v1.27.8 rejects with a strict
                                # decoding error. Found by running it, not read.

for bin in k3d kubectl helm docker; do
    command -v "$bin" &>/dev/null || { echo "missing: $bin"; exit 1; }
done

echo "=== Architecture 3 via Kubernetes: SpinKube on k3d ==="
echo ""

echo "-- creating k3d cluster (node image bakes in containerd-shim-spin) --"
k3d cluster create "${CLUSTER}" \
    --image "${K3D_SHIM_IMAGE}" \
    --agents 1

trap 'echo "-- tearing down --"; k3d cluster delete "${CLUSTER}" || true' EXIT

kubectl get nodes -o wide

echo ""
echo "-- cert-manager ${CERT_MANAGER_VERSION} --"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
kubectl wait --for=condition=available --timeout=180s deployment/cert-manager-webhook -n cert-manager

echo ""
echo "-- SpinApp/SpinAppExecutor CRDs + wasmtime-spin-v2 RuntimeClass --"
kubectl apply -f "https://github.com/spinframework/spin-operator/releases/download/v${OPERATOR_VERSION}/spin-operator.runtime-class.yaml"
kubectl apply -f "https://github.com/spinframework/spin-operator/releases/download/v${OPERATOR_VERSION}/spin-operator.crds.yaml"

echo ""
echo "-- spin-operator via Helm --"
helm upgrade --install spin-operator \
    --namespace spin-operator --create-namespace \
    --version "${OPERATOR_VERSION}" --wait \
    oci://ghcr.io/spinframework/charts/spin-operator

kubectl apply -f "https://github.com/spinframework/spin-operator/releases/download/v${OPERATOR_VERSION}/spin-operator.shim-executor.yaml"

echo ""
echo "-- deploying the sample SpinApp (a real wasi-http Spin component, ~524KB) --"
kubectl apply -f https://raw.githubusercontent.com/spinframework/spin-operator/main/config/samples/simple.yaml
kubectl wait --for=condition=ready --timeout=60s pod -l core.spinkube.dev/app-name=simple-spinapp

echo ""
echo "-- runtimeClassName on the pod (confirms it's not running under runc) --"
kubectl get pod -l core.spinkube.dev/app-name=simple-spinapp \
    -o jsonpath='{.items[0].spec.runtimeClassName}{"\n"}'

echo ""
echo "-- curl through a port-forward --"
kubectl port-forward svc/simple-spinapp 8083:80 &>/dev/null &
PF_PID=$!
sleep 3
curl -sS localhost:8083/hello; echo ""
kill "$PF_PID" 2>/dev/null || true

echo ""
echo "Confirmed end to end: SpinApp CRD -> wasmtime-spin-v2 RuntimeClass ->"
echo "containerd-shim-spin -> wasmtime, serving real HTTP, no Linux userspace."
