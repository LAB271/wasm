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

build: ## Compile custom_runtime/rust -> wasm32-unknown-unknown
	cd custom_runtime/rust && cargo build --target wasm32-unknown-unknown --release

# === Run ===

run: build ## Instantiate the custom-runtime leg once and print the result (Node)
	cd custom_runtime/harness && node measure.mjs

# === Test ===

test: ## Build + measure all three legs (custom runtime, componentize-py, Pyodide), ~15-20s
	./benchmark.sh

# === Clean ===

clean: ## Remove build output
	rm -rf custom_runtime/rust/target
