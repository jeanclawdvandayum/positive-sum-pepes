#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# anvil-e2e.sh — clock-detonation end-to-end with REAL receipts
# (staged-spawn receipts kept; governance-kill leg replaced 2026-09-01)
#
# Drives the full production lifecycle against a local anvil node, one
# broadcast per action, so every leg gets a real tx + gas receipt:
#
#   genesis deployRound (composed reserve+birth)
#   → predeposit ×2 → launch → round-1 buy → claims
#   → warp past detonationAt → detonate (permissionless rando)
#     [mark + RESERVE + BIRTH inside the one detonate tx]
#   → verify round 2 landed on the reserved addresses
#   → round-2 buy via PSPZapIn                         [round-2 ALIVE]
#
# Timings: fast playtest profile — 2m predeposit, 6×60s vest epochs,
# 10-mix wallet cap. The clock is the mainnet-real 72h (warped past).
# Usage: bash scripts/anvil-e2e.sh   (expects anvil on 8545; starts one if absent)
# Env:   PSP_CURVE (default 0 = full 34-zone staircase, the round-2 shape)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${RPC:-http://127.0.0.1:8545}"
CURVE="${PSP_CURVE:-0}"
PRE_SEC=120
VEST_SEC=360                   # ÷6 = 60s epochs

# anvil deterministic accounts — keys derived from the canonical anvil
# mnemonic (verified: cast wallet address matches the funded accounts)
K_OWNER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
K_ALICE=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
K_BOB=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
K_RANDO=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

# ── node ────────────────────────────────────────────────────────────────────
if ! cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "▪ starting anvil"
  # explicit generous gas limit: the 34-zone genesis deployRound alone runs
  # 21.4M, and some anvil builds default the block limit far too low
  anvil --port 8545 --gas-limit 80000000 >/tmp/psp-anvil.log 2>&1 &
  ANVIL_PID=$!
  trap '[ -n "${ANVIL_PID:-}" ] && kill $ANVIL_PID 2>/dev/null || true' EXIT
  sleep 2
fi

TS() { cast block latest --rpc-url "$RPC" -f timestamp; }

# evm_setTime unit probe (anvil builds differ: seconds vs milliseconds)
T0=$(TS)
cast rpc evm_setTime --rpc-url "$RPC" $((T0 + 100)) >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
if [ $(( $(TS) - T0 )) -gt 10000 ]; then TUNIT=1000; else TUNIT=1; fi
echo "▪ evm_setTime unit: ${TUNIT}"

warp_to() { # warp_to <absolute-seconds>
  cast rpc evm_setTime --rpc-url "$RPC" $(( $1 * TUNIT )) >/dev/null
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
}

RECEIPTS=/tmp/psp-e2e-receipts.txt
: > "$RECEIPTS"
receipt() { # receipt <label> <txhash>
  local gas status
  gas=$(cast receipt "$2" --rpc-url "$RPC" --json | jq -r '.gasUsed')
  status=$(cast receipt "$2" --rpc-url "$RPC" --json | jq -r '.status')
  if [ "$status" != "0x1" ]; then
    printf '%-36s %s  ✗ REVERTED (status %s)\n' "$1" "$2" "$status" | tee -a "$RECEIPTS"
    exit 1
  fi
  printf '%-36s %s  gas=%d\n' "$1" "$2" "$((gas))" | tee -a "$RECEIPTS"
}
send() { # send <label> <key> <to> [--value eth] <sig> [args...]
  local label=$1 key=$2 to=$3; shift 3
  local extra=() tx
  if [ "${1:-}" = "--value" ]; then extra=(--value "$2"); shift 2; fi
  tx=$(cast send "$to" "$@" ${extra[@]+"${extra[@]}"} --rpc-url "$RPC" --private-key "$key" --json 2>/tmp/psp-e2e-send-err.log | jq -r '.transactionHash // empty') || true
  if [ -z "$tx" ] || [ "$tx" = "null" ]; then
    echo "✗ send failed: $label"; cat /tmp/psp-e2e-send-err.log; exit 1
  fi
  receipt "$label" "$tx"
}
sort_pair() { # sort_pair <a> <b> → echoes "low high"
  if [ $(( $1 )) -le $(( $2 )) ]; then echo "$1 $2"; else echo "$2 $1"; fi
}

