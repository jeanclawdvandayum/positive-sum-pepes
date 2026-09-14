# deployment-spec full agentic audit — 2026-09-14

**Scope:** branch `deployment-spec` @ `6f18dbd7` (base `testnet-final` @ `75d16297`) — the full v2 ruleset: uncapped IBCO, dynamic post-IBCO curve scaling, dynamic fee, linear tickets, chosen-art predeposit, pull-based referral rewards.
**Method:** orchestrator solo deep pass (all 12 changed src files line-reviewed) + 4 adversarial fresh-eyes lanes (economics / NFT-collisions / fee-theft / lifecycle) + full gates + deep fuzz. Lane reports in this directory.
**Verdict: NO Critical / NO High. 2 Medium (both deploy-gated config/procedure hazards, not permissionless exploits). 5 Low. Economic core sound — dynamic fee provably un-arbitrageable, P1/P2 custody held under ~50k adversarial oracle points.**

## Executive summary

The v2 redesign is mathematically and economically sound. The dynamic fee cannot be arbitraged (two-sided multiplicative fees ≥ 4.9%/round-trip dominate any ≤750bps differential; schedule provably monotone, continuous at both boundaries, rounding always reserve-favoring). ticketPrice is monotone, snapshot-anchored, and un-suppressible (pot never decreases pre-Flat; units computed before the fee that feeds the pot). The clock is cap-before-multiply clean to 3.4e22 units, irreversible, and halt-gated before any state change. The referral escrow is hook-authenticated with exact-sum pre-funding and an outstanding-balance invariant. The NFT reservation lattice is single-assignment sound with O(1) run-boundary frontiers. Both Mediums are configuration/procedure hazards that a malicious actor cannot reach without the owner key or a docs-ignored misdeployment.

## Findings

### MEDIUM

**M-1 (Lane L) — vest slot 1..5s in a hand-assembled timing word permanently strands the entire predeposit pool.**
`RoundController` rejects only ZERO timing slots; `VEST_DURATION ∈ [1,5]` passes, makes `PSPStaker.epochSize() = VEST/6 = 0`, and every `launchPooledBuy` panics 0x11 at `lockGenesis`. No abort, no refund, immutable slot → pool stranded forever. Guard is pack-time-only (`packTimings` enforces `%6==0`); the factory constructor takes raw words.
**Fix (one line):** reject `VEST_DURATION < 6` next to the zero check. Until then, spec must mandate `packTimingsCapped` as the only legal input path.

**M-2 (Lane N) — v2 descriptor set on a v1-era factory silently mints visually duplicate "unique" Pepes.**
`setDescriptor` has no version cross-check; an old factory's staker vessel immutably embeds the v1 fold. On the five widened axes (12/12/11/11/11) nibble pairs collide under v2 rendering but pass v1 key checks (grind ≈ 2^24–2^30 hashes). Permanent, silent, market-integrity impact. Only enforcement today is the EXPANDED.md docs sentence.
**Fix:** runbook rule (already written) + never touch the Sept 9 factory's descriptor; optional on-chain `ART_VERSION` expectation check at `setDescriptor` for future factories.

### LOW

- **E-1 — dust-boot rounds.** (a) net boot < ~143 wei (default params) → `lam == 0` → launch never succeeds; deposits never close, so recovery is top-up-only (anyone can heal it). (b) boot = 1 wei *materializes* (q0 = 43,012): the round launches into a zombie curve with ~97,600 wei total PSP; first ≥MIN_BUY buy saturates supply, all later buys revert `ZeroOutput` forever; sells still work; P1/P2 hold. The buyer overpays catastrophically (self-harm). Suggest a minimum-viable-boot gate (`lam >= MIN_BUY_INPUT`) or extend `_validateBootstrap` below 450e18.
- **E-2 — raw-library slice quantization (contained).** `sellOut(supplyAt(R)−supplyAt(R−s)) > s` in 43% of raw fuzz points (plateau snapping where p > 1), but hook haircuts (5,389/5,389 round trips strictly losing) + sell spot clamp + buy-side horizon death fully contain it; real-scale worst excess 1.5e-10 relative. No action.
- **F-L2 — router hookData stripping degrades referral leg.** Raw-PM/aggregator volume trades unattributed → the 5% leg becomes 4% pot + 1% deployer rake. Not theft; document "trade via buyWithMix/zaps to keep attribution".
- **L-L1 — no pre-launch refund path.** Deposits are recoverable only by growing the pool to a launchable state (ties into E-1). Design-accepted; document.
- **L-L2 — deposits stay open until launch executes** (window end = launch-eligibility, not deposit closure). A whale can front-run the launch tx and join pro-rata. Inherent to uncapped pooled IBCO; UI/spec language should stop calling it a hard deadline.

### INFO (selected)

