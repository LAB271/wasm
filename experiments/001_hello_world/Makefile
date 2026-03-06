.PHONY: test test-smoke bench bench-quick clean

test:  ## Run unit tests (bats)
	bats tests/

bench:  ## Run full benchmark
	./benchmark.sh

bench-quick:  ## Quick benchmark (10 requests)
	HEY_N=10 ./benchmark.sh

clean:  ## Remove .venv, node_modules, target dirs
	rm -rf leg4a_flask_postgres/.venv
	rm -rf leg2a_pyodide_node/node_modules
	rm -rf leg2b_pyodide_chromium/node_modules
	rm -rf leg2c_pyodide_playwright/node_modules
	rm -rf leg4b_wasm_postgres_bridge/node_modules
	rm -rf leg4c_wasmtime_postgres/node_modules
	rm -rf ../shared/rust-hello/target
	rm -rf leg4c_wasmtime_postgres/target

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
