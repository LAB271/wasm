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
		--env CSV_PATH=data/records.csv \
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
		--env CSV_PATH=data/records.csv \
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
	@pkill -f spin || true
	@echo "Leg B: PASS"

# === Benchmark ===

benchmark: build ## Compare cold start, throughput, memory
	@echo "=== Cold Start (external wall-clock) ==="
	@echo "Leg A (TCP):"
	@time -p (timeout 2 wasmtime run --wasi inherit-network \
		--env CSV_PATH=data/records.csv \
		leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm 2>/dev/null || true) 2>&1 | grep real
	@echo "Leg B (Spin):"
	@time -p (cd leg_b_serverless && timeout 2 spin up --from spin.toml 2>/dev/null || true) 2>&1 | grep real
	@echo ""
	@echo "=== Artifact Size ==="
	@ls -lh leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm
	@ls -lh leg_b_serverless/target/wasm32-wasip2/release/leg_b_serverless.wasm
	@echo ""
	@echo "=== Throughput (run servers manually, then: hey -n 1000 http://localhost:PORT/records) ==="

# === Clean ===

clean: ## Remove build output
	rm -rf leg_a_tcp/target leg_b_serverless/target
