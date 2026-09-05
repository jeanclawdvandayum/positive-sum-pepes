#!/usr/bin/env bash
# Local deterministic audit gates; network forks are a separate explicit gate.
set -euo pipefail
cd "$(dirname "$0")/.."
forge test --no-match-path 'test/integration/*'
bash scripts/check-no-governance.sh
python3 scripts/check-sizes.py
python3 scripts/sine_oracle.py --check
node --experimental-strip-types frontend/scripts/check-abi.mjs
node --experimental-strip-types --test frontend/tests/*.test.mjs
(cd frontend && ./node_modules/.bin/tsc -b && ./node_modules/.bin/vite build)
