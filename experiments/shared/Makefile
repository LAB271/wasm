SHELL := /bin/bash

.PHONY: help test

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@echo "  Shared benchmark library (lib/bench.sh)"
	@echo ""
	@echo "  make test    Run bats tests for bench.sh"
	@echo ""

test: ## Run bats tests for lib/bench.sh
	@command -v bats >/dev/null 2>&1 || { echo "bats not found — brew install bats-core"; exit 1; }
	bats tests/
