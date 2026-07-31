SHELL := /bin/bash
PORT ?= 8899
VARIANT ?= pure

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

build: ## Compile rust/ -> web/loop_{pure,alloc}.wasm, vendor the WASI shim, install playwright
	./build.sh

# === Run ===

run: build ## Serve web/ with COOP/COEP headers at :$(PORT) (vars: PORT, VARIANT=pure|alloc)
	@echo "→ open http://127.0.0.1:$(PORT)/index.html?variant=$(VARIANT)"
	python3 web/coi_server.py $(PORT)

# === Test ===

test: build ## Kill-switch verification via headless Chromium, both variants (~10s)
	./benchmark.sh

# === Clean ===

clean: ## Remove build output
	rm -rf web/loop_pure.wasm web/loop_alloc.wasm web/vendor web/node_modules
	rm -rf rust/target node_modules
