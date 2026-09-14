# deployment-spec — base switch & change log

**Date:** 2026-09-14
**Decision:** `deployment-spec` is now the **working base** for all PSP deployment
work. It supersedes the `sigma-testnet` / `sepolia-fixes` lineage as the tip of
development. `testnet-final` remains untouched as the frozen record of the live
Sept-7 Base Sepolia rounds (its bytecode is proven identical to the deployed
rounds — see the local audit `audits/2026-09-08-testnet-final.md`).

This file logs everything pushed in the base switch (3 commits + this log).

---

## 1. `b4cfbc33` — deployment-spec full agentic audit

Four fresh-eyes lanes (economics / fees / lifecycle / NFT) plus orchestrator,
run under evm-cortex discipline. Full report: `audits/2026-09-13-deployment-spec/`.

- **No Critical, no High.** 2 Mediums, both deploy-gated (see §2), 5 Lows.
- Dynamic fee / ticket / clock / economic core **proven sound**: bit-exact
  oracle (60/60 vs compiled SineMath), ~50k adversarial curve points,
  round-trip costs −4.95%…−19% as designed.
- **Fix landed in-commit:** the branch as previously pushed did not compile —
  `SineCustodyInvariants.t.sol` still referenced v1 sine field names. Migrated
  to sine v2 fields (test-only change). Post-migration: 583 pass / 1 env-fail /
  3 skip, deep fuzz P1/P2 @2000 runs green, slither 0H/0M, no-gov gate clean.

## 2. `09a3f79b` — audit resolution: L-M1 fixed, N-1 closed procedurally

- **L-M1 (Medium) fixed in code:** `RoundController` constructor now rejects
  sub-epochal vest durations (`VEST_DURATION < 6`) at the timing-word decode
  site (`TimingsIncomplete`, subsuming the old zero-check). Guards every
  deployment path including direct vessel births.
  Regression: `test_C3_RejectsSubEpochalVest` — hand-assembled words with vest
  1–5s each revert at decode, vest = 6 boundary deploys. C3 suite 9/9.
- **N-1 accepted procedurally:** one eternal factory; the Sept-9 descriptor is
  never touched, future art ships as a new version alongside; frontend
  soft-locks folded DNA KEYS across rounds (chosen-ID art is round-independent
  `keccak(id)`; alias ids exist, so key-lock not id-lock).

## 3. `1a2ee1dd` — graveyard one-click exit + badge reliability

The post-detonation flow (claim mixETH → unlock PSP → redeem) is now one
transaction, and the graveyard badge pipeline no longer depends on pruned
archive state.

### Contracts

- **`src/PSPGraveZap.sol` (new)** — `exit(hook, staker, pepeIds, pspIn,
  minMixOut, deadline)`: `hook.claimPotFor(user)` (pot → user, direct),
  `staker.claimAllTo` (fees → user, zero-guarded), `staker.withdrawFor` per
  pepe (unlock PSP → owner), then fee-free `hook.redeemBacking` pro-rata
  redemption with proceeds forwarded. Holds no funds at any point; unstaked
  ids fail loud; minOut reverts leave zero partial state.
- **`CurveHook`** — added `claimPotFor(address)`: anyone may call, payout
  always goes to the seat owner (third parties can only *credit* an owner —
  no theft surface). `claimPot`/`claimDeployerCredit` deduped through
  `_payMix`. **Net smaller than before the change: 23,918B (was 24,019B)**;
  the 500B EIP-170 headroom gate stays green.
- **`PSPStaker`** — added `withdrawFor(pepeId)`: operator-callable unlock
  whose principal **and** fees always pay the token *owner* (operators
  already hold strictly more power via NFT transfer — no new theft surface).

### Tests

- **`test/wave2/auditorB/B6_GraveZap.t.sol` — 7/7, real behavior only**
  (no `vm.mockCall` on token-moving paths): real launch → buys via
  `zapIn.buyWithMix` → locks → detonation → zap exit. Covers minOut
  atomicity, stranger rejection, owner-only payouts, zero-fee leg skip,
  deadline.
- Harness gotcha documented: the B-rig router attributes ladder seats to its
  internal swapper — the hook seats the **hookData trader**, so tests that
  need a user to own seats must buy via `zapIn.buyWithMix`.

### Frontend

- **Badge reliability fix:** settlement-owner resolution is now derived from
  **Transfer logs** (50k-block windows, per-hook winners cache) instead of
  `ownerOf` at the settlement block. Reason: both public Base Sepolia RPCs
  prune historical state within days — all three dead rounds were already
  unreadable via archive reads. (`ownerOf`-at-block was silently failing or
  degrading for every dead round.)
- **One-click exit UI:** `DeadRoundCard` gained *"exit round — one
  transaction"* with the exact line *"claim X mixETH · unlock Y PSP ·
  convert P PSP → Z mixETH"* (parts omit when zero). Approvals bundle via
  `writeWithApprovals` (atomic-batch wallets = one signature). Hidden until
  `VITE_GRAVE_ZAP` is set. `vite`/`tsc` build clean.

---

## Gate state at tip

- `forge test`: **591 passed / 1 known env-fail (`WNS_FORK_RPC_URL`) / 3 skip**
  (583 baseline + L-M1 regression + 7 zap tests).
- CurveHook **23,918B** (658B EIP-170 headroom); RoundController 12.8kB/24.6kB.
- slither 0H/0M; no-governance grep clean; `vite`/`tsc` clean.

## Caveats & non-changes

- **Live-testnet caveat:** `claimPotFor`/`withdrawFor` exist only in new
  bytecode — the deployed Sept-7-factory rounds keep the granular three-step
  flow. The zap activates with the **eternal factory deploy** + `VITE_GRAVE_ZAP`.
- **No on-chain deployments were made** and none were modified.
- The hosted site was **not** republished — it still serves a stale
  pre-badge bundle (`devoted-truffle-ydjx.here.now`, pushed 09-05, missing a
  week of fixes incl. badges and the exit button). Republish pending decision.
- `audits/2026-09-08-testnet-final.md` (frozen testnet-final audit) remains
  local-only on purpose until explicitly cleared for the remote.
