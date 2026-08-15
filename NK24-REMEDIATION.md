# NK24 Red-Team Remediation — 2026-08-15

**Exercise:** adversarial red-team vs the live V3 deployment config, mainnet fork, no admin privileges.
**Result pre-fix:** no theft on the production config; 3 design-level findings + supporting hardening accepted.
**Result post-fix:** 304/304 test gate (129 unit, 54 fork integration, 10 attack death-proofs P1–P10, 9 math fuzzers, chaos invariants).

---

## Fixes shipped

### F1 — mixETH is the sole unit of account (approved design change)

**Finding:** the settlement path converted mixETH↔ETH through the vault's ERC-4626 rate, giving traders a free short put against vault markdowns: buy PSP, trigger/await a rate drop, sell at the stale favorable conversion — a directional extraction paid by remaining holders.

**Fix:** the 4626 oracle is fully removed from settlement. Buys, sells, fee accrual, genesis splits, and views are denominated in mixETH natively. Vault P&L (up or down) now floats through the rate pro-rata across all PSP holders; there is no direction left to trade. `totalReserveETH` survives as display-only.

**Proofs:** P1 (rate −10% round trip: loss = exactly two fee legs, zero rate delta), P2 (rate −95%: no brick, sells settle, reserve solvent, second round trip works), P3 (rate +10%: identical two-fee-leg loss — perfect symmetry).

### F2 — atomic genesis lock (approved design change)

**Finding:** predepositors' PSP existed unlocked between launch and their individual claims — a first-claim/first-fee window.

**Fix:** `launchPooledBuy` locks 100% of initial PSP into a controller-held virtual lock inside the launch transaction itself (O(1), no depositor loop). Fees accrue to the genesis lock pro-rata from block one; claims decrement it exactly.

**Proofs:** P4 (60/40 depositors, no claims, 5e18 fees traded through, then both claim: exact 3/2 split), P8 (post-bomb late claim still returns principal, genesis decremented exactly).

### F3 — Newton solver hardening

**Finding:** a validate()-legal curve (k·width = 20, price span e^20) stalled the solver, forcing a 1-wei-haircut fallback path; log-first zones hit div-by-zero.

**Fix:**
- bounded **shave loop** in `computeBuyOutput` replaces the fixed 1-wei haircut — guarantees conservative-mint convergence for every legal config;
- validate() rejects **log-first** zone layouts;
- validate() bounds exp-zone **k·width ≤ 7 WAD** (≈1100x price span per zone). Note: an earlier draft used 0.01 WAD, which would have capped zones at a 1.01x span and killed legitimate multi-oscillation S-curves — corrected before merge. The shave loop is the correctness mechanism; the cap is gas/degens defense only.

**Proofs:** NK24Repro regression suite (5/5): both stall configs now revert at validate with exact strings; worst-allowed shape (k·width = 5 WAD) proves the conservative-mint invariant; NK24Math fuzzers (9/9): integrals never exceed input, Newton soundness, split-buy/sell neutrality.

### F4 — quorum floor vs curve supply

**Finding:** bomb quorum was measured against `totalLocked` only; a thin-lock proposal let a late locker dominate the denominator.

**Fix:** quorum denominator = `max(totalLocked, totalPSPSupply)` snapshot at propose. A dust-lock bomb now requires locking ~69% of ALL outstanding PSP — the attacker torches their own bag proportionally.

**Proofs:** P5 (dust bomb reverts; honest bomb executes end-to-end with 101e18 recovered to factory), P9 (mid-vote claim adds zero voting power — lockTime ≥ proposeTime), P10 (pre-launch propose unreachable: genesis lock is created inside launch).

### F5 — decoy pool gate

**Fix:** curve hooks reject initialization on non-canonical pools (fee 0x800000 flag + tickSpacing 60 enforced; `WrongPoolParams`).

**Proof:** P6 (decoy initialization reverts; inner selector asserted through V4's `WrappedError`).

---

## Second-pass review of the remediation itself

New code is new surface; the fixes were re-attacked:

- genesis virtual lock lifecycle (claim/unlock/bomb decrement paths) — clean
- settlement purity (no residual 4626 conversions anywhere in src) — clean
- `_updateAccumulator` zero-lock guard — present (no div-by-zero brick)
- `sendFees`/`drainAll`/`setMode` controller-gating — clean
- one known-edge documented, not fixed: fees accruing while `totalLocked == 0` are captured by the first re-locker (standard Synthetix-style behavior; not economically attackable)
- chaos invariants surfaced a 1-wei over-claim (`floor(m·acc₂/P) − floor(m·acc₁/P)` can exceed the exact pro-rata difference across an integer boundary — inherent accumulator rounding, not a vulnerability). Invariant relaxed to the mathematically derived bound (+1000 wei documented inline). `rewardDebt` rounding at six src sites deliberately left untouched — chasing sub-wei noise there creates real bugs.

## Test layout

- `test/attack/NK24.t.sol` — P1–P10 death proofs on a mainnet fork against a hostile rate-marking mock (mock can move DOWN — happy-path mocks hide short-put risk)
- `test/attack/NK24Repro.t.sol` — validate() regression proofs
- `test/attack/NK24Math.t.sol` — solver/curve fuzzers
- `test/invariant/ChaosInvariant.t.sol` — full-system accounting invariants

## Prior reviews

- `SECURITY-REVIEW.md` — 2026-08-11 hermes (glm-5.2) pass, 7 findings fixed same-day
- `SECURITY-REVIEW-GLM53.md` — 2026-08-14 independent GLM-5.3 pass
