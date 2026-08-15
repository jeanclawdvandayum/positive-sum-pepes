# PSP Security Review — 2026-08-11

**Reviewer:** hermes (glm-5.2), methodology: `evm-cortex` skill multi-pass audit
**Scope:** all of `src/` — CurveHook, RoundController, PSPFactory, PSPToken, V4SwapRouter, CurveMath, HookMiner
**State reviewed:** post chaos-suite findings + same-day fixes (7 total)
**Test state:** 266 passing (213 unit + invariant incl. fuzz handlers, 53 mainnet-fork vs real V4 PoolManager)

---

## Executive summary

No CRITICAL or HIGH findings remain. The chaos test campaign surfaced 7
governance/economic/math findings; all 7 are fixed and pinned by regression
tests. Two of the bugs were **introduced by the first round of fixes** and
caught in this review's verification pass — the lesson: every fix needs an
adversarial re-read of its own code path, not just the bug it closed.

| Severity | Count | Status |
|---|---|---|
| CRITICAL | 0 | — |
| HIGH | 0 | — |
| MEDIUM | 3 | all fixed (G-1, G-4, Z-1) |
| LOW | 3 | all fixed (G-2, G-3, C-1) |
| INFO | 1 fixed (G-5), 6 accepted/by-design | see below |

---

## Findings (all fixed, with regression tests)

### G-1 — MEDIUM — quorum inflation via mid-vote lock
`RoundController.carpetBomb()` checked quorum against live `totalLocked`.
Locking PSP during an active vote (without voting) inflated the denominator
and flipped a passing 69% quorum to failing. Grief cost: one 90-day lock.
**Fix:** `lockedAtPropose` snapshot in the proposal struct; quorum measured
against the snapshot. Test: `test_Exploit_QuorumInflationDuringVoting`
(mid-vote lock no longer blocks execution).

### G-4 — MEDIUM — proposal-wipe DoS (INTRODUCED by the G-2 fix, caught in this review)
The G-2 "dead proposal replacement" logic allowed replacing ANY unexecuted
proposal after the voting window — including one that PASSED but hadn't been
executed yet. Attacker front-runs the execute tx with `proposeCarpetBomb()`,
wiping the yes-votes and forcing a new 3-day cycle, repeatable forever.
**Fix:** replacement only allowed for FAILED proposals; a passing proposal
(quorum + majority vs snapshot) reverts `ProposalExists` and must be executed
(execution is permissionless). Test: `test_Exploit_PassingProposalCannotBeWiped`.

### Z-1 — MEDIUM — locking into a destroyed round
`lock()` accepted PSP after carpet bomb; hook drained, fees never accrue
again, PSP sits dead for 90 days.
**Fix:** `lock()` reverts `RoundDestroyed` when hook mode == Destroyed
(skipped only when no hook wired, i.e. pure unit-test env; production wiring
happens atomically in `PSPFactory.deployRound`). Tests: unit
`test_Exploit_LockIntoDeadRoundBlocked`, fork `test_Fork_ZombieLockAfterBomb`.

### G-2 — LOW — dead proposal bricks governance
A failed proposal (quorum miss) blocked all future proposals forever —
permanent governance DoS for 1 wei locked.
**Fix:** proposals only block during their live voting window; expired FAILED
proposals are replaced by the next `proposeCarpetBomb()` (see G-4 for the
passing-proposal carve-out). Test: `test_Exploit_DeadProposalGovernanceRecovers`.

### G-3 — LOW — permanent voter disenfranchisement
`hasVoted` never reset between proposals; every past voter was locked out of
all future proposals.
**Fix:** replaced mapping with per-proposal epoch (`proposalCount` +
`lastVotedOn`), O(1) gas, no iteration. Test: `test_Exploit_VoteEpochResetsPerProposal`.

