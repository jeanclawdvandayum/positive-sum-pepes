#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# anvil-e2e.sh — staged-spawn end-to-end with REAL receipts (2026-08-30)
#
# Drives the full production lifecycle against a local anvil node, one
# broadcast per action, so every staged leg gets a real tx + gas receipt:
#
#   genesis deployRound (composed reserve+birth)
#   → predeposit ×2 → launch → round-1 buy → claims
#   → propose → vote ×2 → carpetBomb → finalizeCarpet  [RESERVE receipt]
#   → birthRound (permissionless rando)                [BIRTH receipt]
#   → verify round 2 landed on the reserved addresses
#   → round-2 buy via PSPZapIn                         [round-2 ALIVE]
#
# Timings: fast playtest profile — 2m predeposit, 6×60s vest epochs, 60s
# vote window, 60s flat exit, 10-mix wallet cap.
# Usage: bash scripts/anvil-e2e.sh   (expects anvil on 8545; starts one if absent)
# Env:   PSP_CURVE (default 0 = full 34-zone staircase, the round-2 shape)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${RPC:-http://127.0.0.1:8545}"
CURVE="${PSP_CURVE:-0}"
PRE_SEC=120
VEST_SEC=360                   # ÷6 = 60s epochs
VOTE_SEC=60
FLAT_SEC=60

# anvil deterministic accounts (public throwaway keys, local node only)
K_OWNER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
K_ALICE=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
K_BOB=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348ec8d3cbd9c9df
K_RANDO=0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

# ── node ────────────────────────────────────────────────────────────────────
if ! cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "▪ starting anvil"
  anvil --port 8545 >/tmp/psp-anvil.log 2>&1 &
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
  local gas
  gas=$(cast receipt "$2" --rpc-url "$RPC" --json | jq -r '.gasUsed')
  printf '%-36s %s  gas=%d\n' "$1" "$2" "$((gas))" | tee -a "$RECEIPTS"
}
send() { # send <label> <key> <to> [--value eth] <sig> [args...]
  local label=$1 key=$2 to=$3; shift 3
  local extra=() tx
  if [ "${1:-}" = "--value" ]; then extra=(--value "$2"); shift 2; fi
  tx=$(cast send "$to" "$@" "${extra[@]}" --rpc-url "$RPC" --private-key "$key" --json | jq -r '.transactionHash')
  receipt "$label" "$tx"
}
sort_pair() { # sort_pair <a> <b> → echoes "low high"
  if [ $(( $1 )) -le $(( $2 )) ]; then echo "$1 $2"; else echo "$2 $1"; fi
}

# ── 1. genesis (composed reserve+birth inside deployRound) ──────────────────
echo "▪ DeployPSP (PSP_ANVIL=1 PSP_CURVE=$CURVE)"
DEPLOY_LOG=/tmp/psp-e2e-deploy.log
PSP_ANVIL=1 PSP_CURVE="$CURVE" \
PSP_PREDEPOSIT_SEC=$PRE_SEC PSP_VEST_SEC=$VEST_SEC PSP_VOTE_SEC=$VOTE_SEC \
PSP_FLAT_EXIT_SEC=$FLAT_SEC PSP_WALLET_CAP_MIX=10 \
  forge script DeployPSP --rpc-url "$RPC" --broadcast --private-key "$K_OWNER" 2>&1 | tee "$DEPLOY_LOG" >/dev/null
