.PHONY: deps build build-js build-py build-rust test bench bench-quick clean help

CONTAINER_CMD ?= $(shell command -v podman 2>/dev/null || echo docker)
# .venv lives at the project root (git root)
GIT_ROOT      := $(shell git rev-parse --show-toplevel)
VENV          := $(GIT_ROOT)/.venv
ACTIVATE      := . $(VENV)/bin/activate &&

$(VENV)/bin/activate: requirements.txt
	uv venv --clear $(VENV)
	uv pip install --quiet -r requirements.txt
	@touch $(VENV)/bin/activate

deps: $(VENV)/bin/activate  ## Install toolchain dependencies (spin, componentize-py, hey)
	@echo "→ Installing Spin..."
	brew install fermyon/tap/spin
	@echo "→ Installing hey (HTTP load generator)..."
	brew install hey
	@echo "✓ deps ready  (componentize-py in $(VENV); JS deps fetched at build time by spin build)"

build: build-js build-py build-rust  ## Compile all sources to .wasm
	@echo "✓ All .wasm artifacts built"

build-js:  ## Build JS → .wasm (Spin)
	@echo "→ Building JS (Spin)..."
	cd js-spin && spin build

build-py: $(VENV)/bin/activate  ## Build Python → .wasm (componentize-py + Spin)
	@echo "→ Building Python/raw (componentize-py)..."
	cd python-raw && VIRTUAL_ENV= $(VENV)/bin/componentize-py -d wit -w example:hello/proxy componentize app -o hello-py-raw.wasm
	@echo "→ Building Python (Spin)..."
	cd python-spin && $(ACTIVATE) spin build

build-rust:  ## Build Rust → .wasm (cargo wasm32-wasip2)
	@echo "→ Building Rust baseline..."
	cd rust && cargo build --target wasm32-wasip2 --release --quiet

test:  ## Run BATS unit tests
	bats tests/

bench:  ## Run full 6-leg benchmark
	./benchmark.sh

bench-quick:  ## Quick benchmark (10 requests)
	HEY_N=10 ./benchmark.sh

clean:  ## Remove build artifacts
	rm -rf $(VENV)
	rm -rf js-spin/node_modules js-spin/build js-spin/dist
	rm -f python-spin/app.wasm
	rm -f python-raw/hello-py-raw.wasm
	rm -rf rust/target
	$(CONTAINER_CMD) rmi -f hello-js-spin hello-py-spin 2>/dev/null || true

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
