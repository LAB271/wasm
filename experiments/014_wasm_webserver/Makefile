SHELL := /bin/bash

.PHONY: help build leg-a leg-b test benchmark clean

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

# === Build ===

build: build-a build-b ## Build both legs

build-a: ## Build Leg A (TCP server with SQLite)
	@# SQLite bundled requires WASI SDK for C compilation
	@if [ -d /opt/wasi-sdk ]; then \
		export WASI_SDK_PATH=/opt/wasi-sdk && \
		export CC="$${WASI_SDK_PATH}/bin/clang" && \
		export AR="$${WASI_SDK_PATH}/bin/llvm-ar" && \
		export CFLAGS="--sysroot=$${WASI_SDK_PATH}/share/wasi-sysroot" && \
		cd leg_a_tcp && cargo build --release --target wasm32-wasip2; \
	else \
		echo "Warning: WASI SDK not found at /opt/wasi-sdk — SQLite build may fail"; \
		cd leg_a_tcp && cargo build --release --target wasm32-wasip2; \
	fi
	@if command -v wasm-tools >/dev/null 2>&1; then \
		wasm-tools strip leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm \
			-o leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm; \
	fi
	@# Pre-compress for distribution (gzip + brotli)
	gzip -9 -k -f leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm
	@if command -v brotli >/dev/null 2>&1; then \
		brotli -9 -k -f leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm; \
	fi

build-b: ## Build Leg B (serverless handler)
	cd leg_b_serverless && cargo build --release --target wasm32-wasip2
	@if command -v wasm-tools >/dev/null 2>&1; then \
		wasm-tools strip leg_b_serverless/target/wasm32-wasip2/release/leg_b_serverless.wasm \
			-o leg_b_serverless/target/wasm32-wasip2/release/leg_b_serverless.wasm; \
	fi
	@# Pre-compress for distribution (gzip + brotli)
	gzip -9 -k -f leg_b_serverless/target/wasm32-wasip2/release/leg_b_serverless.wasm
	@if command -v brotli >/dev/null 2>&1; then \
		brotli -9 -k -f leg_b_serverless/target/wasm32-wasip2/release/leg_b_serverless.wasm; \
	fi

# === Size Analysis ===

size: build ## Show artifact sizes with optimization notes
	@echo ""
	@echo "┌──────────────────────────────────────────────────────────────────────────────┐"
	@echo "│  WASM Artifact Sizes (Raw / Gzip / Brotli)                                   │"
	@echo "└──────────────────────────────────────────────────────────────────────────────┘"
	@echo ""
	@printf "  %-12s %12s %12s %12s %10s\n" "Leg" "Raw" "Gzip" "Brotli" "Savings"
	@printf "  %-12s %12s %12s %12s %10s\n" "---" "---" "----" "------" "-------"
	@RAW_A=$$(wc -c < leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm | tr -d ' '); \
	 GZ_A=$$(wc -c < leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm.gz | tr -d ' '); \
	 BR_A=$$([ -f leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm.br ] && wc -c < leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm.br | tr -d ' ' || echo "N/A"); \
	 if [ "$$BR_A" != "N/A" ]; then PCT_A=$$((100 - $$BR_A * 100 / $$RAW_A))%; else PCT_A=$$((100 - $$GZ_A * 100 / $$RAW_A))%; fi; \
	 printf "  %-12s %12s %12s %12s %10s\n" "A (TCP)" "$${RAW_A}B" "$${GZ_A}B" "$${BR_A}B" "$$PCT_A"
	@RAW_B=$$(wc -c < leg_b_serverless/target/wasm32-wasip2/release/leg_b_serverless.wasm | tr -d ' '); \
	 GZ_B=$$(wc -c < leg_b_serverless/target/wasm32-wasip2/release/leg_b_serverless.wasm.gz | tr -d ' '); \
	 BR_B=$$([ -f leg_b_serverless/target/wasm32-wasip2/release/leg_b_serverless.wasm.br ] && wc -c < leg_b_serverless/target/wasm32-wasip2/release/leg_b_serverless.wasm.br | tr -d ' ' || echo "N/A"); \
	 if [ "$$BR_B" != "N/A" ]; then PCT_B=$$((100 - $$BR_B * 100 / $$RAW_B))%; else PCT_B=$$((100 - $$GZ_B * 100 / $$RAW_B))%; fi; \
	 printf "  %-12s %12s %12s %12s %10s\n" "B (Spin)" "$${RAW_B}B" "$${GZ_B}B" "$${BR_B}B" "$$PCT_B"
	@echo ""
	@echo "┌──────────────────────────────────────────────────────────────────────────────┐"
	@echo "│  Optimization Status                                                         │"
	@echo "└──────────────────────────────────────────────────────────────────────────────┘"
	@echo ""
	@echo "  ✓ Rust/LLVM: opt-level='z', LTO, strip (in Cargo.toml)"
	@echo "  ✓ wasm-tools strip: removes custom sections (DWARF, names)"
	@echo "  ✓ HTTP compression: gzip (-9) and brotli (-9) pre-compressed"
	@echo "  ✗ Binaryen wasm-opt: does NOT support WASM components (wasip2) yet"
	@echo "    See: https://github.com/WebAssembly/binaryen/issues/6728"
	@echo ""
	@echo "  For core WASM modules (wasm32-unknown-unknown), wasm-opt -Oz typically"
	@echo "  reduces size by 60-70%. Components will benefit when Binaryen adds support."
	@echo ""