FACTORY=$(grep -o 'factory: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | tail -1 | awk '{print $2}')
MIX=$(grep -o 'ANVIL mock mixETH: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | tail -1 | awk '{print $3}')
ZAPIN=$(grep -o 'zapIn: 0x[0-9a-fA-F]*' "$DEPLOY_LOG" | tail -1 | awk '{print $2}')
echo "  factory=$FACTORY mix=$MIX zapIn=$ZAPIN"

# genesis receipt: the FIRST call to the factory in broadcast order is
# deployRound (setDescriptor/setHtml come after it in the script)
RD_TX=$(jq -r --arg f "$(echo "$FACTORY" | tr '[:upper:]' '[:lower:]')" \
  '.transactions | map(select((.to // "") | ascii_downcase == $f)) | .[0].hash' \
  broadcast/DeployPSP.s.sol/31337/run-latest.json)
[ -n "$RD_TX" ] && [ "$RD_TX" != "null" ] && receipt "genesis deployRound (R1)" "$RD_TX"

round() { cast call "$FACTORY" "getRound(uint256)(address,address,address,bool)" "$1" --rpc-url "$RPC"; }
R1_TOKEN=$(round 1 | awk 'NR==1{print $1}' | tr -d '"')
R1_CTRL=$(round 1 | awk 'NR==2{print $1}' | tr -d '"')
R1_HOOK=$(round 1 | awk 'NR==3{print $1}' | tr -d '"')
R1_STAKER=$(cast call "$R1_CTRL" "stakerAddress()(address)" --rpc-url "$RPC")
echo "  R1 token=$R1_TOKEN ctrl=$R1_CTRL hook=$R1_HOOK"

# ── 2. predeposit ×2 (zap wraps ETH → mixETH → predepositFor) ───────────────
send "predeposit alice (10 mix)" "$K_ALICE" "$ZAPIN" --value 10 "zapInPredeposit(address,uint256)" "$R1_CTRL" 0
send "predeposit bob (10 mix)" "$K_BOB" "$ZAPIN" --value 10 "zapInPredeposit(address,uint256)" "$R1_CTRL" 0

# ── 3. window over → permissionless launch ─────────────────────────────────
warp_to $(( $(TS) + PRE_SEC + 5 ))
send "launchPooledBuy (rando)" "$K_RANDO" "$R1_CTRL" "launchPooledBuy()"

# ── 4. round-1 buy (real curve flow; seeds the reserve the bomb drains) ────
read -r C0 C1 <<< "$(sort_pair "$MIX" "$R1_TOKEN")"
send "R1 buy 1 ETH via zapIn (rando)" "$K_RANDO" "$ZAPIN" --value 1 \
  "zapInBuy((address,address,uint24,int24,address),uint256,uint256)" "($C0,$C1,8388608,60,$R1_HOOK)" 0 0

# ── 5. claims ───────────────────────────────────────────────────────────────
send "claim PSP alice" "$K_ALICE" "$R1_CTRL" "claimPredepositPSP()"
send "claim PSP bob" "$K_BOB" "$R1_CTRL" "claimPredepositPSP()"

# ── 6. epoch boundary → governance kill ────────────────────────────────────
EPOCH=$((VEST_SEC / 6))
warp_to $(( (( $(TS) / EPOCH) + 1) * EPOCH + 2 ))
send "proposeCarpetBomb (alice)" "$K_ALICE" "$R1_CTRL" "proposeCarpetBomb()"
PROPOSE_TS=$(cast call "$R1_CTRL" "currentProposal()(uint256,uint256,uint256,uint256,uint256)" --rpc-url "$RPC" | awk 'NR==2{print $1}')

ids_of() { # ids_of <wallet> → "[id,id,...]"
  local n id i out=""
  n=$(( $(cast call "$R1_STAKER" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC") ))
  for ((i = 0; i < n; i++)); do
    id=$(( $(cast call "$R1_STAKER" "tokenOfOwnerByIndex(address,uint256)(uint256)" "$1" "$i" --rpc-url "$RPC") ))
    out+="${id},"
  done
  echo "[${out%,}]"
}
send "vote YES alice (all pepes)" "$K_ALICE" "$R1_CTRL" "voteCarpetBomb(uint256[],bool)" "$(ids_of "$ALICE")" true
send "vote YES bob (all pepes)" "$K_BOB" "$R1_CTRL" "voteCarpetBomb(uint256[],bool)" "$(ids_of "$BOB")" true

warp_to $(( PROPOSE_TS + VOTE_SEC + 2 ))
send "carpetBomb (alice)" "$K_ALICE" "$R1_CTRL" "carpetBomb()"

# ── 7. flat window → THE STAGED LEGS ────────────────────────────────────────
FLAT_TS=$(cast call "$R1_CTRL" "flatTime()(uint256)" --rpc-url "$RPC")
warp_to $(( FLAT_TS + FLAT_SEC + 2 ))
send "finalizeCarpet→RESERVE (rando)" "$K_RANDO" "$R1_CTRL" "finalizeCarpet()"
send "birthRound (rando)" "$K_RANDO" "$FACTORY" "birthRound()"

# ── 8. verify round 2 landed on the reservation ─────────────────────────────
R2_TOKEN=$(round 2 | awk 'NR==1{print $1}' | tr -d '"')
R2_CTRL=$(round 2 | awk 'NR==2{print $1}' | tr -d '"')
R2_HOOK=$(round 2 | awk 'NR==3{print $1}' | tr -d '"')
RES=$(cast call "$FACTORY" "reservation()(uint128,uint128,bytes32,bytes32,bytes32,address,address,address,bytes32,bool)" --rpc-url "$RPC")
RES_TOKEN=$(echo "$RES" | awk 'NR==6{print $1}' | tr -d '"')
RES_CTRL=$(echo "$RES" | awk 'NR==7{print $1}' | tr -d '"')
RES_HOOK=$(echo "$RES" | awk 'NR==8{print $1}' | tr -d '"')
if [ "$R2_TOKEN" = "$RES_TOKEN" ] && [ "$R2_CTRL" = "$RES_CTRL" ] && [ "$R2_HOOK" = "$RES_HOOK" ]; then
  echo "✓ round 2 == reservation (token/ctrl/hook all match)"
else
  echo "✗ MISMATCH: R2 ($R2_TOKEN $R2_CTRL $R2_HOOK) vs reservation ($RES_TOKEN $RES_CTRL $RES_HOOK)"; exit 1
fi
MODE=$(cast call "$R2_HOOK" "mode()(uint8)" --rpc-url "$RPC")
echo "  R2 hook mode=$MODE (0 = Predeposit expected)"

# ── 9. round-2 is ALIVE: buy on the newborn curve ───────────────────────────
read -r C0 C1 <<< "$(sort_pair "$MIX" "$R2_TOKEN")"
send "R2 buy 1 ETH via zapIn (rando)" "$K_RANDO" "$ZAPIN" --value 1 \
  "zapInBuy((address,address,uint24,int24,address),uint256,uint256)" "($C0,$C1,8388608,60,$R2_HOOK)" 0 0

echo
echo "═══ staged-spawn e2e complete — receipts also in $RECEIPTS ═══"
