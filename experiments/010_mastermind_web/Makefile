SHELL := /bin/bash
PORT ?= 8010
ENGINE ?= rust

.PHONY: help build build-rust build-as build-ui run test test-unit test-browser clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: build-rust build-as build-ui ## Build both engines and the UI

build-rust: ## Compile engines/rust -> web/engine-rust.wasm (cargo, wasm32-unknown-unknown)
	cd engines/rust && cargo build --target wasm32-unknown-unknown --release
	@if command -v wasm-opt >/dev/null 2>&1; then \
		wasm-opt -Oz engines/rust/target/wasm32-unknown-unknown/release/mastermind_engine.wasm -o web/engine-rust.wasm; \
	else \
		cp engines/rust/target/wasm32-unknown-unknown/release/mastermind_engine.wasm web/engine-rust.wasm; \
	fi

build-as: ## Compile engines/assemblyscript -> web/engine-as.wasm (asc)
	@if [ ! -d engines/assemblyscript/node_modules ]; then \
		echo "  (first run — installing engines/assemblyscript/ deps)"; \
		cd engines/assemblyscript && npm install --no-audit --no-fund; \
	fi
	cd engines/assemblyscript && npm run build

build-ui: ## Compile web/app.ts -> web/dist/app.js (tsc)
	@if [ ! -d web/node_modules ]; then \
		echo "  (first run — installing web/ deps)"; \
		cd web && npm install --no-audit --no-fund; \
	fi
	cd web && npx tsc app.ts --target es2020 --module es2020 --lib es2020,dom --strict --outDir dist

# === Run ===

# Foreground: `make run` execs serve.py in this same process, so Ctrl+C
# stops it directly — no background PID, no signal trap to get wrong.
run: build ## Build everything and serve at :$(PORT) (vars: PORT, ENGINE=rust|as)
	@echo "→ open http://127.0.0.1:$(PORT)/?engine=$(ENGINE)"
	exec python3 serve.py $(PORT)

# === Test ===

test: test-unit test-browser ## Run everything below

test-unit: build ## cargo test (Rust logic) + tests/wasm.test.mjs (both engines, in Node)
	cd engines/rust && cargo test
	node tests/wasm.test.mjs

test-browser: build ## tests/browser.test.mjs — real headless Chrome, both engines (vars: PORT)
	@if [ ! -d tests/node_modules ]; then \
		echo "  (first run — installing tests/ deps)"; \
		cd tests && npm install --no-audit --no-fund; \
	fi
	node tests/browser.test.mjs $(PORT)

# === Clean ===

clean: ## Remove all build output
	rm -rf web/dist web/engine-rust.wasm web/engine-as.wasm web/engine-as.debug.wasm
	rm -rf engines/rust/target