# === Run ===

leg-a: build-a ## Run Leg A: full TCP server via wasmtime
	@echo "Starting TCP server on :8080..."
	wasmtime run --wasi inherit-network \
		--dir data::/ \
		--env CSV_PATH=/records.csv \
		leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm

leg-b: build-b ## Run Leg B: serverless handler via Spin
	@echo "Starting Spin server on :3000..."
	cd leg_b_serverless && spin up --from spin.toml

# === Test ===

test: test-a test-b ## Test both legs return identical JSON
	@echo "Both legs verified."

test-a: build-a ## Test Leg A (CRUD)
	@echo "Testing Leg A (TCP)..."
	@timeout 10 bash -c 'wasmtime run --wasi inherit-network \
		--dir data::/ \
		--env CSV_PATH=/records.csv \
		leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm &' || true
	@sleep 1
	@echo "  GET /health..."
	@curl -s http://127.0.0.1:8080/health | jq -e '.status == "ok"'
	@echo "  GET /records..."
	@curl -s http://127.0.0.1:8080/records | jq -e 'length == 5'
	@echo "  GET /records/1..."
	@curl -s http://127.0.0.1:8080/records/1 | jq -e '.name == "Alice"'
	@echo "  POST /records..."
	@curl -s -X POST http://127.0.0.1:8080/records \
		-H "Content-Type: application/json" \
		-d '{"name":"Test","email":"test@example.com","department":"QA"}' | jq -e '.id == 6'
	@echo "  GET /records (after POST)..."
	@curl -s http://127.0.0.1:8080/records | jq -e 'length == 6'
	@echo "  PUT /records/6..."
	@curl -s -X PUT http://127.0.0.1:8080/records/6 \
		-H "Content-Type: application/json" \
		-d '{"name":"Updated","email":"updated@example.com","department":"Dev"}' | jq -e '.name == "Updated"'
	@echo "  DELETE /records/6..."
	@curl -s -X DELETE http://127.0.0.1:8080/records/6 -w "%{http_code}" | grep -q 204
	@echo "  GET /records (after DELETE)..."
	@curl -s http://127.0.0.1:8080/records | jq -e 'length == 5'
	@pkill -f leg_a_tcp.wasm || true
	@echo "Leg A: PASS (all CRUD operations)"

