SHELL := /bin/bash

.PHONY: help build build-guest build-host run test benchmark clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: build-guest build-host ## Build guest WASM and host binary

build-guest: ## Build AssemblyScript guest
	@if [ ! -d guest/node_modules ]; then \
		echo "Installing AssemblyScript dependencies..."; \
		cd guest && npm install --no-audit --no-fund; \
	fi
	cd guest && npm run build
	@ls -lh guest/build/release.wasm

build-host: ## Build Rust host
	cd host && cargo build --release

# === Run ===

run: build ## Build and run test
	cd host && cargo run --release -- --test

test: run ## Alias for run

benchmark: build ## Run FFI benchmark (10000 iterations)
	cd host && cargo run --release -- --benchmark 10000

# === Size ===

size: build-guest ## Show WASM artifact size
	@echo ""
	@echo "Guest WASM size:"
	@ls -lh guest/build/release.wasm
	@echo ""

# === Clean ===

clean: ## Remove build output
	rm -rf guest/build guest/node_modules host/target
