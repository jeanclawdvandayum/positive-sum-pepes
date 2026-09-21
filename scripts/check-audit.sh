#!/usr/bin/env bash
# Local deterministic audit gates; network forks are a separate explicit gate.
set -euo pipefail
cd "$(dirname "$0")/.."
forge test --no-match-path 'test/integration/*'
python3 scripts/formal/test_runner.py
node script/gen_expanded_art.mjs --check
node script/expanded-art-fixtures.mjs --check
bash scripts/check-no-governance.sh
python3 scripts/check-sizes.py
python3 scripts/sine_oracle.py --check
python3 scripts/sine_v3.py --check
python3 scripts/sine_v3_price.py --check
python3 scripts/sine_v3_small_reserve.py --check
python3 scripts/sine_v3_primitive_validate.py
node --experimental-strip-types frontend/scripts/check-abi.mjs
node --experimental-strip-types --test frontend/tests/*.test.mjs
node --experimental-strip-types --test scripts/names/*.test.mjs
(cd frontend && ./node_modules/.bin/tsc -b && ./node_modules/.bin/vite build)
