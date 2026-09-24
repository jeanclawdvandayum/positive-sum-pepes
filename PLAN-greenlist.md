# PLAN — Two-phase greenlist IBCO (greenlist + open, split genesis buys)

Branch: new `greenlist-ibco` off `alt-ui-fun`. Contracts (solc 0.8.26, via_ir) + frontend + deploy tooling.
Old rounds are untouched: everything below is per-round state on NEW rounds only.

## Spec (user, 2026-09-25)

1. Total IBCO cap stays 1000 mixETH (already the contract constant).
2. Two phases: **green** (whitelist) then **open**.
3. Green phase: CSV of eligible addresses (provided later, per round), per-depositor cap
   `500 mixETH / N` (N = greenlist size), lasts 1 day.
4. Open phase: everyone, 10 mixETH per wallet, lasts 1 day, fills up to the 1000 total
   (unused green capacity rolls into open).
5. Genesis launch does TWO consecutive curve buys in ONE transaction:
   buy #1 = the green pool, buy #2 = the open pool. Atomic, so nobody canfrontrun between them.
6. Predeposit claims (genesis pepe) work exactly as now for both phases.
7. Detonation greenlists every CURRENT-round PSP holder into the NEXT round (current round only —
   round-1 holders are not in round 3's greenlist unless they played round 2).

## Design decisions (need user sign-off)

### D1 — Greenlist storage: Merkle root (recommended) vs on-chain address list
- **Merkle root (recommended):** the deploy tooling builds a Merkle tree from the CSV and the chain
  data, stores only `greenRoot` + `greenPerWallet = 500e18 / N` on the round. Deposits take a proof
  (`predepositGreen(amount, proof)`); the UI ships the tree file and proves membership in the browser.
  One storage slot no matter the list size; CSV arrives "later" without a gas problem.
- On-chain list: simple reads, but each address costs ~20k gas at birth and detonation unions get big.
- Both keep `predepositPepe` reserving working via the green entry point.

### D2 — Auto-greenlist of PSP holders (point 8): TRUSTLESS on-chain snapshot (user-approved)
- PSPToken maintains `holder(address) => bool` + `holderCount` in its transfer hook
  (set on first receipt, cleared on empty, count maintained). ~3k gas warm per transfer.
- `detonate()` FREEZES the round's holder map (`holdersFrozen = true`): balances keep
  moving after death, but the bools stop updating — the map becomes the
  "held PSP at detonation" snapshot, forever readable.
- Round N+1's green entry: `prevToken.holder(msg.sender)` (frozen snapshot) OR the CSV
  Merkle root. No operator step, no processing, no root needed for the auto part —
  spawns stay permissionless indefinitely (birth reads prevToken.holderCount + csvCount
  to compute greenPerWallet = 500e18 / N).
- The CSV root remains optional operator data per round (set before birth; absent = empty CSV).
- Cost: one extra bool/counter in PSPToken + a freeze flag; detonate unchanged otherwise.

### D3 — Window mechanics
- New per-round immutables `GREEN_DURATION` (default 1 day) and `OPEN_DURATION` (default 1 day),
  replacing `PREDEPOSIT_DURATION`; env-overridable for testnet lifecycles
  (`PSP_GREEN_SEC`, `PSP_OPEN_SEC`; profile keeps the current short testnet windows).
- `predepositState()` grows: `phase (0 green|1 open|2 over)`, `greenEnd`, `openEnd`,
  `greenPerWallet`, `openPerWallet`, `greenTotal`.
- Green deposit window = [start, start+GREEN); open = [start+GREEN, start+GREEN+OPEN).
  Launch: anyone once open ends OR the 1000 cap is hit (owner early-launch stays).
- Timing packing: today's 4×64-bit slot is exactly full. Green/open windows become plain immutables
  set from the factory's spawn args (packing stays for vest/det/wallet fields). The hand-rolled
  packing ban (AGENTS) still applies — only CurveMath helpers touch the packed slot.

### D4 — Caps and rounding
- `greenPerWallet = max(500e18 / N, minimum)` in whole mixETH-wei, floor 0.005 mixETH
  (so a 1-address greenlist can't brick the phase; N=1 → 500 cap).
  N = csvCount + prevToken.holderCount (a CSV address who also held PSP counts twice —
  noted, accepted).
- Open per-wallet: 10 mixETH immutable. Both phases share the 1000 total cap; the green phase
  implicitly holds ≤ 500 (N × 500/N); whatever it doesn't take is open-phase headroom.
- The existing per-wallet cap slot (PSP_WALLET_CAP_MIX) retires in favor of these two caps.

### D5 — Split genesis buys (point 6)
- `launchPooledBuy()` burns the single pooled buy into: genesis buy #1 with `greenPool`
  (90% seeds curve, 10% → pot), then immediately buy #2 with `openPool`, same tx, same pricing path,
  slippage-safe by construction. PSP allocation: green tranche shares to green depositors,
  open tranche shares to open depositors (per-tranche pro-rata, tracked per depositor).
- Frontrun-safety: both buys are inside the launch tx (atomic) — no bundling needed.

## Build order (opus implements the core; glm 5.3 gets the mechanical slices)

1. **RoundController green/open phases** (opus): state, entry points (`predepositGreen(amount,proof,pepeId?)`,
   `predepositOpen`), caps, phase views, launch split, per-tranche claim accounting; PEDEPOSIT_RULES_VERSION 3.
2. **Factory + spawn wiring** (opus): green root + greenPerWallet + durations as spawn args;
   deploy scripts + env; manifest/verifier updates; AUD-3-style birth checks.
3. **Greenlist tooling** (glm 5.3, mechanical): CSV → Merkle tree builder, tree JSON for the UI,
   holders-at-detonation extractor (Transfer events), union script; reproducible root.
4. **Tests** (glm 5.3 for the mechanical grid; opus for the adversarial ones): phase boundaries,
   cap math incl. rounding, proof forgery, both tranches' claims, launch ordering, rebirth greenlist,
   old-round regression (release tests), EIP-170 sizes.
5. **Frontend IBCO page** (glm 5.3, mechanical): phase-aware clock (green vs open countdown via the
   new urgency lanes), greenlist proof flow (reads tree file, wallet membership check), caps/headroom
   display, per-phase deposit CTAs; copy stays in the site voice.
6. **Gates + deploy rehearsal** (opus): check-audit, anvil e2e two-round lifecycle with green→open→
   launch→detonate→auto-green rebirth, then a live Base Sepolia deploy when the user says go.

## Non-goals
- No changes to the curve math, ticket/ladder rules, fee split, or redemption.
- No retro-fitting of deployed rounds.
- No on-chain secret lists (the CSV is public data in a tree).
