.PHONY: deps build test bench bench-quick clean help

CONTAINER_CMD ?= $(shell command -v podman 2>/dev/null || echo docker)
VENV          := .venv
COMPONENTIZE  := $(VENV)/bin/componentize-py

$(VENV)/bin/activate: requirements.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet -r requirements.txt
	@touch $(VENV)/bin/activate

deps: $(VENV)/bin/activate  ## Install toolchain dependencies (spin, componentize-py, hey)
	@echo "→ Installing Spin..."
	brew install fermyon/tap/spin
	@echo "→ Installing hey (HTTP load generator)..."
	brew install hey
	@echo "→ JS deps..."
	cd js-spin && npm install
	@echo "✓ deps ready  (componentize-py in $(VENV))"

build: $(VENV)/bin/activate  ## Compile all sources to .wasm
	@echo "→ Building JS (Spin)..."
	cd js-spin && npm install --silent && spin build
	@echo "→ Building Python/raw (componentize-py)..."
	cd python-raw && ../$(COMPONENTIZE) -d wit -w proxy componentize app -o hello-py-raw.wasm
	@echo "→ Building Python (Spin)..."
	cd python-spin && spin build
	@echo "→ Building Rust baseline..."
	cd rust && cargo build --target wasm32-wasip2 --release --quiet
	@echo "✓ All .wasm artifacts built"

test:  ## Run BATS unit tests
	bats tests/

bench:  ## Run full 6-leg benchmark
	./benchmark.sh

bench-quick:  ## Quick benchmark (10 requests)
	HEY_N=10 ./benchmark.sh

clean:  ## Remove build artifacts
	rm -rf $(VENV)
	rm -rf js-spin/node_modules js-spin/target
	rm -f python-spin/app.wasm
	rm -f python-raw/hello-py-raw.wasm
	rm -rf rust/target
	$(CONTAINER_CMD) rmi -f hello-js-spin hello-py-spin 2>/dev/null || true

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
