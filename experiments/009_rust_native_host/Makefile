SHELL := /bin/bash
MODE ?= --single-shot

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

build: ## Compile guest/ (wasm32-unknown-unknown) and host/ (embeds wasmtime)
	./build.sh

# === Run ===

run: build ## Run the embedded host once (vars: MODE=--single-shot|"--loop N")
	./host/target/release/wasm_host $(MODE)

# === Test ===

test: build ## Full cold-start / warm-loop benchmark
	./benchmark.sh

# === Clean ===

clean: ## Remove build output
	rm -rf guest/target host/target
