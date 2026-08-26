# Wave 2 Independent Security Audit — Auditor A
**Target:** RoundController accounting & governance (`src/RoundController.sol`, `src/PSPToken.sol`, interfaces; CurveHook/PSPFactory read for reachability)
**Repo:** `/Users/clawdbot/clawd/positive-sum-pepes` @ Solidity 0.8.26 (pre-deployment review)
**Date:** 2026-08-18 · **Auditor:** independent (Auditor A), no prior context
**PoC suite:** `test/wave2/auditorA/` — 6 files, 40 tests, **40 PASS / 0 FAIL**
Reproduce: `forge test --match-path "test/wave2/auditorA/*" -vv`

---

## 1. Executive summary

I threat-modeled the accounting and governance surfaces of RoundController: the
predeposit → genesis-split → lock lifecycle, the fee accumulator and its claim
paths, the side-pot ledger (potPSPBalance / totalPotMixETH), the carpet-bomb
voting mechanism (quorum/majority/snapshot integrity), and the
flatten → flat-window → finalize → rebirth state machine, including custody
invariants (`psp.balanceOf(controller) == totalLocked + potPSPBalance`) and
reentrancy on every payout path.

Overall: the governance core is solid. The documented in-code fixes (M-1
vote-eligibility snapshot, G-1 quorum snapshot, G-2/G-3/G-4 proposal lifecycle,
NK24 supply-floor denominator, H-1 rewardDebt refresh, Z-1 phase guards) all
held under adversarial PoCs, including a hostile-ERC20 reentrancy harness. I
found **no way to steal locked user funds, inflate vote weight, double-claim
fees, or brick the exit paths**.

What did break: **the side pot's ring-fencing leaks during the flat window**
(A-F2, MED — reproduced end-to-end on the real CurveHook/PSPFactory stack:
~87.5e18 pot PSP stranded per simulated round), **post-launch
`seedCarry`/`potDeposit` lack phase guards** (A-F1, MED, factory-trusted
misuse: 2× dilution of depositor genesis claims + panic on a late factory
claim), and two LOW accounting-dust issues (A-F3 accumulator wipe, A-F4
finalize fee sweep). Several INFO-level edges are documented below.

Nothing modified outside `test/wave2/auditorA/`.

---

## 2. Findings

### A-F1 — `seedCarry()` has no phase guard: post-launch call dilutes all depositor claims and mints the factory a voting lock
**Severity: MEDIUM · Confidence: 95% (reproduced)** · **File:** `src/RoundController.sol:312-324`

`seedCarry` is meant to run at round birth (spawnNextRound → seedCarry, before
the public window). It checks only `msg.sender == factory` (L313) — there is no
`predepositClosed` / mode check — and then unconditionally runs
`_recordPredeposit(msg.sender, actualAmount)` (L322), increasing
`totalPredepositMixETH` and crediting the *factory* a predeposit share.

**Exploit scenario (trusted-party misuse or wiring bug):** round has launched
(predepositClosed), depositors' genesis shares are fixed. Factory calls
`seedCarry(X)` with X = current total. Now `totalPredepositMixETH` doubles:
every depositor's `claimPredepositPSP` share halves, and the factory claims the
other half of the genesis PSP — receiving a fresh **90-day governance lock**
(vote weight in every future carpet-bomb proposal of the round). Measured in
PoC: alice's claim drops from G to G/2 (±2 wei); factory captures G/2.

Sub-finding **A-F1b**: if all genesis shares were already claimed, the
factory's own later `claimPredepositPSP()` reverts with **Panic(0x11)**
(arithmetic underflow on the exhausted genesis lock) — a hard-bricked claim
entry for the factory.

Reachability is the mitigating factor: caller must be the PSPFactory (Ownable
owner). It cannot be triggered by an attacker; it is an operational
foot-gun/centralization vector. A one-line `if (predepositClosed) revert` (or
routing seedCarry before `launchPooledBuy` only) closes it.

**PoC:** `test/wave2/auditorA/A3_Lifecycle.t.sol::test_F1a_post_launch_seedCarry_dilutes_predepositors` — PASS
`test/wave2/auditorA/A3_Lifecycle.t.sol::test_F1a2_factory_claim_after_genesis_exhausted_panics` — PASS

---

### A-F2 — Side-pot PSP accrued during the flat window is stranded forever; its backing is silently re-routed from the pot to the generic carry
**Severity: MEDIUM · Confidence: 98% (reproduced on the real contract stack)**
**Files:** `src/RoundController.sol:777-791` (bomb-time redemption), `:813-837` (`finalizeCarpet` ignores `potPSPBalance`), `src/CurveHook.sol:371` (flat buy → `mintPotPSP`), `:426-429` (flat sell → PSP transfer + `creditPotPSP`)

