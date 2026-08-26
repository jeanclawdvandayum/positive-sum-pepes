# PSP Security Review — GLM-5.3 (Independent)

**Date:** 2026-08-14
**Repo:** `~/clawd/positive-sum-pepes` @ working tree (no git history; untracked files)
**Reviewer:** independent GLM-5.3 pass, evm-cortex multi-pass methodology (CEI/access → math/economic → static analysis + integration)
**Scope:** `src/CurveHook.sol`, `src/RoundController.sol`, `src/PSPFactory.sol`, `src/PSPToken.sol`, `src/libraries/CurveMath.sol`, `src/interfaces/IRoundController.sol`, `src/utils/HookMiner.sol`, `test/integration/V4SwapRouter.sol` (test infra)

---

## 1. Validation Gate

| Check | Result |
|---|---|
| `forge build` | ✅ clean (lint warnings only, all in `test/`) |
| `forge test --no-match-path 'test/integration/*'` | ✅ **226 passed, 0 failed** (13 suites, incl. invariant fuzz: 256 runs × 128k calls) |
| `forge test --match-path 'test/integration/*'` (mainnet fork, real V4 PoolManager) | ✅ **54 passed, 0 failed** (6 suites) |
| Test integrity grep (`vm.mockCall\|vm.expectCall\|assertTrue(true)\|try.*catch` over `test/`) | ✅ **0 matches** — no mocked behavior, no swallowed failures, no empty assertions anywhere in the tree |
| `slither . --filter-paths "test/\|script/\|lib/"` | ✅ **0 High / 0 Medium** — 35 informational results only (intentional low-level calls: the ERC-4626 `totalAssets` probe and the factory `markDestroyed` callback; naming conventions; numeric literals) |
| Hardcoded selector `0x01e1d114` | ✅ verified via `cast sig "totalAssets()"` → `0x01e1d114` |

## 2. Verdicts on the 7 fixes under verification

All 7 **HOLD**. None introduced a new vulnerability.

- **G-1 (quorum snapshot)** — `lockedAtPropose` captured at `propose()` (RoundController.sol:474); `carpetBomb()` checks quorum against the snapshot (:518). With M-1 layered on (numerator time-gated), the snapshot is now sound in both directions: mid-vote locks can neither inflate votes above the snapshot nor dilute quorum.
- **G-2 (dead-proposal replacement)** — expired-unexecuted proposals are replaceable (:455-458). Correct.
- **G-3 (vote epoch)** — `proposalCount` / `lastVotedOn` O(1) epoch pattern (:487-489). New proposal re-enfranchises all voters; no iteration, no nested mapping. Correct.
- **G-4 (passing proposals not wipeable)** — replacement recomputes quorum **and** majority against the propose-time snapshot and reverts `ProposalExists` for passing-but-unexecuted proposals (:460-465). Execution is permissionless, so no griefing window remains. This closes the wipe-DoS that G-2 itself introduced in the prior pass. Correct.
- **G-5 (no governance on destroyed round)** — `proposeCarpetBomb()` reverts `RoundDestroyed` (:443-445). `vote()` needs no explicit guard: post-execution the timestamp check kills it (`VotingEnded`), and no new proposal can exist post-destruction since `propose` is the only entry. Guard symmetry holds. Correct.
- **Z-1 (lock() on destroyed round)** — reverts `RoundDestroyed` (:303-305). `claimFees`/`unlock`/`relock` intentionally remain open (principal + fee recovery on the corpse) — correct asymmetry: lock adds new exposure, recovery paths remove it. Correct.
- **C-1 (dust guard)** — `MIN_SWAP_INPUT = 1e12` enforced in `_beforeSwap` before buy/sell dispatch (CurveHook.sol:167), covering both directions. Correct.

## 3. Verdicts on the second-round fixes (regression check)

All fix markers re-verified in source; regression tests confirmed present and asserting real behavior:

