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

build: ## Compile rust/ -> web/line_flood.wasm, vendor the WASI shim
	./build.sh

# === Run ===

run: build ## Serve web/ at :$(PORT) (vars: PORT; open ?n=1000&dom=1 to set line count / DOM sink)
	@echo "→ open http://127.0.0.1:$(PORT)/index.html?n=1000&dom=1"
	python3 -m http.server $(PORT) --bind 127.0.0.1 --directory web

# === Test ===

test: build ## Full N x dom benchmark matrix (vars: RUNS)
	./benchmark.sh

# === Clean ===

clean: ## Remove build output
	rm -rf web/line_flood.wasm web/vendor web/node_modules
	rm -rf rust/target