The pot's ONLY exit is `carpetBomb()` L777-791: redeem `potPSPBalance` at
average backing, burn it, credit the factory's ring-fenced `sidePot`. But the
hook keeps accruing pot PSP **during the 3-day flat window** (both buy and sell
paths), *after* the bomb has already executed. `finalizeCarpet()` never touches
`potPSPBalance`: it drains the hook, marks destroyed, spawns round 2. The
flat-window pot PSP is now held by a dead controller with:
- `carpetBomb()` → `AlreadyExecuted`,
- `sweep(PSP)` → `ProtectedToken` (PSP is permanently sweep-protected),
- no other exit.

Its **backing** is not lost to the protocol — `drainAll` sends the hook's whole
balance (incl. the flat-pot's pro-rata reserve slice) to the factory, where it
counts as **generic carry**, not `sidePot`. So round-2 predepositors receive
what the compounding side-pot mechanism was designed to accumulate, and the
pot's PSP principal is permanently locked (unburned supply overhang in a dead
token).

**Measured (real PSPFactory + real CurveHook + real zaps, MockPoolManager
executing the genuine v4 flow):** flat-window trades accrued
**87,478,904,768,237,537,981 PSP (~87.5e18)** of pot that never reached the
factory (`sidePot == 0` from this stream), remained at
`controller.potPSPBalance` after finalize, and passed the
no-sweep/no-re-execute checks. The rebirth loop itself stays healthy (round 2
accepts predeposits, launches, trades — verified).

Impact grows with flat-window volume; this is normal-operation leakage, not an
attack. Suggested fix: redeem-and-forward the pot inside `finalizeCarpet()`
(same three calls as carpetBomb), or stop pot accrual when
`mode == Flat`.

**PoC (real stack):** `test/wave2/auditorA/A4_E2E.t.sol::test_E2E_F2_flat_window_pot_stranded_on_real_stack` — PASS
`test/wave2/auditorA/A4_E2E.t.sol::test_E2E_round2_rebirth_loop_alive` — PASS
**PoC (mock isolation):** `test/wave2/auditorA/A3_Lifecycle.t.sol::test_F2_flat_window_pot_accrual_stranded_forever` — PASS

---

### A-F3 — Fee accumulator wipes the floor remainder: sub-share dust becomes permanently unclaimable
**Severity: LOW · Confidence: 95% (reproduced)** · **File:** `src/RoundController.sol:657-660`

```solidity
if (pendingFeesMixETH == 0) return;
accFeePerShareMixETH += (pendingFeesMixETH * PRECISION) / totalLocked;
pendingFeesMixETH = 0;            // ← unconditional, remainder discarded
```

When `pendingFeesMixETH * 1e18 < totalLocked`, the accumulator delta floors to
zero **and** the pending buffer is zeroed — the wei exist at the hook (surplus)
but the ledger says nothing is claimable, forever. Reproduced: two `addFees`
calls of 2 and 3 wei against L ≈ 9.78e23 locked → `accFeePerShareMixETH == 0`,
`pendingFeesMixETH == 0`, `claimFees()` → `NothingToClaim`. The dust is not
stolen — it eventually rides `drainAll` into the carry — but the "rolling
remainder" pattern (`pending = pending + amount - distributed`) that
masterchef-style accumulators use to make dust eventually claimable is absent.
Fix: `pendingFeesMixETH = pendingFeesMixETH - (accDelta * totalLocked / PRECISION)`.

**PoC:** `test/wave2/auditorA/A2_Accounting.t.sol::test_F3_accumulator_dust_stranded_forever` — PASS

---

### A-F4 — Unclaimed (accrued) staker fees are swept into the round-2 carry at finalize
**Severity: LOW · Confidence: 90% (reproduced; partially documented behavior)** · **File:** `src/RoundController.sol:813-837` + CurveHook `sendFees`/`drainAll` surplus model

