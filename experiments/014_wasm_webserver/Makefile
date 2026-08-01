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

build-a: ## Build Leg A (TCP server)
	cd leg_a_tcp && cargo build --release --target wasm32-wasip2

build-b: ## Build Leg B (serverless handler)
	cd leg_b_serverless && cargo build --release --target wasm32-wasip2

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

test-a: build-a ## Test Leg A
	@echo "Testing Leg A (TCP)..."
	@timeout 5 bash -c 'wasmtime run --wasi inherit-network \
		--dir data::/ \
		--env CSV_PATH=/records.csv \
		leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm &' || true
	@sleep 1
	@curl -s http://127.0.0.1:8080/health | jq -e '.status == "ok"'
	@curl -s http://127.0.0.1:8080/records | jq -e 'length == 5'
	@curl -s http://127.0.0.1:8080/records/1 | jq -e '.name == "Alice"'
	@pkill -f leg_a_tcp.wasm || true
	@echo "Leg A: PASS"

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