- **H-1 (relock double-claim)** — `relock()` → unified `_claimPendingFees(true)` (:361); rewardDebt is always refreshed before any payment, on every fee-paying path (lock :314, unlock :338, relock :361, claimFees :381 via `_claimPendingFees(false)`). The `pending == 0` early-return is safe (rewardDebt stale ⟺ pending ≠ 0 is an invariant: accumulator only grows and every amount-mutation recomputes rewardDebt). `test_RelockFeesPaidOnce` pins it. **Holds.**
- **H-2 (mining gas)** — `codeHash` hoisted (HookMiner.sol:32), per-iteration keccak over the 85-byte preimage only, salt slot rewritten in place; the `.code.length` probe was dropped (CREATE2 collision ⟺ keccak collision). `Factory.t::test_Gas_DeployRoundUnder10M` asserts min-of-4 draws < 10M — the geometric-draw judgment call is sound (a regression shifts the whole distribution to ~35M+ min and still hard-fails). **Holds.**
- **M-1 (post-snapshot vote capture)** — `VoteLockedAfterPropose` on `lockTime >= proposeTime` (:498). Soundness re-derived independently: all three weight-mutating paths (`lock` :321, `claimPredepositPSP` :287, `relock` :364) stamp `lockTime = block.timestamp`; amounts can only decrease post-propose (`unlock` zeroes, and the only voter-eligible state requires an untouched lock). Therefore `yesVotes + noVotes ≤ lockedAtPropose` structurally, including same-block sandwiches. **Holds.**
- **M-2 (fee-leg revert traps principal)** — forfeit-on-shortfall (`_claimPendingFees(true)`) on unlock/relock/lock-top-up; strict revert on `claimFees` (caller intent = fees; principal still recoverable via unlock). `FeesForfeited` emitted. try/catch wraps the **external** `hook.sendFees` call directly (compiles — the earlier internal-helper mistake was not repeated). **Holds, with one residue — see L-5.**
- **M-3 (unvalidated CurveConfig)** — `CurveMath.validate()` is the first statement of `_deployRound` (PSPFactory.sol:82); covers zone count 1..50, P0 > 0, first zone at 0, strictly-increasing contiguous boundaries, log rate ≤ 1e18, exp rate ≤ 100e18, last zone unbounded. Raw-calldata entrypoint `deployRound` is owner-gated **and** validated. **Holds.**
- **L-1** `carryToNextRound` onlyOwner (:163). **L-2** `BEFORE_INITIALIZE_FLAG` in the mined flag set (PSPFactory.sol:104-110) **matches** `getHookPermissions()` (CurveHook.sol:99) and `_beforeInitialize` gates the canonical {mixETH, PSP} pair order-independently (:124-139) — the permission/address coupling is consistent across both files. **L-3** `emergencyPause` absent (tombstone comment :562), `sweep()` reverts `ProtectedToken` (:569). **L-4** `ZeroShare` checked before `dep.claimed` flips (:269-272). **All hold.**

## 4. New findings

### L-5 (LOW) — `claimPredepositPSP` fee leg is strict: M-2 unification missed this path → **FIXED**
`RoundController.sol:280-283` (original). When the caller already has a lock (`userLock.amount > 0`), the claim paid pending fees via `_transferFees` → bare `hook.sendFees(...)` — no forfeit path. After a carpet-bomb drain, a user with pending > 0 **and** an unclaimed predeposit got `InsufficientFees` on every claim attempt, with the 1-wei-topup shortcut blocked by Z-1 forcing a full 90-day wait.

**Fix applied (2026-08-14, post-review):** fee leg routed through `_claimPendingFees(true)` — identical M-2 semantics to lock/unlock/relock (forfeit-on-shortfall, `FeesForfeited` emitted, rewardDebt refreshed). `_transferFees` had a single call site and was removed with it. Explicit `claimFees` remains strict by design (caller intent = fees).
**Regression test:** `test_L5_ClaimPredepositAfterDrain` — full lifecycle: predeposit + separate lock → fees accrue → carpet bomb drains hook to zero → strict `claimFees` reverts `InsufficientFees` → `claimPredepositPSP` succeeds, emits `FeesForfeited(bob, 50e18)`, pays nothing, claims the predeposit PSP into the lock.

