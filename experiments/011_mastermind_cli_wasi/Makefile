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

# === Run ===

run: build ## Run the embedded host (reads real stdin interactively)
	./host/target/release/mastermind-host

# === Test ===

test: build ## Non-interactive verification: pipe two guesses through the host
	printf "1 2 3 4\n2 3 4 5\n" | ./host/target/release/mastermind-host

# === Clean ===

clean: ## Remove build output
	rm -rf guest/target host/target
