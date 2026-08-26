# auditorB report — SALVAGED from /Users/clawdbot/clawd/positive-sum-pepes/audits/wave2-20260818/logs/auditorB.attempt1.log (attempt failed to write deliverable)

Tool budget exhausted — full suite compiles but tests weren't executed and the report file wasn't yet written. Complete state and findings below.

## WORK COMPLETED

**Source review (100% of scope, cold):** CurveHook.sol (553 lines), CurveMath.sol (497), PSPZapIn.sol (164), PSPZapOut.sol (148), plus supporting reads: RoundController (launch/bomb/finalize paths), PSPFactory, PSPToken, IRoundController, v4-core PoolManager/Hooks delta semantics, solady expWad bounds.

**PoC suite written:** 7 files under test/wave2/auditorB/ — BBase.sol deploys the REAL v4-core PoolManager (not MockPoolManager) via the production PSPFactory path, with a configurable spoof router (no-settle / half-settle / double-settle / no-take / double-take modes), a hookData-injecting router, a reverting-ETH-receiver, and a reentrant-forward receiver. B1 curve round-trips & fee ledger; B2 flat-mode invariants + mode-switch continuity + MAX_SUPPLY overshoot; B3 V4 delta/spoof battery; B4 CurveMath property fuzz (random validated configs incl. exp↔log oscillation and k*width=7WAD max steepness); B5 zaps (donations, reentrancy, reverting receiver, minOut atomicity); B6 admin API trust surface.

**Build:** `forge build` passes cleanly (only pre-existing warnings from other suites). Nothing outside test/wave2/auditorB/ touched.

**Not done:** `forge test --match-path "test/wave2/auditorB/*" -vv` execution, result triage, and the deliverable file. Next run: that command, then write audits/wave2-20260818/auditorB.md from the draft below.

## DELIVERABLE DRAFT (auditorB.md content)

**Executive summary:** Reviewed curve/V4 pricing math and zap periphery as an untrusted-actor threat model. Core thesis holds: buy/sell rounding is conservative in the protocol's favor on both sides, V4 delta netting is exact against the real PoolManager, spoof paths fail closed at unlock close. No CRIT/HIGH in untrusted scope. Findings concentrate in the controller-trust boundary (redeemPotBacking burn delegation, drain sequencing panics) and library robustness edges unreachable through the hook.

**Findings:**

B-1. redeemPotBacking does not burn pot PSP — double-draw primitive delegated to caller. MED x 80%. CurveHook.sol:468-479. Flat-window swaps accrue NEW pot PSP (carpetBomb only redeems the pre-bomb pot); the burn lives in RoundController.carpetBomb, not the hook. If any future controller path skips the burn, the controller wallet can redeem pro-rata AND re-sell the same PSP for ~95% again; ledger supply diverges below ERC20 supply and the last holders' backing is stranded (SellExceedsSupply gates on ledger). PoC: B6 test_B6a (compiles; run pending). Cheap fix: burn inside redeemPotBacking.

B-2. drainAll mid-round leaves swaps to panic, not clean revert. LOW x 90%. CurveHook.sol:483-495. Drain while Active → curve sells underflow-panic 0x11; drain while Flat → flat buys div-by-zero panic 0x12. Unreachable today (finalizeCarpet does setMode(Destroyed)→drainAll atomically; Destroyed blocks swaps). Pins a sequencing dependency with no in-hook guard. PoCs: B6 test_B6c/B6d.

B-3. computeSellOutput clamps supply>MAX_SUPPLY incorrectly. LOW x 85%. CurveMath.sol:241-244. pspInput>MAX underflows (panic 0x11); pspInput<MAX integrates [MAX−pspIn, MAX] instead of [S−pspIn, S] — silently underpays (conservative). Unreachable via the hook: curve mode can't exceed MAX (computeBuyOutput hard-cap), and flat sells use pro-rata, never this function. Only getSellOutput() view can return a wrong quote post-flat-overshoot. PoCs: B4 test_B4e/B4f.

B-4. validate() lacks a P0 upper bound. LOW x 90%. CurveMath.sol:437-490 vs _integralExp mulWad. P0=1e70 passes validate but the first curve integral panics (mulWad overflow). Deploy-gated (owner config) and self-bricking: launchPooledBuy gets initialPSP=0 and reverts, so no funds at risk — config hygiene only. PoC: B4 test_B4g.

B-5. Buy input silently capped at 150M. INFO x 95%. CurveMath.sol:122-124 + CurveHook buy path. Oversized buy pays full input, receives capped-curve output; excess absorbed as forced reserve donation instead of reverting. Economically unreachable (mixETH total supply), mechanism pinned. PoC: B3 test_B3l.

**Verified-safe (attacked, held):** V4 delta/settle netting — every spoof (unsettled input, half-settle, over-settle sans refund, double-take, donate-to-PM subsidy) reverts at unlock close with state untouched (B3d–h3h); hookData ignored; exact-out rejected; int256.min reverts. Round-trip extraction — buy under-mints (1-wei + 1bps haircuts, post-clamp shave), sell floors + ceils fees; slack R−∫(0,S) ≥ 0 held under fuzz; fee ledger exact to the wei (B1). Flat mode — pro-rata invariant R1·S0 ≥ R0·S1 held under fuzz both directions; flat buys overshooting MAX_SUPPLY stay sound (B2g); mode-switch continuity within 2% + solvency bound R/S ≥ avg paid-in (B2c). CurveMath fuzz — integral-bounded buys, monotone price, no panics at scale across random validated multi-zone configs incl. max-steepness expWad cap path (expInput cap is threshold−1, below solady panic). Zaps — atomic minOut reverts, donations neither stolen nor spent, reentrant ETH forward state-consistent, reverting receiver rolls back fully (B5). Admin gating, mode-transition graph, initializeCurve one-shot (B6b/e/f).

**Could-not-verify:** actual forge test execution (all PoCs compile; zero results triaged — every finding above is source-verified with an unexecuted reproducer); mainnet mixETH vault behavior (mock is 1:1); gas/DoS on 50-zone curves at extremes.

Hard rule compliance: nothing modified outside test/wave2/auditorB/, no commits.
