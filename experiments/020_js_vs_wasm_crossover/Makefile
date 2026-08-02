SHELL := /bin/bash

.PHONY: help build test rematch axis1 axis2 matrix browser bench clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: ## cargo build + wasm-opt -Oz/-O3 (runs build.sh)
	./build.sh

test: build ## cargo test + validate both wasm variants
	cargo test --manifest-path rust/crossover/Cargo.toml
	@wasm-tools validate output/crossover_oz.wasm && echo "  ✓ crossover_oz.wasm"
	@wasm-tools validate output/crossover_o3.wasm && echo "  ✓ crossover_o3.wasm"

# === Benchmarks ===

rematch: build ## The 010 rematch: 4 JS formulations vs WASM -Oz/-O3, with JIT tier/deopt trace
	node --trace-opt --trace-deopt js/bench_010_rematch.mjs

axis1: build ## Axis 1 — what crosses the boundary (typed arrays, plain arrays, strings, objects)
	node js/bench_axis1.mjs

axis2: build ## Axis 2 — work per crossing (granularity sweep + OLS decomposition)
	node js/bench_axis2.mjs

matrix: build ## Cross-engine scalar rematch: node, bun, jsc, spidermonkey
	./run_matrix.sh

browser: build ## Confirm the rematch holds in real headless Chrome (Playwright)
	cd tests && node perf.mjs

bench: rematch axis1 axis2 matrix browser ## Everything — the full benchmark suite

# === Clean ===

clean: ## Remove build output and captured results
	rm -rf output/*.wasm
	rm -rf results
	rm -rf rust/crossover/target