`finalizeCarpet` drains the hook's entire mixETH balance — reserve **plus
fee surplus** — into the factory carry. Any staker who accrued fees but did not
`claimFees()` before the flat window closes forfeits them to round 2:
afterwards `claimFees()` reverts `InsufficientFees` (strict path) and
`unlock()` silently emits `FeesForfeited`. PoC: bob's 40e18 accrued fees
(60/40 split of 100e18) end up in the factory carry; principal still exits
cleanly. The in-code comments ("whatever they leave on the table is what the
next round inherits") suggest intent, but the deadline is implicit — a UI-level
warning ("claim before round ends or forfeit") seems warranted. Not a theft;
flagging as a fee-distribution fairness/UX edge.

**PoC:** `test/wave2/auditorA/A3_Lifecycle.t.sol::test_finalize_sweeps_unclaimed_fees_bob_forfeits` — PASS

---

### A-I1 (INFO) — `relock()` has no upper bound; natspec inaccurate
`src/RoundController.sol:580-599`. The only window check is the lower bound
`ts >= unlockTime - 7d` (L588). Callable arbitrarily long after expiry, always
resetting a fresh 90d term and refreshing `lockTime` (which disenfranchises the
relocker from any concurrently-active proposal — a safe direction).
**PoC:** `A3_Lifecycle.t.sol::test_relock_callable_long_after_expiry` — PASS (caveat: the forge cheatcode timestamp quirk described in §4 makes one leg of this test's clock arithmetic weaker than intended; the post-expiry relock itself is source-verified L588).

### A-I2 (INFO) — `ZeroShare` claim does not mark the depositor claimed
A 1-wei depositor (on a 1:1-start curve, share floors to 0) reverts
`ZeroShare` without setting `claimed` and without a lock — they can retry
forever (no state pollution, deposit stays accounted, funds ride the reserve).
Benign; noted because there is no dust-refund path for such depositors.
**PoC:** `A2_Accounting.t.sol::test_zero_share_dust_depositor_not_marked_claimed` — PASS

### A-I3 (INFO) — All factory callbacks are raw `call`s with precomputed selectors
`src/RoundController.sol:789, 825, 832` (`0xada2e425` creditSidePot,
`0x723c5612` markDestroyed, `0x1c9424dc` spawnNextRound — EIP-170 workaround).
I verified with `cast sig` that all three match the current PSPFactory ABI,
and behavior-tested each path (mark/spawn/credit). Risk is purely future ABI
drift compiling silently — recommend a comment-anchored test (like this suite)
or a runtime selector assert in CI.

### A-I4 (INFO) — Per-claim fee rounding is double-floored toward the protocol
Each claim floors twice (accumulator, then per-user share). Measured loss on a
1e18 distribution with L≈9.78e23: 707,058 wei (~7e-13 relative) — dust bounded
by ~2·L/1e18 wei per claim, direction favors the hook surplus (→ carry).
Normal for the pattern; listed for completeness.
**PoC:** `A2_Accounting.t.sol::test_fee_split_conservation` — PASS

---

## 3. Verified-safe (attacked and held)

**Governance / carpet bomb**
- Quorum math: 60% cast < 69% (`QUORUM_BIPS=6900`) reverts `QuorumNotReached`; 80% executes. Exact-69% boundary is `>=` (L761 uses `<` to revert).
- Majority: 50/50 tie fails (`MAJORITY_BIPS=5001`, strict `>` at L764).
- **NK24 supply floor**: sole locker holding 100% of `totalLocked` still fails quorum when hook supply is 2× locked — denominator is `max(totalLocked, hook.totalSupplyPSP)` at propose (L711, L719-722). Thin-lock capture dead.
- **M-1**: fresh `lock()`, `relock()`, and delayed `claimPredepositPSP()` after `proposeTime` all correctly disenfranchised (`VoteLockedAfterPropose`, L741 — note it's `>=`, so same-block locks also excluded).
- **G-1/G-2/G-3/G-4**: failed proposal replaceable only after its window; prior voters re-enfranchised on the successor; a passing-but-unexecuted proposal cannot be front-run-replaced (`ProposalExists`) and stays executable; no proposing once flat/destroyed.
- No double vote (per-proposal epoch via `lastVotedOn`), no early execution (L756 `<=` end → `VotingEnded`), no double execution, no mid-vote `unlock` (90d term ≫ 3d window; totalVotes structurally ≤ snapshot).

**Accounting & custody**
- **H-1 invariant** `psp.balanceOf(controller) == totalLocked + potPSPBalance` held across: launch, `mintPotPSP`, `mintPSPForSwap`+transfer+`creditPotPSP`, `unlock`, bomb (pot burn), finalize — on mocks *and* the real stack.
- Fee distribution: 60/40 pro-rata within rounding (A-I4); genesis-lock fees accrue to the share and pay out at claim even a month late; no over-distribution in any test.
- Strict-vs-forfeit fee paths behave as documented: `claimFees` reverts `InsufficientFees` on hook shortfall; `unlock` forfeits fees (event) but **always releases PSP principal** — no principal trap.
- **Reentrancy**: hostile ERC20 (callbacks fired mid-`transfer` on the payout leg of `claimFees` and `unlock`) attempted reentrant `claimFees`/`unlock` — 0 successes (nonReentrant + rewardDebt-before-pay), single payout delivered. Attacker contract got exactly one distribution.
- Launch/window gates: non-owner cannot launch while window open & cap unreached; owner can launch early; anyone at cap-exact or after 7-day window expiry (permissionless launch verified).
- Cap: exceeding reverts `CapExceeded`, cap-exact lands.
- Sweep: mixETH protected pre-launch (deposits accounted), PSP protected always, stray tokens rescuable by owner.
- `seedCarry`/`potDeposit` are `NotFactory`-gated (the A-F1 issue is the *timing*, not the access).
- Pot redemption happy path: pre-launch pot → bomb redeems at avg backing, burns pot PSP, credits ring-fenced factory `sidePot`, hook supply drops by the pot share (±1 wei).
- Flat-window exits: `unlock()` bypasses the 90-day expiry while flat (exit path open); Z-1 blocks new `lock()` in flat/destroyed.
- **finalizeCarpet atomicity**: with a factory whose `spawnNextRound` reverts, the whole call reverts — hook still `Flat`, `markDestroyed` rolled back, reserve untouched (`FactorySpawnFailed`).
- PSPToken: one-time factory-gated `setController`; mint/burn controller-only (full read).
- Factory-side guards (read + selector-verified): `creditSidePot` restricted to the *current* round's controller with `SidePotOverdrawn` balance check; `markDestroyed` to the round's own controller; `spawnNextRound` strictly latest-round.

---

## 4. Could-not-verify / caveats

1. **Real Uniswap v4 PoolManager.** All swap-path tests ran against
   `MockPoolManager` (which does execute the genuine unlock/sync/settle/
   beforeSwap/take flow against the real CurveHook). Mainnet-fork harness
   exists in-repo; I judged unit PoCs sufficient and did not fork. V4-specific
   delta-accounting edge cases (e.g. minted-claim settlement quirks) are
   therefore out of my evidence base.
2. **Hostile-mixETH fee-token semantics.** My hostile token reenters but is
   otherwise well-behaved (no fee-on-transfer, no balance lies). A
   fee-on-transfer mixETH would break `seedCarry`'s measured-deposit pattern
   (it actually handles it via balBefore/balAfter) but I did not fuzz balance
   deflation inside `addFees`/`sendFees` surplus accounting.
3. **CurveMath zone-boundary rounding** (multi-zone integrals) — reviewed the
   validation invariants (M-3/NK24 hardening) but wrote no exhaustive math
   PoCs; treated as out of primary scope (accounting/governance).
4. **Economic vote-buying**: buying PSP on the curve and locking *before*
   propose is legal participation; the supply floor prices it at ≥69% of
   everything outstanding. I verified the mechanism, not the game-theoretic
   equilibrium.
5. **Forge quirk encountered (test-infra, not protocol):** after a call whose
   revert was absorbed by `vm.expectRevert`, `block.timestamp` arithmetic in
   the *test contract* evaluated from a stale timestamp while external calls
   still ran at the warped time — produced a misleading `VotingEnded` failure
   until I switched all chained warps to absolute targets read from contract
   state (`_warpPastVote`). Flagging in case other auditors hit it.
6. **Gas/DoS of `spawnNextRound` hook mining** under mempool contention —
   HookMiner is cheap (hoisted code hash), but I did not adversarially
   measure it.

---

## 5. PoC inventory (all green, 40/40)

| File | Tests | Covers |
|---|---|---|
| `test/wave2/auditorA/AuditorMocks.sol` | — | AuditorHook, AuditorFactory/FailFactory, HostileMixETH + ReentryAttacker |
| `test/wave2/auditorA/AuditorBase.sol` | — | shared harness + custody-invariant helper |
| `test/wave2/auditorA/A1_Governance.t.sol` | 15 | quorum/majority, NK24 floor, M-1 (3 variants), G-2/G-3/G-4, vote/execute gates |
| `test/wave2/auditorA/A2_Accounting.t.sol` | 14 | A-F3, fee split/conservation, genesis accrual, strict/forfeit, H-1, ZeroShare, reentrancy, launch/cap/sweep/factory gates |
| `test/wave2/auditorA/A3_Lifecycle.t.sol` | 9 | A-F1 + A-F1b (panic), A-F2 (mock), A-F4, pot happy path, relock INFO, flat exits, finalize atomicity |
| `test/wave2/auditorA/A4_E2E.t.sol` | 2 | A-F2 on the real factory/hook/zaps; round-2 rebirth |

Severity × confidence recap: **A-F2 MED/98 · A-F1 MED/95 · A-F3 LOW/95 ·
A-F4 LOW/90 · A-I1..A-I4 INFO (source-verified + PoC'd)**. No HIGH/CRIT found
on the surfaces in scope.