### C-1 — LOW — dust-scale round-trip arbitrage (invariant violation)
Fuzzer found `buy 14868 wei → sell 15217 wei` (+2.3%) at supply ~7e3: at dust
scales, `divWad` truncation in `pStart/k` makes integral error exceed the
1 bps buy haircut. Economically nil (~3.5e-16 ETH/cycle) but breaks the
strict `sell ≤ buy` invariant.
**Fix:** `MIN_SWAP_INPUT = 1e12` guard in `_beforeSwap` (8 orders of magnitude
above the counterexample; covers buys, sells, and flat mode). Library-level
behavior documented in `test_Exploit_DustScaleRoundTripArbitrage`; on-chain
enforcement pinned by fork `test_Fork_DustSwapReverts`.

### G-5 — INFO — governance theater on dead rounds (found in this review)
`proposeCarpetBomb()` still worked on destroyed rounds (Z-1 only guarded
`lock()`); harmless (execution dies at hook `setMode`) but wasted gas and
created zombie-governance confusion.
**Fix:** same `RoundDestroyed` guard as `lock()`. Tests:
`test_Exploit_ProposeOnDeadRoundBlocked`, `test_Exploit_DoubleCarpetBombBlocked`.

---

## Accepted risks / by-design (do not re-report)

1. **Sole-locker fee rebate (F-1)** — a lone locker receives 100% of swap
   fees; whale who locks then churns trades effectively fee-free while
   capturing retail fees. Economic design choice, quantified in
   `test_Fork_SoleLockerCapturesAllSwapFees`.
2. **Unclaimed fees socialize to next round on carpet bomb** — lockors who
   don't claim before a bomb lose fees to round N+1. Documented incentive to
   monitor governance.
3. **First-locker accumulator windfall** — Synthetix math: fees accrued
   before the first locker all flow to the first locker when the second
   joins. Known MasterChef-class behavior; functions as early-participation
   incentive.
4. **1-wei lock top-up resets the 90-day timer** — vlCVX semantics, documented.
5. **MockMixETH vs real Alchemix VaultV2** — V4's raw `take()` transfers are
   incompatible with VaultV2 internal accounting; a wrapper/adapter is
   required before production mixETH. Excluded from this review's scope by
   prior decision; remains the biggest pre-production engineering risk.
6. **`emergencyPause()` is a no-op, `markDestroyed` reuses `ZeroAddress` for
   its auth failure** — cosmetic; hook mode system is the real circuit breaker.

---

## Verification of the 5 requested fixes

| Fix | Verdict |
|---|---|
| G-1 quorum snapshot | HOLDS — plus invariant: attacker lock mid-vote is now irrelevant to quorum |
| G-2 dead proposal replacement | HELD but introduced G-4 wipe-DoS; G-4 now fixed, G-2 still holds for failed proposals |
| G-3 vote epoch | HOLDS — same-proposal double-vote still reverts |
| Z-1 zombie lock guard | HOLDS — unit + fork, MockHook setMode made real |
| C-1 dust swap guard | HOLDS — buy/sell/flat all guarded; boundary (exactly 1e12) allowed |

## Static analysis & test integrity

- Slither: 34 results, all INFO-class (strict-equality `totalSupply == 0`
  guards, numeric-literal warnings). No high/medium.
- `grep vm.mockCall|vm.expectCall|assertTrue(true)` in `test/`: **zero matches**.
- No floating pragmas (`pragma solidity 0.8.26` everywhere).
- No raw `.approve()`/`.transfer()` on IERC20 in `src/` (SafeERC20 throughout,
  `forceApprove` in factory carry path).
- Events emitted before external calls in all modified functions.

## Coverage of attack classes reviewed

Reentrancy/CEI (all mutating paths re-checked, guards present), access control
(controller-only mint/burn, factory-only setController, hook-only swap
support), V4 specifics (BeforeSwapDelta signs fork-verified, sync→transfer→settle
ordering, unfunded swap reverts, WrappedError handling), ERC-4626 rounding
(conversion round-trip fuzzed non-amplifying), governance (quorum/majority/
epoch/replacement — 12 adversarial tests), curve math (round-trip, split-buy,
seam continuity, MAX_SUPPLY clamp, monotonicity — all fuzzed), economic
(atomic MEV churn loses money on real V4, multi-pool interleave solvent,
cross-round isolation verified).