# ── 1. genesis (composed reserve+birth inside deployRound) ──────────────────
echo "▪ DeployPSP (PSP_ANVIL=1 PSP_CURVE=$CURVE)"
DEPLOY_LOG=/tmp/psp-e2e-deploy.log
PSP_ANVIL=1 PSP_CURVE="$CURVE" \
PSP_PREDEPOSIT_SEC=$PRE_SEC PSP_VEST_SEC=$VEST_SEC \
PSP_WALLET_CAP_MIX=10 \
  forge script DeployPSP --rpc-url "$RPC" --broadcast --private-key "$K_OWNER" 2>&1 | tee "$DEPLOY_LOG" >/dev/null
FACTORY=$(grep -o 'factory: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | tail -1 | awk '{print $2}')
MIX=$(grep -o 'ANVIL mock mixETH: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | tail -1 | awk '{print $4}')
ZAPIN=$(grep -o 'zapIn: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | tail -1 | awk '{print $2}')
echo "  factory=$FACTORY mix=$MIX zapIn=$ZAPIN"

# genesis receipt: calls to the factory in broadcast order are
# [setDescriptor, deployRound, setHtml] — deployRound is index 1
RD_TX=$(jq -r --arg f "$(echo "$FACTORY" | tr '[:upper:]' '[:lower:]')" \
  '.transactions | map(select((.to // "") | ascii_downcase == $f)) | .[1].hash' \
  broadcast/DeployPSP.s.sol/31337/run-latest.json)
if [ -n "$RD_TX" ] && [ "$RD_TX" != "null" ]; then receipt "genesis deployRound (R1)" "$RD_TX"; fi

# second pass: the reinvestor reads the REAL round from the RPC (staged
# addresses are entropy-salted — the deploying script's sim state diverges
# from the broadcast, so round-dependent ctor args must come from chain)
PSP_FACTORY="$FACTORY" PSP_ZAPIN="$ZAPIN" \
  forge script DeployReinvestor --rpc-url "$RPC" --broadcast --private-key "$K_OWNER" \
  2>&1 | tee /tmp/psp-e2e-reinvestor.log >/dev/null
RI_TX=$(jq -r '.transactions[0].hash // empty' broadcast/DeployReinvestor.s.sol/31337/run-latest.json 2>/dev/null)
if [ -n "${RI_TX:-}" ]; then receipt "reinvestor (2nd-pass, real state)" "$RI_TX"; fi

round() { # round <id> → echoes "token ctrl hook"; raw hex, 64-char words,
  # low-20-byte sliced (words are left-padded addresses)
  local hex w out=""
  hex=$(cast call "$FACTORY" "getRound(uint256)" "$1" --rpc-url "$RPC" | grep -v Warning | tr -d '\n')
  for w in $(echo "${hex:2}" | fold -w64 | awk 'NR>=2 && NR<=4'); do out+="0x${w: -40} "; done
  echo "$out"
}
read -r R1_TOKEN R1_CTRL R1_HOOK _ <<< "$(round 1)"
R1_STAKER=$(cast call "$R1_CTRL" "stakerAddress()(address)" --rpc-url "$RPC")
echo "  R1 token=$R1_TOKEN ctrl=$R1_CTRL hook=$R1_HOOK"

# ── 2. predeposit ×2 (zap wraps ETH → mixETH → predepositFor) ───────────────
send "predeposit alice (10 mix)" "$K_ALICE" "$ZAPIN" --value 10ether "zapInPredeposit(address,uint256)" "$R1_CTRL" 0
send "predeposit bob (10 mix)" "$K_BOB" "$ZAPIN" --value 10ether "zapInPredeposit(address,uint256)" "$R1_CTRL" 0

# ── 3. window over → permissionless launch ─────────────────────────────────
warp_to $(( $(TS) + PRE_SEC + 5 ))
send "launchPooledBuy (rando)" "$K_RANDO" "$R1_CTRL" "launchPooledBuy()"

# ── 4. round-1 buy (real curve flow; seeds the reserve the bomb drains) ────
read -r C0 C1 <<< "$(sort_pair "$MIX" "$R1_TOKEN")"
send "R1 buy 1 ETH via zapIn (rando)" "$K_RANDO" "$ZAPIN" --value 1ether \
  "zapInBuy((address,address,uint24,int24,address),uint256,uint256)" "($C0,$C1,8388608,60,$R1_HOOK)" 0 0

# ── 5. claims ───────────────────────────────────────────────────────────────
send "claim PSP alice" "$K_ALICE" "$R1_CTRL" "claimPredepositPSP()"
send "claim PSP bob" "$K_BOB" "$R1_CTRL" "claimPredepositPSP()"

# ── 6. THE CLOCK KILLS THE ROUND (governance died 2026-09-01) ───────────────
# detonationAt was armed at launch (72h window, mainnet-real). Buys extend
# it; nothing here does, so warp past it and let any rando detonate: one tx
# = pot frozen + flat + all locks open + mark + RESERVE + BIRTH of round 2.
DET_AT=$(cast call "$R1_HOOK" "detonationAt()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
warp_to $(( DET_AT + 2 ))

# detonate wraps spawnNextRound → the ~0.03% reserve-mine tail can bounce
# the whole tx CLEAN (atomic revert; clock stays at zero). Production
# semantics: retry next block with fresh entropy. Mirror them.
DET_TX=""
for attempt in 1 2 3 4 5; do
  DET_TX=$(cast send "$R1_CTRL" "detonate()" --rpc-url "$RPC" --private-key "$K_RANDO" --json 2>/tmp/psp-e2e-det-err.log | jq -r '.transactionHash')
  if [ -n "$DET_TX" ] && [ "$DET_TX" != "null" ]; then break; fi
  echo "  detonate attempt $attempt bounced (next block re-rolls entropy): $(tail -1 /tmp/psp-e2e-det-err.log | head -c 120)"
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
done
[ -n "$DET_TX" ] && [ "$DET_TX" != "null" ] || { echo "✗ detonate never landed"; cat /tmp/psp-e2e-det-err.log; exit 1; }
receipt "detonate→RESERVE+BIRTH (rando)" "$DET_TX"

# post-detonation invariants: flat mode, locks open, round 2 already born
MODE=$(cast call "$R1_HOOK" "mode()(uint8)" --rpc-url "$RPC")
echo "  R1 hook mode=$MODE (2 = Flat expected)"
FLAT_TS=$(cast call "$R1_CTRL" "flatTime()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
[ "$FLAT_TS" != "0" ] || { echo "✗ flatTime not set"; exit 1; }

# ── 8. verify round 2 landed on the reservation ─────────────────────────────
read -r R2_TOKEN R2_CTRL R2_HOOK _ <<< "$(round 2)"
# static struct → NO outer offset: [from, new, tSalt, cSalt, hSalt, token,
# ctrl, hook, contextHash, active] → token=word6, ctrl=7, hook=8
RES_HEX=$(cast call "$FACTORY" "reservation()" --rpc-url "$RPC" | grep -v Warning | tr -d '\n')
RES_TOKEN="0x$(echo "${RES_HEX:2}" | fold -w64 | awk 'NR==6{print substr($1,25)}')"
RES_CTRL="0x$(echo "${RES_HEX:2}" | fold -w64 | awk 'NR==7{print substr($1,25)}')"
RES_HOOK="0x$(echo "${RES_HEX:2}" | fold -w64 | awk 'NR==8{print substr($1,25)}')"
if [ "$R2_TOKEN" = "$RES_TOKEN" ] && [ "$R2_CTRL" = "$RES_CTRL" ] && [ "$R2_HOOK" = "$RES_HOOK" ]; then
  echo "✓ round 2 == reservation (token/ctrl/hook all match)"
else
  echo "✗ MISMATCH: R2 ($R2_TOKEN $R2_CTRL $R2_HOOK) vs reservation ($RES_TOKEN $RES_CTRL $RES_HOOK)"; exit 1
fi
MODE=$(cast call "$R2_HOOK" "mode()(uint8)" --rpc-url "$RPC")
echo "  R2 hook mode=$MODE (0 = Predeposit expected)"

# ── 9. round 2 is ALIVE: drive its lifecycle — predeposit → launch → buy ────
send "R2 predeposit alice (10 mix)" "$K_ALICE" "$ZAPIN" --value 10ether "zapInPredeposit(address,uint256)" "$R2_CTRL" 0
warp_to $(( $(TS) + PRE_SEC + 5 ))
send "R2 launchPooledBuy (rando)" "$K_RANDO" "$R2_CTRL" "launchPooledBuy()"
read -r C0 C1 <<< "$(sort_pair "$MIX" "$R2_TOKEN")"
send "R2 buy 1 ETH via zapIn (rando)" "$K_RANDO" "$ZAPIN" --value 1ether \
  "zapInBuy((address,address,uint24,int24,address),uint256,uint256)" "($C0,$C1,8388608,60,$R2_HOOK)" 0 0

echo
echo "═══ staged-spawn e2e complete — receipts also in $RECEIPTS ═══"
