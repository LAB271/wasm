SHELL := /bin/bash
LEG ?= leg3_wasmtime

.PHONY: help build run test bench bench-quick clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: ## No standalone build -- each leg's run.sh builds itself; see `make run LEG=<leg>`
	@echo "No standalone build step here -- each leg builds inline via its own run.sh."
	@echo "Use: make run LEG=<leg>  (see README's Legs table for valid names)"

# === Run ===

run: ## Run one leg standalone (vars: LEG=leg1_flask_docker|leg2a_pyodide_node|leg2b_pyodide_chromium|leg2c_pyodide_playwright|leg3_wasmtime|leg4a_flask_postgres|leg4b_wasm_postgres_bridge|leg4c_wasmtime_postgres)
	./$(LEG)/run.sh

# === Test ===

# Division of labour: experiments/shared/tests/ tests the library functions
# themselves; these test how 001 *applies* them — that its legs, ports and
# library calls actually agree with each other. The bench.sh-internals tests
# that used to live here were duplicates, and they drifted (31s here vs 2.5s
# in shared, because only shared got optimised).
test: ## Run 001's wiring tests (bats)
	bats tests/

bench: ## Run full benchmark
	./benchmark.sh

bench-quick: ## Quick benchmark (10 requests)
	HEY_N=10 ./benchmark.sh

# === Clean ===

clean: ## Remove .venv, node_modules, target dirs
	rm -rf leg4a_flask_postgres/.venv
	rm -rf leg2a_pyodide_node/node_modules
	rm -rf leg2b_pyodide_chromium/node_modules
	rm -rf leg2c_pyodide_playwright/node_modules
	rm -rf leg4b_wasm_postgres_bridge/node_modules
	rm -rf leg4c_wasmtime_postgres/node_modules
	rm -rf leg3_wasmtime/target
	rm -rf leg4c_wasmtime_postgres/target
