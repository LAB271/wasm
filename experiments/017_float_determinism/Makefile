SHELL := /bin/bash

.PHONY: help build matrix test size clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: ## Build both wasm-lib variants + the wasmtime driver (runs build.sh)
	./build.sh

# === Test ===

test: build ## Validate all WASM outputs and confirm zero imports on the full build
	@echo ""
	@echo "Validating WASM outputs..."
	@PASS=0; FAIL=0; \
	for wasm in output/*.wasm; do \
		if wasm-tools validate "$$wasm" 2>/dev/null; then \
			echo "  ✓ $$wasm"; PASS=$$((PASS + 1)); \
		else \
			echo "  ✗ $$wasm (invalid)"; FAIL=$$((FAIL + 1)); \
		fi; \
	done; \
	echo ""; echo "$$PASS passed, $$FAIL failed"; \
	[ $$FAIL -eq 0 ]
	@echo ""
	@echo "Checking output/determinism_full.wasm has zero imports..."
	@if command -v wasm-objdump >/dev/null 2>&1; then \
		IMPORTS=$$(wasm-objdump -x output/determinism_full.wasm | awk '/^Import\[/{flag=1;next}/^[A-Z][a-z]+\[/{flag=0}flag'); \
		if [ -z "$$IMPORTS" ]; then echo "  ✓ no host imports"; else echo "  ✗ unexpected imports:"; echo "$$IMPORTS"; exit 1; fi; \
	else \
		echo "  wasm-objdump not found — install via 'brew install wabt'"; \
	fi

# === Analysis ===

matrix: build ## Run the full {JS impl, WASM impl} x {host} determinism matrix
	./run_matrix.sh

size: build ## Show the H4 libm size delta (arith-only vs full trig build)
	@echo ""
	@printf "  %-40s %10s\n" "Artifact" "Size"
	@printf "  %-40s %10s\n" "--------" "----"
	@for wasm in output/*.wasm; do \
		name=$$(basename "$$wasm"); \
		size=$$(wc -c < "$$wasm" | tr -d ' '); \
		printf "  %-40s %10s\n" "$$name" "$${size}B"; \
	done
	@echo ""

# === Clean ===

clean: ## Remove build output and captured results
	rm -rf output/*.wasm
	rm -rf results
	rm -rf rust/compute/target rust/wasm-lib/target rust/wasm-driver/target
