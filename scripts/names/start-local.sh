#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
exec node --env-file="$HOME/.config/psp/names/pepetesters-current.env" --experimental-strip-types scripts/names/server.mjs
