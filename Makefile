# PSP Makefile
# Common commands for building, testing, and fork testing

.PHONY: test test-fork build clean slither

# Run all unit/exploit/invariant tests (no fork needed)
test:
	forge test

# Run fork tests against mainnet
# Usage: make test-fork MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
test-fork:
	forge test --match-path "test/integration/*" --fork-url $(MAINNET_RPC_URL) -vvv

# Run only the V4 integration test
test-v4:
	forge test --match-contract V4IntegrationTest --fork-url $(MAINNET_RPC_URL) -vvv

# Run destruction lifecycle test
test-destroy:
	forge test --match-contract ForkDestructionTest --fork-url $(MAINNET_RPC_URL) -vvv

# Build
build:
	forge build

# Clean
clean:
	forge clean

# Slither static analysis
slither:
	slither . --filter-paths "test/,script/,lib/"
