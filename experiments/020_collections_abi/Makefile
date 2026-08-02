SHELL := /bin/bash

.PHONY: help build test bench report ordering sizes glue disasm probe clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: ## Build all six guest legs + the wasmtime host (runs build.sh)
	./build.sh

# === Test ===

test: ## Validate every .wasm and assert cross-leg parity on all four collections
	@echo ""
	@echo "Validating WASM outputs..."
	@PASS=0; FAIL=0; \
	for wasm in output/*.wasm; do \
		if wasm-tools validate "$$wasm" 2>/dev/null; then \
			echo "  ✓ $$wasm"; PASS=$$((PASS + 1)); \
		else \
			echo "  ✗ $$wasm (invalid)"; FAIL=$$((FAIL + 1)); \
		fi; \
	done; \
	echo ""; echo "$$PASS passed, $$FAIL failed"; \
	[ $$FAIL -eq 0 ]
	@echo ""
	@echo "Parity (every leg must return identical checksums):"
	@python3 scripts/report.py | sed -n '/^### parity/,$$p'

# === Benchmarks ===

bench: build ## Run the full matrix, forward and reverse leg order (writes results/)
	./run.sh both

ordering: build ## Ordering-bias check only: same matrix twice, opposite order
	./run.sh both && python3 scripts/report.py | sed -n '/^### ordering/,/^### parity/p'

report: ## Print the markdown tables from results/ (run `make bench` first)
	@python3 scripts/report.py

# === Analysis ===

sizes: build ## Guest binary sizes, raw and after wasm-opt -Oz
	@printf "  %-34s %10s %10s\n" "artifact" "raw" "-Oz"
	@for w in output/*.wasm; do \
		oz=$$(wasm-opt -Oz --enable-bulk-memory --enable-reference-types --enable-multivalue \
		      "$$w" -o /tmp/020oz.wasm 2>/dev/null && wc -c < /tmp/020oz.wasm | tr -d ' ' || echo "n/a"); \
		printf "  %-34s %10s %10s\n" "$$(basename $$w)" "$$(wc -c < $$w | tr -d ' ')" "$$oz"; \
	done

glue: ## Count lines of glue code per leg (the cost nobody reports)
	@python3 scripts/glue_loc.py

disasm: ## Show what each toolchain generated: canonical ABI lifts, bindgen shims
	@echo "=== Component Model: canonical ABI lowering (wasm-tools print) ==="
	@wasm-tools print output/component.wasm | grep -E 'canon lift' | sed 's/^ */  /'
	@echo ""
	@echo "=== Component Model: the WIT the component actually declares ==="
	@wasm-tools component wit output/component.wasm | sed 's/^/  /'
	@echo ""
	@echo "=== wasm-bindgen: how a returned String is spelled ==="
	@echo "  rustc core export (scratch return pointer):"
	@wasm-tools print guests/rust_bindgen/target/wasm32-unknown-unknown/release/collections_bindgen.wasm \
	  | grep -E '^  \(func \$$str_upper_ascii ' | sed 's/^/  /'
	@echo "  after wasm-bindgen post-processing (multi-value shim):"
	@wasm-tools print output/rust_bindgen.wasm | grep -E 'export "str_upper_ascii"' | sed 's/^/  /'

probe: build ## Verify AssemblyScript's string layout by running it, not by citing docs
	@node js/as_layout_probe.mjs

# === Clean ===

clean: ## Remove build output and captured results
	rm -rf output results
	rm -rf guests/rust_manual/target guests/rust_bindgen/target guests/component/target
	rm -rf guests/rust_bindgen/pkg guests/assemblyscript/build guests/assemblyscript/node_modules
	rm -rf host/target
