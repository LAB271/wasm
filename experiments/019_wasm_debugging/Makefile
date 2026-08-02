SHELL := /bin/bash
PORT ?= 8019

.PHONY: help build test check-sections traces profile-guest size serve clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: ## Build all 4 tiers + 3 profiling variants + native wasmtime host (runs build.sh)
	./build.sh

# === Test ===

test: build check-sections traces ## Build, then run all automated checks below

check-sections: ## H1: validate + list custom sections (name/DWARF) per tier, verify DWARF well-formedness
	./scripts/check_sections.sh

traces: ## H2 + H5: capture real trap stack traces + host-log output, wasmtime host and Node, all tiers
	./scripts/capture_traces.sh

profile-guest: ## H4: wasmtime --profile=guest on zero-import builds, check name resolution
	./scripts/profile_guest.sh

# === Analysis ===

size: build ## Show raw/gzip/brotli sizes and multiplier over tier1 for all tiers
	@echo ""
	@echo "┌──────────────────────────────────────────────────────────────────────┐"
	@echo "│  019 — WASM Debugging: Size Tiers                                    │"
	@echo "└──────────────────────────────────────────────────────────────────────┘"
	@echo ""
	@printf "  %-28s %10s %10s %10s %8s\n" "Tier" "Raw" "Gzip" "Brotli" "x tier1"
	@printf "  %-28s %10s %10s %10s %8s\n" "----" "---" "----" "------" "-------"
	@base=$$(wc -c < output/tier1_fully_optimized.wasm | tr -d ' '); \
	for f in output/tier1_fully_optimized.wasm output/tier2_optimized_names.wasm \
	         output/tier3_release_debuginfo.wasm output/tier4_full_debug.wasm; do \
		name=$$(basename "$$f" .wasm); \
		raw=$$(wc -c < "$$f" | tr -d ' '); \
		gz=$$(gzip -9 -c "$$f" | wc -c | tr -d ' '); \
		br=$$(brotli -9 -c "$$f" | wc -c | tr -d ' '); \
		mult=$$(echo "scale=1; $$raw / $$base" | bc); \
		printf "  %-28s %9sB %9sB %9sB %7sx\n" "$$name" "$$raw" "$$gz" "$$br" "$$mult"; \
	done
	@echo ""

# === Manual verification ===

serve: build ## Serve web/ for manual Chrome DevTools DWARF verification (see README)
	@echo "→ open http://127.0.0.1:$(PORT)/"
	cd web && python3 -m http.server $(PORT)

# === Clean ===

clean: ## Remove all build output
	rm -rf module/target host/target output wasmtime-guest-profile.json
