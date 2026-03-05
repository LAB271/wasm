.PHONY: test bench bench-quick clean help

test:  ## Run unit tests (bats)
	bats tests/

bench:  ## Run full benchmark
	./benchmark.sh

bench-quick:  ## Quick benchmark (10 requests)
	HEY_N=10 ./benchmark.sh

clean:  ## Remove node_modules
	rm -rf node_modules

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
