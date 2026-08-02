SHELL := /bin/bash
LEG ?= 1a

.PHONY: help build build-wasm run test bench bench-quick clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: ## Install npm dependencies (playwright, pg)
	npm install --no-audit --no-fund

build-wasm: ## Build native WASM workloads for legs 5a/5b (Rust + AssemblyScript)
	cd workloads/rust && cargo build --target wasm32-unknown-unknown --release
	wasm-bindgen --target web --out-dir workloads/rust/pkg \
	  workloads/rust/target/wasm32-unknown-unknown/release/cpu_bound.wasm
	cd workloads/assemblyscript && npm install --no-audit --no-fund && npm run build
	command -v wasm-opt >/dev/null && { \
	  wasm-opt -Oz --enable-bulk-memory workloads/rust/pkg/cpu_bound_bg.wasm -o workloads/rust/pkg/cpu_bound_bg.wasm; \
	  wasm-opt -Oz --enable-bulk-memory workloads/assemblyscript/build/cpu_bound.wasm -o workloads/assemblyscript/build/cpu_bound.wasm; \
	} || echo "wasm-opt not found — skipping size optimization (binaryen: brew install binaryen)"

# === Run ===

run: build ## Run one leg standalone (vars: LEG=1a|1b|2a|2b|3a|3b|4a|4b|5a|5b)
	node harness.js $(LEG)

# === Test ===

test: ## Run unit tests (bats)
	bats tests/

bench: ## Run full benchmark
	./benchmark.sh

bench-quick: ## Quick benchmark (10 requests)
	HEY_N=10 ./benchmark.sh

# === Clean ===

clean: ## Remove node_modules
	rm -rf node_modules
