.PHONY: help deps build build-js build-py build-rust build-as run test bench bench-quick clean

.DEFAULT_GOAL := help

CONTAINER_CMD ?= $(shell command -v podman 2>/dev/null || echo docker)
GIT_ROOT      := $(shell git rev-parse --show-toplevel)
VENV          := $(GIT_ROOT)/.venv
ACTIVATE      := . $(VENV)/bin/activate &&
BUILD_DIR     := build
PORT          ?= 5030
WASM_LANG     ?= rust

help: ## Show this help
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# === .* ===$$/  { sub(/^# === /, ""); sub(/ ===$$/, ""); printf "\n\033[33m%s\033[0m\n", $$0 } \
	  /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""

$(VENV)/bin/activate: requirements.txt
	uv venv --clear $(VENV)
	uv pip install --quiet --python $(VENV)/bin/python3 -r requirements.txt
	@touch $(VENV)/bin/activate

# === Setup ===

deps: $(VENV)/bin/activate  ## Install toolchain dependencies (spin, componentize-py, hey)
	@echo "→ Installing Spin..."
	brew install fermyon/tap/spin
	@echo "→ Installing hey (HTTP load generator)..."
	brew install hey
	@echo "✓ deps ready  (componentize-py in $(VENV); JS deps fetched at build time by spin build)"

# === Build ===

build: build-js build-py build-rust build-as  ## Compile all sources to .wasm → build/
	@echo "✓ All .wasm artifacts in $(BUILD_DIR)/"

build-js:  ## Build JS → .wasm (Spin)
	@echo "→ Building JS (Spin)..."
	cd js-spin && spin build
	@mkdir -p $(BUILD_DIR)
	cp js-spin/dist/hello-js.wasm $(BUILD_DIR)/hello-js-spin.wasm

build-py: $(VENV)/bin/activate  ## Build Python → .wasm (componentize-py + Spin)
	@mkdir -p $(BUILD_DIR)
	@echo "→ Building Python/raw (componentize-py)..."
	cd python-raw && VIRTUAL_ENV= $(VENV)/bin/componentize-py -d wit -w example:hello/proxy --all-features componentize app -o hello-py-raw.wasm
	cp python-raw/hello-py-raw.wasm $(BUILD_DIR)/hello-py-raw.wasm
	@echo "→ Building Python (Spin)..."
	cd python-spin && $(ACTIVATE) spin build
	cp python-spin/app.wasm $(BUILD_DIR)/hello-py-spin.wasm

build-rust:  ## Build Rust → .wasm (cargo wasm32-wasip2)
	@echo "→ Building Rust baseline..."
	cd rust-hello && cargo build --target wasm32-wasip2 --release --quiet
	@mkdir -p $(BUILD_DIR)
	cp rust-hello/target/wasm32-wasip2/release/leg3.wasm $(BUILD_DIR)/hello-rust.wasm

build-as:  ## Build AssemblyScript → .wasm (asc + wasm-tools)
	@echo "→ Building AssemblyScript (asc + wasm-tools)..."
	cd as-hello && npm install --silent && ./build.sh
	@mkdir -p $(BUILD_DIR)
	cp as-hello/build/hello-as.wasm $(BUILD_DIR)/hello-as.wasm

# === Run ===

run: build ## Serve one leg standalone via wasmtime (vars: WASM_LANG=rust|as, PORT=5030) -- js/py legs need containers/venv, see `make bench`
	wasmtime serve -S cli --addr "127.0.0.1:$(PORT)" $(BUILD_DIR)/hello-$(WASM_LANG).wasm

# === Test ===

test:  ## Run BATS unit tests
	bats tests/

bench:  ## Run full 7-leg benchmark
	./benchmark.sh

bench-quick:  ## Quick benchmark (10 requests)
	HEY_N=10 ./benchmark.sh

# === Clean ===

clean:  ## Remove build artifacts
	rm -rf $(BUILD_DIR)
	rm -rf $(VENV)
	rm -rf js-spin/node_modules js-spin/build js-spin/dist
	rm -f python-spin/app.wasm
	rm -f python-raw/hello-py-raw.wasm
	rm -rf rust-hello/target
	rm -rf as-hello/node_modules as-hello/build
	$(CONTAINER_CMD) rmi -f hello-js-spin hello-py-spin 2>/dev/null || true
