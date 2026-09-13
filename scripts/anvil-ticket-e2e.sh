#!/usr/bin/env bash
# Local-only receipt tests for the linear ticket release. Uses disposable Anvil keys.
set -euo pipefail
cd "$(dirname "$0")/.."
RPC=http://127.0.0.1:18545
if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  echo 'Port 18545 is occupied. Stop that test node before starting a fresh run.' >&2
  exit 1
fi
anvil --host 127.0.0.1 --port 18545 --chain-id 31337 --gas-limit 80000000 --silent > /tmp/psp-ticket-anvil-node.log 2>&1 &
node_pid=$!
trap 'kill "$node_pid" 2>/dev/null || true' EXIT
for _ in {1..30}; do
  if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
PSP_ANVIL=1 PSP_TESTNET=0 PSP_PREDEPOSIT_SEC=259200 PSP_VEST_SEC=2419200 PSP_DET_SEC=248660 PSP_WALLET_CAP_MIX=0 \
  forge script script/DeployPSP.s.sol --rpc-url "$RPC" --broadcast --slow \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  > /tmp/psp-ticket-anvil-deploy.log 2>&1
node frontend/scripts/anvil-tickets.mjs
forge test --fork-url "$RPC" --match-contract 'RealV4LifecycleTest|SineStatefulTest|ClockDetonation'
