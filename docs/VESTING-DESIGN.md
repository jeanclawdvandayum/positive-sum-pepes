# PSP Vesting Redesign — indefinite locks, InfiniFi-style epoch decay, per-pepe cards

Spec (scoopy, 2026-08-28): indefinite locks; `requestWithdraw` starts a 6-week
linear decay of dividend + voting power (1000 PSP → 5/6 at wk1, 1/2 at wk3, 0
at wk6, then withdrawable). Stake page: one card per staked pepe NFT (art,
amount, $value, unlock date, cancel-request / withdraw buttons, per-card claim +
reinvest), header totals + multiclaim + reinvest-all.

**2026-08-28 update — fee engine replaced AGAIN (live accumulator).** Testing
the first real Sepolia deploy, scoopy flagged the epoch-gated claim window as
a must-fix UX regression ("fees should be assigned and claimable as they come
in, and not be epoch based"). Fee crediting and settlement now run on a live
`creditPerWeight` accumulator (see the Fees section below); the epoch-point
machinery remains for WEIGHTS ONLY (decay, votes, quorum). The per-epoch fee
buckets, the `_allocated` replay walk, and the `{settledEpoch, settledW,
settledSlope}` self-anchor are retired.

**2026-08-29 update — fee engine replaced.** The dual-leg design below is
RETIRED. It shipped with two exactness bugs under staggered decayers (see git
history). The engine is now the InfiniFi epoch-point design
(`InfiniFi-Labs/infinifi-protocol`, `src/locking/UnwindingModule.sol`) — the
mechanism their locked iUSD uses to decay boosted yield down to the unlocked
rate while unwinding. PSP-specific mapping below; the old dual-leg section is
kept at the bottom for the record.

## The epoch-point engine (current, after InfiniFi)

One mechanism for everyone — no Synthetix accumulator, no day buckets, no
rewardDebt.

### Epochs
- `epochSize = VEST_DURATION / 6` (mainnet 42d → 7d; testnet 2d → 8h).
  `epoch(ts) = ts / epochSize`. `packTimings` guards `vest % 6 == 0`. The
  genesis point anchor is lazy: it materializes at the first write-side use
  (a position-creating call), so no delta can predate it and the walk never
  starts from epoch 0 (small epochs would otherwise make that ~100k+
  iterations).
- **Weight only changes at epoch boundaries.** Every weight mutation (stake,
  top-up, request, cancel, flat-withdraw) registers a per-epoch delta that goes
  live at the NEXT boundary. Within an epoch, weights are constant — that is
  the exactness invariant the dual-leg design lacked.

### Global point
`GlobalPoint {epoch, weight, slope, fees}` stored per epoch, lazily
extrapolated (`_advance`) from the last stored point via four delta maps:
`biasAdd/biasSub/slopeAdd/slopeSub[epoch]` (applied advancing e→e+1). Stored
points are authoritative — walkers prefer them so direct corrections
(mid-decay cancel) propagate (InfiniFi's Certora-tested pattern).

### Decay (the veCRV bias/slope pattern)
`requestWithdraw` at epoch E: `base = amount − amount%6`, `slope = base/6`.
- weight = full `amount` through E; `base − k·slope` during E+k (k=1..5); 0
  from E+6. Dust (amount%6) is removed up-front via `biasSub[E]` so the decay
  lands on exactly zero (InfiniFi's rounding).
- Global: `slopeAdd[E] += slope` (decay starts at the boundary after the
  request), `slopeSub[E+6] += slope` (slope retires when the position zeroes).
- Spec checkpoints hold EXACTLY at any request phase: +1wk crosses exactly one
  boundary → 5/6; +3wk → 1/2; +6wk → 0.
- `withdraw` unlocks at `epoch ≥ E+6` (`withdrawableAt = (E+6)·epochSize`).
  Slope retirement is lazy — no correction needed on withdraw.

### Fees (LIVE accumulator — 2026-08-28, scoopy's must-fix)
`addFees` advances a single monotonic accumulator the INSTANT fees arrive:

```
creditPerWeight += fees · 1e30 / totalWeight    (CREDIT_PRECISION = 1e30)
```

Zero-weight rounds orphan in `pendingFeesMixETH` until weight exists, and the
buffer uses a rolling remainder (`pending -= distributed`, not `pending = 0`)
so sub-precision dust accumulates until it crosses one credit unit — the
wave2 A-F3 stranding bug stays dead. `FeesCredited(amount, creditAfter)` is
emitted on every credit for UI/indexing.

**Why exactness survives for static positions:** weights only change at epoch
boundaries, so `totalWeight` is frozen within an epoch — the accumulator
split `w · Δcredit / W` is arithmetically identical to the retired per-epoch
bucket replay. Immediacy costs nothing here.

**Why immediacy is safe:** a fresh stake has `weightAt = 0` until the next
epoch, so no same-tx stake→harvest→exit sandwich exists — the anti-manip
property was always the next-epoch weight gate, never the claim delay.

### Settlement (claims — O(1))
Every position carries `creditCheckpoint` — the accumulator value at its last
settle. Claimable is a live product:

```
due = weightAt(pepeId, now) · (creditPerWeight − checkpoint) / 1e30
```

No epoch walk, no self-anchor, no boundary wait — `pendingFeesOf` and
`claimFees` agree at every instant. The one accepted approximation (scoopy,
2026-08-28: "im ok with some loss of precision from the decaying staked PSP
positions"): a DECAYING position that skips claims while its vest steps down
settles fees earned at earlier, higher weights at its current, lower weight —
under-credits only, never over-credits (solvency holds: Σ claims ≤ Σ fees).
A position that reaches zero weight with unclaimed credit forfeits it —
claim before your vest runs out (the UI surfaces this).

### Mutations (uniform rule: upward changes land next boundary)
- `_stake` fresh: `startEpoch = e`, `biasAdd[e] += amount` — live from e+1. A
  fresh stake does not retroactively claim this epoch's already-deposited fees
  (mid-epoch fairness — why InfiniFi registers bias at the current epoch).
- top-up: settle + pay first, `biasAdd[e] += add`, `startEpoch = e` re-anchor
  (the top-up epoch itself is forfeit — ≤1 epoch under-accrual, uniform).
- `requestWithdraw`: settle+pay, arm the slope (weight unchanged at E).
- `cancelWithdraw` at f: settle+pay. If f == E: unwind the pending deltas
  (slopeAdd/slopeSub/biasSub). If f > E: checkpoint + correct the live point
  (`p.slope -= slope`), `biasAdd[f] += (f−E)·slope + dust` (full power from
  f+1; the cancel epoch itself is forfeit), `slopeSub[E+6] -= slope`.
  Position re-anchors at full amount (`startEpoch = f`, requestEpoch = 0).
- `withdraw` (decayed): weight is already 0 — no corrections. Flat-path
  (carpet bomb): `biasSub[e] += amount` for tidy bookkeeping.
- Genesis (`positions[0]`): lockGenesis registers like a stake; share claims
  settle genesis, pay the share's pro-rata fees (`alloc · share / amount`),
  `biasSub[e] += share` out + fresh pepe `biasAdd[e] += share` in.

### Views
- `weightAt(pepeId, e)` / `biasOf(pepeId, ts)`: the stepped schedule.
- `totalWeight()`: extrapolated global point (controller quorum).
- `pendingFeesOf`: live O(1) accumulator read — agrees with claim at every instant.
- `withdrawableAt`: `(requestEpoch+6)·epochSize` or uint.max.
- `voteWeight(user, at)`: Σ live position power at `at` — governance-only
  (a fresh lock carries FULL power in its creation epoch; the fee engine
  epoch-gates, governance does not). Decay mirrors the fee engine from the
  request epoch onward. scoopy 2026-08-27: votes are evaluated live at the
  vote (post-propose stakes count), quorum denominates against staked
  weight only (supply floor retired — it froze governance when staked was
  a minority of supply).

### Deviations from InfiniFi (all favor simplicity; documented)
- PSP is single-system: weight never hops contracts (their locked→unwinding
  move creates a 1-epoch earning gap; ours keeps full weight through the
  request epoch — ≤1 epoch of full weight post-request instead).
- Epoch length derives from the vest window (theirs is a fixed week with a
  3-day offset) — keeps testnet decay visible and mainnet on exact week steps.
- No slashIndex / share-price legs (PSP fees are mixETH, not the stake token —
  replay-claim is the natural fit).

## RoundController — timing + vote surface
- Timings pack: PREDEPOSIT, VEST_DURATION, VOTE_DURATION (+flat exit const).
  LOCK/EXTEND/RELOCK slots retired (findings-46 zero-guards preserved).
- vote(): weight = Σ bias(id, proposeTime), per-id actionTime < proposeTime.
- Quorum denominator: max(totalWeight(proposeTime), hook.totalSupplyPSP()).
- flatTime bypass on withdraw stays (carpet bomb = all locks open).

## PSPReinvestor (script-deployed like zaps — zero factory size)
`reinvest(pepeId, key, minOut, deadline)`:
claimFeesTo(pepeId, reinvestor) → mix.forceApprove(zapIn) →
zapIn.buyWithMix(key, mix, minOut, deadline) → PSP → stakeFor(owner, pepeId).
`reinvestAll(ids[], …)` loops. No custody beyond in-flight, no admin.

## Frontend (stake page)
- PepeCards: one card per owned pepe id — art via renderPepeSvg(dnaOf(id));
  rows: amount staked, $value (amount × curvePrice × mix→USD), unlock date
  ((requestEpoch+6)·epochSize — read via positions()[2] and VEST_DURATION/6),
  stepped power % (client mirror of the contract schedule), buttons:
  cancel-request / withdraw (greyed per state machine), claim
  [claim – X mixETH], reinvest.
- Header: total PSP staked (Σ), total $ value, multiclaim (claimAllTo),
  reinvest-all.
- app.html (on-chain fallback app): user panel now reads staker() →
  stakedTotalOf(acct) (the old locks(address) read died with the multi-NFT
  rewrite).

## Test plan (test/unit/Vesting.t.sol — epoch-exact)
- Decay pins at boundary-anchored requests: full through request epoch, 5/6
  +1wk, 1/2 +3wk, 0 +6wk; aggregate exact.
- **Staggered decayers exact** (the retired dual-leg's known-issue #1): two
  requests one epoch apart; per-position and totalWeight pinned floor-for-floor.
- Exact fee splits incl. a mid-decay epoch (decayer 5/6 vs stayer full),
  never over-distributes (retired known-issue #2).
- Withdraw gating (first unlock instant = (E+6)·epochSize), husk + re-stake,
  cancel same-epoch / mid-decay (forfeit epoch documented), stakeFor gating,
  multiclaim, vote snapshot semantics, dust rounding (amount%6 → exact zero),
  sparse replay across quiet gap epochs, genesis share fee split.

## Retired: dual-leg fee math (2026-08-28 — do not resurrect)
Classic Synthetix accumulator for non-decayers + day-bucket legs for decayers,
with an O(1) aggregate decaying-bias snapshot. Two exactness failures shipped:
staggered second requester's aggregate decayed at double rate, and decayer
bucket legs read a 28d-equivalent bias instead of 21d. Root cause class:
continuous-weight accumulator + sub-day bucket approximations interacting.
Superseded wholesale by the epoch-point engine above. Lesson: when weights
decay, use epoch/point-slope replay (veCRV / InfiniFi) — not hybrid
accumulators.
