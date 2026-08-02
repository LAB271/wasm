SHELL := /bin/bash
PORT ?= 8010
ENGINE ?= rust

.PHONY: help build build-rust build-as build-ui build-inline run test test-unit test-browser clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: build-rust build-as build-ui build-inline ## Build both engines, the UI, and inline-base64 variants

build-rust: ## Compile engines/rust -> web/engine-rust.wasm (cargo, wasm32-unknown-unknown)
	cd engines/rust && cargo build --target wasm32-unknown-unknown --release
	@if command -v wasm-opt >/dev/null 2>&1; then \
		wasm-opt -Oz engines/rust/target/wasm32-unknown-unknown/release/mastermind_engine.wasm -o web/engine-rust.wasm; \
	else \
		cp engines/rust/target/wasm32-unknown-unknown/release/mastermind_engine.wasm web/engine-rust.wasm; \
	fi
	@# Pre-compress for HTTP serving (gzip + brotli)
	gzip -9 -k -f web/engine-rust.wasm
	@if command -v brotli >/dev/null 2>&1; then \
		brotli -9 -k -f web/engine-rust.wasm; \
	fi

build-as: ## Compile engines/assemblyscript -> web/engine-as.wasm (asc)
	@if [ ! -d engines/assemblyscript/node_modules ]; then \
		echo "  (first run — installing engines/assemblyscript/ deps)"; \
		cd engines/assemblyscript && npm install --no-audit --no-fund; \
	fi
	cd engines/assemblyscript && npm run build
	@# Pre-compress for HTTP serving (gzip + brotli)
	gzip -9 -k -f web/engine-as.wasm
	@if command -v brotli >/dev/null 2>&1; then \
		brotli -9 -k -f web/engine-as.wasm; \
	fi

build-ui: ## Compile web/app.ts, web/inline.ts -> web/dist/*.js (tsc)
	@if [ ! -d web/node_modules ]; then \
		echo "  (first run — installing web/ deps)"; \
		cd web && npm install --no-audit --no-fund; \
	fi
	@# Separate invocations: neither file has top-level import/export, so tsc
	@# treats each as a global script — compiling them together would collide
	@# their top-level names (engineName, main, ...) in one shared scope.
	cd web && npx tsc app.ts --target es2020 --module es2020 --lib es2020,dom --strict --outDir dist
	cd web && npx tsc inline.ts --target es2020 --module es2020 --lib es2020,dom --strict --outDir dist
	@# Pre-compress for HTTP serving (gzip + brotli) — same pattern as the wasm engines
	gzip -9 -k -f web/dist/app.js web/dist/inline.js
	@if command -v brotli >/dev/null 2>&1; then \
		brotli -9 -k -f web/dist/app.js web/dist/inline.js; \
	fi

build-inline: build-rust build-as ## Base64-encode engine-*.wasm -> web/engine-*.b64.js (ES modules, for inline-loading demo)
	@printf 'export const WASM_B64 = "%s";\n' "$$(base64 -i web/engine-rust.wasm | tr -d '\n')" > web/engine-rust.b64.js
	@printf 'export const WASM_B64 = "%s";\n' "$$(base64 -i web/engine-as.wasm | tr -d '\n')" > web/engine-as.b64.js
	@# Pre-compress for HTTP serving (gzip + brotli) — same pattern as the wasm engines
	gzip -9 -k -f web/engine-rust.b64.js web/engine-as.b64.js
	@if command -v brotli >/dev/null 2>&1; then \
		brotli -9 -k -f web/engine-rust.b64.js web/engine-as.b64.js; \
	fi

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
	rm -rf web/engine-*.wasm.gz web/engine-*.wasm.br
	rm -rf web/engine-*.b64.js web/engine-*.b64.js.gz web/engine-*.b64.js.br
	rm -rf engines/rust/target

size: build ## Show WASM sizes (raw, gzip, brotli)
	@echo ""
	@echo "┌────────────────────────────────────────────────────────────┐"
	@echo "│  WASM Artifact Sizes                                       │"
	@echo "└────────────────────────────────────────────────────────────┘"
	@echo ""
	@printf "  %-20s %8s %8s %8s\n" "Engine" "Raw" "Gzip" "Brotli"
	@printf "  %-20s %8s %8s %8s\n" "------" "---" "----" "------"
	@printf "  %-20s %8s %8s %8s\n" \
		"Rust" \
		"$$(wc -c < web/engine-rust.wasm | tr -d ' ')B" \
		"$$(wc -c < web/engine-rust.wasm.gz | tr -d ' ')B" \
		"$$([ -f web/engine-rust.wasm.br ] && wc -c < web/engine-rust.wasm.br | tr -d ' ' || echo 'N/A')B"
	@printf "  %-20s %8s %8s %8s\n" \
		"AssemblyScript" \
		"$$(wc -c < web/engine-as.wasm | tr -d ' ')B" \
		"$$(wc -c < web/engine-as.wasm.gz | tr -d ' ')B" \
		"$$([ -f web/engine-as.wasm.br ] && wc -c < web/engine-as.wasm.br | tr -d ' ' || echo 'N/A')B"
	@echo ""
	@echo "  (below: base64-inlined ES modules — see README 'fetch vs inline' section)"
	@printf "  %-20s %8s %8s %8s\n" \
		"Rust (b64 inline)" \
		"$$(wc -c < web/engine-rust.b64.js | tr -d ' ')B" \
		"$$(wc -c < web/engine-rust.b64.js.gz | tr -d ' ')B" \
		"$$([ -f web/engine-rust.b64.js.br ] && wc -c < web/engine-rust.b64.js.br | tr -d ' ' || echo 'N/A')B"
	@printf "  %-20s %8s %8s %8s\n" \
		"AS (b64 inline)" \
		"$$(wc -c < web/engine-as.b64.js | tr -d ' ')B" \
		"$$(wc -c < web/engine-as.b64.js.gz | tr -d ' ')B" \
		"$$([ -f web/engine-as.b64.js.br ] && wc -c < web/engine-as.b64.js.br | tr -d ' ' || echo 'N/A')B"
	@echo ""
	@echo "  (below: compiled+compressed JS, same pre-compression pattern as the wasm/b64 rows above)"
	@printf "  %-20s %8s %8s %8s\n" \
		"dist/app.js" \
		"$$(wc -c < web/dist/app.js | tr -d ' ')B" \
		"$$(wc -c < web/dist/app.js.gz | tr -d ' ')B" \
		"$$([ -f web/dist/app.js.br ] && wc -c < web/dist/app.js.br | tr -d ' ' || echo 'N/A')B"
	@printf "  %-20s %8s %8s %8s\n" \
		"dist/inline.js" \
		"$$(wc -c < web/dist/inline.js | tr -d ' ')B" \
		"$$(wc -c < web/dist/inline.js.gz | tr -d ' ')B" \
		"$$([ -f web/dist/inline.js.br ] && wc -c < web/dist/inline.js.br | tr -d ' ' || echo 'N/A')B"
	@echo ""
