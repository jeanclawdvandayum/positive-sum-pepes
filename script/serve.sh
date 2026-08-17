#!/usr/bin/env bash
# Fetch the PSP frontend straight from the blockchain — no server, no domain.
# The factory's html() holds the entire site; any RPC will serve it.
#
# usage: ./script/serve.sh <factory-address> [rpc-url] [out.html]
set -euo pipefail
F=${1:?usage: serve.sh <factory> [rpc] [out.html]}
R=${2:-https://mainnet.base.org}
OUT=${3:-psp.html}

cast call "$F" 'html()(string)' --rpc-url "$R" \
  | python3 -c 'import sys,json;sys.stdout.write(json.loads(sys.stdin.read()))' \
  > "$OUT"

echo "wrote $OUT ($(wc -c <"$OUT") bytes) — open it in any browser"
echo "the same bytes are on-chain: cast call $F 'html()(string)' --rpc-url $R"
