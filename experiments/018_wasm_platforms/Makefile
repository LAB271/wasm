SHELL := /bin/bash

.PHONY: help install verify verify-baseline verify-containerd-shim verify-k3d-spinkube verify-platforms portability-test clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Install ===

install: ## Install everything not already present (k3d, kubectl, helm, wash, fastly, wrangler)
	@command -v k3d >/dev/null || brew install k3d
	@command -v kubectl >/dev/null || brew install kubernetes-cli
	@command -v helm >/dev/null || brew install helm
	@command -v wash >/dev/null || brew install wasmcloud/wasmcloud/wash
	@command -v fastly >/dev/null || brew install fastly
	@rustup target add wasm32-wasip2
	@echo "Run 'npm install -g --allow-scripts=esbuild,workerd wrangler' if wrangler is missing"
	@echo "(see scripts/verify-platform-runtimes.sh, which does this automatically)."

# === Verify (the local-testability matrix, one target per architecture/leg) ===

# Each leg reports its own outcome, so one unavailable prerequisite must not
# abort the others — a missing container engine should not hide the portability
# results. `-` lets make continue; the legs' own SKIP/BLOCKED/BROKEN lines carry
# the verdict.
verify: ## Run the fast verification legs (skips the two slow/heavy k8s+shim installs)
	-@./scripts/verify-baseline.sh
	@echo ""
	-@./scripts/verify-platform-runtimes.sh
	@echo ""
	-@./scripts/portability-test.sh

verify-baseline: ## Architecture 1: container running a normal process (docker run hello-world)
	./scripts/verify-baseline.sh

verify-containerd-shim: ## Architecture 3: WASM via containerd shim (runwasi), raw ctr — installs a shim into the colima guest
	./scripts/verify-containerd-shim.sh

verify-k3d-spinkube: ## Architecture 3 via Kubernetes: k3d + SpinKube spin-operator + RuntimeClass
	./scripts/verify-k3d-spinkube.sh

verify-platforms: ## Install + version-check all four platform runtimes (spin, wash, wrangler, fastly/viceroy)
	./scripts/verify-platform-runtimes.sh

portability-test: ## Build one wasi-http component, run it unmodified on 5 runtimes, report pass/fail
	./scripts/portability-test.sh

# === Clean ===

clean: ## Remove build output from the portability test component
	rm -rf portability/hello/target
	rm -rf /tmp/wasm018-*
