SHELL := /bin/bash

.PHONY: help build run test clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: ## Compile guest/ (wasm32-wasip1) and host/ (embeds wasmtime + wasmtime-wasi)
	./build.sh

build-opt: build ## Build + optimize with wasm-opt (requires binaryen)
	@if command -v wasm-opt >/dev/null 2>&1; then \
		echo "Optimizing with wasm-opt -Oz..."; \
		wasm-opt -Oz --enable-bulk-memory \
			guest/target/wasm32-wasip1/release/mastermind-guest.wasm \
			-o guest/target/wasm32-wasip1/release/mastermind-guest-opt.wasm; \
		ls -lh guest/target/wasm32-wasip1/release/mastermind-guest.wasm; \
		ls -lh guest/target/wasm32-wasip1/release/mastermind-guest-opt.wasm; \
	else \
		echo "wasm-opt not found. Install binaryen: brew install binaryen"; \
	fi

size: build ## Show artifact sizes
	@echo ""
	@echo "WASM artifact sizes:"
	@ls -lh guest/target/wasm32-wasip1/release/mastermind-guest.wasm
	@if [ -f guest/target/wasm32-wasip1/release/mastermind-guest-opt.wasm ]; then \
		ls -lh guest/target/wasm32-wasip1/release/mastermind-guest-opt.wasm; \
	fi
	@echo ""
	@echo "Run 'make build-opt' to create optimized version with wasm-opt."

# === Run ===

run: build ## Run the embedded host (reads real stdin interactively)
	./host/target/release/mastermind-host

# === Test ===

test: build ## Non-interactive verification: pipe two guesses through the host
	printf "1 2 3 4\n2 3 4 5\n" | ./host/target/release/mastermind-host

# === Solver ===

solver: ## Run the Python solver sideways (pass rounds as args: make solver ARGS="1 1 2 2 1 0")
	python3 solve.py $(ARGS)

# === Clean ===

clean: ## Remove build output
	rm -rf guest/target host/target