- **L-1 (inherited, `setHook` re-point) — regraded defense-in-depth.** Lane L proved it unreachable on current bytecode (controller owner = factory contract; factory calls `setHook` only in `_birthWire`; no forwarding path exists). The audit-map's "fix before mainnet" stands as cheap hardening, not an open exploit.
- **L-I1 — the "owner early-launch bypass" is dead code** (factory never calls `launchPooledBuy`): nobody at all can launch before the window ends. Docstring bug.
- **E-3/E-4/E-5/E-6 — economic character notes:** chunked buys save ~2nd-order fee (chunk buys, never sells); one holder can sustain the clock indefinitely at ~0.156 mixETH/day minimum burn; buy side hits the inverse-price wall at ~20 waves (~6.7× target; sells stay open beyond); MIN_BUY buys stop earning time/seats after the first qualifying trade.
- **F-I* — registry donations strand (cannot enable anything); pot floor dust and deployer-credit trigger are benign; `claimFeesTo` operator redirection is standard ERC-721 trust; vessel nonce-CREATE spam is harmless.**
- **L-I3 — owner-only ordering hazards** (active-genesis reservation at detonation; out-of-band `deployRound` strands old carry): tolerated by design, spec-worthy.
- **E-1 vs L-L1 discrepancy:** lane E's parenthetical "funds remain claimable via predeposit withdrawal" is WRONG per lane L's exhaustive exit census (no such function; `sweep` is token-protected pre-launch). Deferred to L.

## Gates run

- `forge build && forge test` — **583 passed / 1 failed / 3 skipped** (the 1 = documented `WNS_FORK_RPC_URL` infra-fail). NOTE: the branch as pushed DID NOT COMPILE — `test/audit/testnet-final/SineCustodyInvariants.t.sol` still destructured v1 field names (`preK`/`slope`). Migrated by the auditor (test-only change, field renames, order unchanged) so the P1/P2 machine proofs run against v2 math. **The GATE-LOG/569-test claims on this branch predate the SineMath rename and were not reproducible at tip.**
- Deep fuzz: P1/P2 custody invariants 4/4 @2000 runs (incl. whole-balance sell, sliding-fee boundary custody); SineScaling 7/7, UncappedCapacity 7/7, ReferralRewards 12/12 @2000 runs.
- `make slither` — **0 High / 0 Medium** (242 informational, baseline profile).
- `check-no-governance.sh` — clean.
- Test-integrity grep: view-mock drift grew beyond the documented baseline (ChosenPredepositPepe failure-injection `mockCallRevert` on `sendFees`; ExpandedPepeArt controller view mocks). No token-fake success mocks found.

## Attack hypotheses REFUTED (evidence in lane reports)

1. Dynamic-fee round-trip extraction (measured: −19.01%/−12.12%/−4.947% at boot/mid/target)
2. ticketPrice suppression or early/late ticket arbitrage (pot monotone; snapshot-anchored; self-trade inflates own ticketPrice: 2000→1972 units over 6 cycles)
3. Self-trade loop minting clock time free (loses 1.9008 mixETH per 10-mixETH cycle)
4. Clock overflow / early detonation pull (property-tested to 3.4e22 units; detonationAt monotone)
5. Spot clamps overpaying sellers or breaking P2 (oracle: P1/P2 hold on every path, 1-wei→1e37 boots)
6. Fee-split dust inversion / sixth destination / registry underflow / cross-function reentrancy (all refuted with citations)
7. Reservation theft / double-consumption / duplicate art within a matched-codec round / `_nextArtKey` DoS
8. Early launch / window-delay grief / successor mis-birth / mid-window flavor flip (single-gate census; context-hash pinning)

## Required actions before mainnet

1. **M-1 one-liner** (`VEST_DURATION < 6` reject) — code fix.
2. **M-2 runbook** — fresh-factory rule for any art-version bump (already in EXPANDED.md; enforce procedurally).
3. Commit the invariant-suite migration (done in this audit's tree) so the branch compiles and P1/P2 proofs gate v2.
4. Spec language: "window over = launchable" not "deposits closed"; dust-band behavior; chunked-buy note.

*Audited tree includes the test-harness migration only; zero src/ changes made by this audit.*

## Resolutions (2026-09-14, scoopy-reviewed)

1. **M-1 — FIXED in code.** `RoundController` constructor now rejects `VEST_DURATION < 6` (`TimingsIncomplete`, subsumes the zero check) at the slot's decode site — guards every deployment path incl. direct vessel births. Regression test `test_C3_RejectsSubEpochalVest` (C3_Lifecycle.t.sol): hand-assembled words with vest slots 1–5s each revert at decode and never deploy; vest=6 boundary deploys with `VEST_DURATION()==6`. Pre-fix reachability re-verified: `roundTimings` is immutable, written once in the factory constructor, no setter — deploy-config was the only entry. No bubble-up: only in-repo vest values are 28d default + 1200/1201s tests; EIP-170 headroom unchanged (RoundController 12.8kB / 24.6kB).
2. **M-2 — ACCEPTED with procedural mitigation (scoopy decision).** One eternal factory; the Sept 9 factory's descriptor is never touched; any future art-version bump ships as a wholly new version alongside, never a `setDescriptor` on the old factory. Residual cross-round product surface (distinct from M-2): chosen-ID art is round-INdependent (`dna = keccak(id)`, unsalted) so a past round's #id is re-mintable byte-identical in any later round; genesis wallet art is round-salted (never repeats); the fallback frontier restarts at key 1 each round (rare). Mitigation: canonical frontend soft-locks folded DNA KEYS (not raw ids — alias ids exist, ~2^24 grind) of previously minted pepes across all rounds. Indexable purely from on-chain per-round stakers; no backend. On-chain per-round uniqueness stands everywhere; global uniqueness is the canonical-UI's curated invariant — consistent with the unstoppable-dapp design (soft lock bypassable by direct contract calls and frontier mints; accepted).