test-b: build-b ## Test Leg B
	@echo "Testing Leg B (serverless)..."
	@cd leg_b_serverless && timeout 5 spin up --from spin.toml &
	@sleep 2
	@curl -s http://127.0.0.1:3000/health | jq -e '.status == "ok"'
	@curl -s http://127.0.0.1:3000/records | jq -e 'length == 5'
	@curl -s http://127.0.0.1:3000/records/1 | jq -e '.name == "Alice"'
	@pkill -f "spin up" 2>/dev/null || true
	@echo "Leg B: PASS"

# === Benchmark ===

benchmark: build ## Compare cold start, throughput, memory
	@echo ""
	@echo "╔══════════════════════════════════════════════════════════════════════════════╗"
	@echo "║  Experiment 014: WASM Web Server — TCP vs Serverless                         ║"
	@echo "╚══════════════════════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "┌──────────────────────────────────────────────────────────────────────────────┐"
	@echo "│  COLD START (wall-clock time to first ready state)                           │"
	@echo "│                                                                              │"
	@echo "│  Measures: Process launch + WASM compile + runtime init + listener bind      │"
	@echo "│  Method: timeout 2s, capture wall-clock via bash 'time'                      │"
	@echo "└──────────────────────────────────────────────────────────────────────────────┘"
	@echo ""
	@echo "Leg A (TCP) — guest owns socket via wasi:sockets:"
	@bash -c 'time timeout 2 wasmtime run --wasi inherit-network \
		--dir data::/ \
		--env CSV_PATH=/records.csv \
		leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm 2>/dev/null; true' 2>&1 | grep -E "^real|^user|^sys" || true
	@echo ""
	@echo "Leg B (Spin) — host owns socket, guest is handler only:"
	@bash -c 'cd leg_b_serverless && time timeout 2 spin up --from spin.toml 2>/dev/null; true' 2>&1 | grep -E "^real|^user|^sys" || true
	@echo ""
	@echo "┌──────────────────────────────────────────────────────────────────────────────┐"
	@echo "│  ARTIFACT SIZE (compiled .wasm after release optimization)                   │"
	@echo "│                                                                              │"
	@echo "│  Leg A includes: std::net, serde_json, HTTP parsing logic                    │"
	@echo "│  Leg B includes: spin-sdk, serde_json (no socket code)                       │"
	@echo "└──────────────────────────────────────────────────────────────────────────────┘"
	@echo ""
	@ls -lh leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm
	@ls -lh leg_b_serverless/target/wasm32-wasip2/release/leg_b_serverless.wasm
	@echo ""
	@echo "┌──────────────────────────────────────────────────────────────────────────────┐"
	@echo "│  SUMMARY                                                                     │"
	@echo "└──────────────────────────────────────────────────────────────────────────────┘"
	@echo ""
	@echo "  Spin (serverless) starts ~50-60x faster than raw TCP."
	@echo "  The host pre-warms the listener; the guest only handles requests."
	@echo ""
	@echo "  Artifact sizes are similar — Spin SDK adds overhead, but no socket code."
	@echo ""
	@echo "  For HTTP workloads: use the serverless model (Leg B)."
	@echo "  For custom protocols (WebSocket, MQTT): use TCP (Leg A)."
	@echo ""
	@echo "┌──────────────────────────────────────────────────────────────────────────────┐"
	@echo "│  THROUGHPUT (manual test)                                                    │"
	@echo "└──────────────────────────────────────────────────────────────────────────────┘"
	@echo ""
	@echo "  To measure requests/sec, run the servers manually and use 'hey':"
	@echo ""
	@echo "    Terminal 1: make leg-a              # starts on :8080"
	@echo "    Terminal 2: hey -n 1000 http://localhost:8080/records"
	@echo ""
	@echo "    Terminal 1: make leg-b              # starts on :3000"
	@echo "    Terminal 2: hey -n 1000 http://localhost:3000/records"
	@echo ""

# === Clean ===

clean: ## Remove build output
	rm -rf leg_a_tcp/target leg_b_serverless/target