### Informational → all addressed (2026-08-14 hardening pass)
- **I-1 — FIXED:** `sweep()` now gates mixETH on `!predepositClosed` instead of protecting it unconditionally. Pre-launch the controller custodies accounted predeposits (still protected); `launchPooledBuy` sets the flag **before** transferring exactly `totalPredepositMixETH`, so post-launch the accounted mixETH balance is zero by construction and any remainder is stray (donations, misroutes) with no user claim on it — rescuable by the owner. PSP remains permanently protected (it is user principal custody: locked PSP + unclaimed predeposit allocations). Test: `test_I1_SweepStrayMixETHAfterLaunch` (also asserts PSP sweep still reverts post-launch); pre-launch protection still pinned by `test_L3_SweepProtectedTokens`.
- **I-2 — FIXED:** `ZeroOutput()` revert in all four swap handlers (`_handleBuy`, `_handleSell`, `_handleFlatBuy`, `_handleFlatSell`), checked immediately after output computation and **before any state mutation**. A swap can no longer silently absorb input while minting/paying nothing — dust-at-insane-price buys revert instead of donating to the reserve. Guard is unreachable for third parties: pushing the curve price past the min-size threshold costs >1e30 ETH, and flat-mode price strictly falls under both market actions. Fork test: `test_Fork_ZeroOutputBuyReverts` (P0 = 1e30, exactly-MIN input; asserts no PSP minted, input balance untouched, pool still solvent).
- **I-3 — FIXED:** `Buy`/`Sell` events moved to directly after the CEI state updates, before `take`/`mint`/`burn`/`settle`/`addFees` — events-before-interactions convention now holds in all four handlers. (Reverted transactions roll back logs, so no phantom-event risk from the reordering.)
- **I-4 — FIXED:** dedicated `NotRoundController()` error in `PSPFactory.markDestroyed` (was the misleading `ZeroAddress`). Test: `test_I4_MarkDestroyedOnlyFromRoundController` (wrong caller, nonexistent round, and the legitimate controller path).

### Accepted risks (out of scope per commission, not counted)
Sole-locker fee rebate economics · socialized unclaimed fees on carpet bomb · first-locker accumulator windfall · 1-wei top-up lock-timer reset · `MockMixETH` standing in for the real Alchemix VaultV2 (re-audit the real adapter when it lands — note the V4 `take()` incompatibility flagged earlier).

## 5. Conclusion

The codebase is in the best state of the campaign: **226/226 unit+invariant green, 54/54 fork green against the real V4 PoolManager, zero test-integrity violations, zero static-analysis findings above the pre-existing informational set (verified by JSON diff against a reverted baseline — no new detectors), all 15 tracked fixes (G-1..G-5, Z-1, C-1, H-1/H-2, M-1/M-2/M-3, L-1..L-4) verified present, correct, and regression-free.** The L-5 residue is now fixed and regression-pinned, and all four informational notes were addressed in the hardening pass. Every principal-bearing path now uses the unified `_claimPendingFees` semantics; `_transferFees` is gone. No HIGH or MEDIUM findings. No blocking issues for testnet deployment; the real-mixETH-adapter re-audit remains the open pre-mainnet item.

### Fix log (2026-08-14 hardening pass)
- `src/RoundController.sol` — L-5 (claim fee leg → `_claimPendingFees(true)`), `_transferFees` removed (dead), sweep mixETH gate on `predepositClosed` (I-1)
- `src/CurveHook.sol` — `ZeroOutput()` guard ×4 handlers (I-2), emit ordering (I-3)
- `src/PSPFactory.sol` — `NotRoundController()` (I-4)
- Tests added: `test_L5_ClaimPredepositAfterDrain`, `test_I1_SweepStrayMixETHAfterLaunch`, `test_I4_MarkDestroyedOnlyFromRoundController`, `test_Fork_ZeroOutputBuyReverts`
- Test-infra fix (pre-existing, proven by reverted-baseline run): `test/integration/AdvancedScenario.t.sol` used inline `vm.warp(block.timestamp + N)` which on live forks evaluates against the fork-genesis timestamp (forge quirk; `skip()` reads via the cheatcode and is correct) — this made `test_Adv_ThreeRoundsInSequence` fail with `VoteLockedAfterPropose` after any 90-day time skip. All inline warps in that file replaced with `skip()`. The M-1 guard itself behaved correctly throughout.
- Attacker re-read of every diff applied post-fix (per methodology meta-rule): no new attack surface introduced — see per-item notes above.
