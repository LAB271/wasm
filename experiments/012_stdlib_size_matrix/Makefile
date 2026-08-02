SHELL := /bin/bash

.PHONY: help build test benchmark size clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: ## Build all legs (runs build.sh)
	./build.sh

# === Test ===

test: ## Verify all WASM files exist and are valid (does not rebuild)
	@echo ""
	@echo "Verifying WASM outputs..."
	@PASS=0; FAIL=0; \
	for wasm in output/*.wasm; do \
		if [ -f "$$wasm" ]; then \
			if wasm-tools validate "$$wasm" 2>/dev/null; then \
				echo "  ✓ $$wasm"; \
				PASS=$$((PASS + 1)); \
			else \
				echo "  ✗ $$wasm (invalid)"; \
				FAIL=$$((FAIL + 1)); \
			fi; \
		else \
			echo "  ✗ $$wasm (missing)"; \
			FAIL=$$((FAIL + 1)); \
		fi; \
	done; \
	echo ""; \
	echo "$$PASS passed, $$FAIL failed"; \
	[ $$FAIL -eq 0 ]

# === Analysis ===

benchmark: build ## Run size analysis benchmark
	./benchmark.sh

size: build ## Show artifact sizes
	@echo ""
	@echo "┌────────────────────────────────────────────────────────────┐"
	@echo "│  Stdlib Size Matrix — WASM Artifact Sizes                  │"
	@echo "└────────────────────────────────────────────────────────────┘"
	@echo ""
	@printf "  %-30s %10s\n" "Leg" "Size"
	@printf "  %-30s %10s\n" "---" "----"
	@for wasm in output/*.wasm; do \
		name=$$(basename "$$wasm" .wasm); \
		size=$$(wc -c < "$$wasm" | tr -d ' '); \
		printf "  %-30s %10s\n" "$$name" "$${size}B"; \
	done
	@echo ""

# === Clean ===

clean: ## Remove build output
	rm -rf output/*.wasm
	rm -rf app/target
	rm -rf stdlib/target
