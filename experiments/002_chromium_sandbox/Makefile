SHELL := /bin/bash
LEG ?= 1a

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

build: ## Install npm dependencies (playwright, pg)
	npm install --no-audit --no-fund

# === Run ===

run: build ## Run one leg standalone (vars: LEG=1a|1b|2a|2b|3a|3b|4a|4b)
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
