SHELL := /bin/bash
PORT ?= 8899

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

build: ## Compile rust/ -> web/hello_wasi.wasm, vendor the WASI shim
	./build.sh

# === Run ===

run: build ## Serve web/ at :$(PORT) and print the URL to open (vars: PORT)
	@echo "→ open http://127.0.0.1:$(PORT)/index.html"
	python3 -m http.server $(PORT) --bind 127.0.0.1 --directory web

# === Test ===

test: build ## Cold-start benchmark, 10 runs (vars: RUNS)
	./benchmark.sh

# === Clean ===

clean: ## Remove build output
	rm -rf web/hello_wasi.wasm web/vendor web/node_modules
	rm -rf rust/target
