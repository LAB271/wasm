SHELL := /bin/bash

.PHONY: help build build-guest build-host run test benchmark clean postgres-start postgres-stop

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Infrastructure ===

postgres-start: ## Start Postgres in Podman
	@if podman ps -a --format '{{.Names}}' | grep -q '^postgres015$$'; then \
		podman start postgres015; \
	else \
		podman run -d --name postgres015 \
			-e POSTGRES_PASSWORD=secret \
			-p 5432:5432 \
			postgres:16-alpine; \
	fi
	@echo "Waiting for Postgres to be ready..."
	@sleep 2
	@until podman exec postgres015 pg_isready -U postgres > /dev/null 2>&1; do sleep 1; done
	@echo "Postgres ready on :5432"

postgres-stop: ## Stop Postgres container
	podman stop postgres015 || true

postgres-logs: ## Show Postgres logs
	podman logs -f postgres015

# === Build ===

build: build-guest build-host ## Build guest WASM and host binary

build-guest: ## Build guest WASM module
	cd guest && cargo build --target wasm32-unknown-unknown --release
	@if command -v wasm-opt >/dev/null 2>&1; then \
		wasm-opt -Oz guest/target/wasm32-unknown-unknown/release/pg_guest.wasm \
			-o guest/target/wasm32-unknown-unknown/release/pg_guest.wasm; \
	fi
	@ls -lh guest/target/wasm32-unknown-unknown/release/pg_guest.wasm

build-host: ## Build host binary
	cd host && cargo build --release

# === Run ===

run: build postgres-start ## Build and run CRUD test
	cd host && cargo run --release -- --test

test: run ## Alias for run

benchmark: build postgres-start ## Run benchmark (100 iterations)
	cd host && cargo run --release -- --benchmark 1000

# === Size ===

size: build-guest ## Show WASM artifact size
	@echo ""
	@echo "Guest WASM size:"
	@ls -lh guest/target/wasm32-unknown-unknown/release/pg_guest.wasm
	@echo ""
	@if command -v wasm-opt >/dev/null 2>&1; then \
		echo "  ✓ wasm-opt applied"; \
	else \
		echo "  ⚠ wasm-opt not found (install binaryen for smaller output)"; \
	fi

# === Clean ===

clean: ## Remove build output
	rm -rf guest/target host/target
