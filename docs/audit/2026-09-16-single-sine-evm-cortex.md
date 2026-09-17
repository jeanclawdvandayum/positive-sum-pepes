# EVM-CORTEX AUDIT — Positive Sum Pepes, `single-sine-spec` @ d0e5507b

**Date:** 2026-09-16 · **Requested:** scoopy ("full audit on the single sine spec, verify every finding with a poc, dont fix just report")
**Target:** `~/clawd/positive-sum-pepes` branch `single-sine-spec`, tip `d0e5507b` (in sync with origin), clean tree.
**Surface:** diff vs `deployment-spec` = 17 src files, +1079/−117. New v3 core (SineV3Primitive 286L, SineV3Price 205L, SineV3Math 131L, SineV3Bernstein/DataInfo/Data, ISineV3Math) + CurveHook v3 integration (+195) + factory/controller/reinvestor/zaps/referral fixes.
**Method:** evm-cortex multi-pass (CEI/access, math/economic incl. §5.5 boundary-value lens, static+integration), line-by-line read of the entire v3 core + full CurveHook diff, slither (287 raw → triaged), fix-regression review of all 8 AUD-V3 findings from the Sept-15 external review, and **6 new adversarial integration PoCs through real V4** (`test/SineV3AuditPoC.t.sol`, **6/6 PASS**). Report-only: nothing in src/ touched, nothing committed.

## Verdict

**No new exploitable findings on the v3 surface.** Every attack I ran held. The Sept-15 repair battery (114 v3 tests: adjacent-wei monotone fuzzes at two scales, mechanical boundary tables `test_AllBoundaries_*`/`AllControls_*` covering the full 4938-knot domain, inverse bracket-closure at waves 0→4096, data-shard reorder/dup/one-byte integrity, one-wei allocation conservation, round-trip-never-wins fuzz through real V4) plus my six new probes give the branch the strongest evidence state it has had.

## PoC results (TIER 1 — real local V4, real table, real hook)

| ID | Property attacked | Result |
|----|-------------------|--------|
| T1 | `getBuyOutput` quote == execution output for identical inputs (4 sizes); revert parity below-min (SwapTooSmall both paths) | **HELD** (exact equality) |
| T2 | `getSellOutput` quote == execution (incl. fee slice); `SellExceedsSupply` parity at whole-supply sell | **HELD** |
| T3 | TicketPriceMoved guard end-to-end: rival fee event reprices pot → stale guard trips (WrappedError); tight guard (== current tp) never trips on own fee | **HELD** |
| T4 | Pre-fee sampling: buy of exactly one spot = exactly one clock unit (69s), own fee reprices only LATER buyers | **HELD** |
| T5 | Current ladder spot is the binding buy min: tp−1 reverts, tp passes | **HELD** |
| T6 | Sell-side dust guard intact on sine rounds: MIN_SWAP_INPUT−1 reverts, MIN passes (buy-side exemption is asymmetric by design and always dominated by the tp floor) | **HELD** |

Note: T1/T2 close a real coverage gap — the V3-INT-3/V3-INT-5 quote fixes (getBuyOutput/getSellOutput) had **zero direct tests** despite being modified this branch. The PoC file pins them now; committing it moves the forge gate 715 → 721 (your call — it's untracked, per the stand-down discipline).

## Core-math review (line-by-line, no findings)

- **SineV3Primitive**: constructor codehash+length-pins all 4 shards and the phase-table endpoints; `_knot` STOP-prefix reads verified against shard boundaries; `_prepare` enforces runtime coefficient positivity (`SineV3Coefficient` on ≤0) so malformed data fails closed rather than mispricing; de Casteljau runs 16 levels + fused final degree-1 lerp (the `gap` term) — standard evaluation, floor-ordered throughout; inverse (`_reserveAtPrimitive`) = knot binary-search → strict bracket → ≤16 capped Newton steps (adjacent-wei plateau probing, slope from the degree-1 gap) → forced bisection ≤128 total → **minimality proof** (`F(upper) ≥ target`, `F(upper−1) < target`, else revert). The 2^81 cell-width vs 112-bisection-budget bound holds for the factory domain and fails closed outside.
- **SineV3Price**: `phaseAt` (two ordered Bernstein quarters + reflection), `exponentAtPhase` (exact floored cbrt − integer constant), `scaledExp` (range-reduced positive-coefficient degree-20 Horner at 1e36, k-shift with explicit overflow guards both directions). Every stage order-preserving; guards at each conversion (`MAX_PHASE_MAGNITUDE`, `max/1e36 − WAD`, `max>>shift` checks). `unchecked` blocks carry argued bounds (max product ~1e45 vs 2^256).
- **SineV3Math**: `_checkDomain` chains the derived bounds (boot ≤682e6·e18, lam == lamAt(boot), −580.5-wave coverage `2·boot ≤ 1161·lam`, R ≤ boot+4096·lam, price(0) > 0); buyOut spot-bound + 1-wei + 1bp haircut; sellOut early-return unreachable from execution (verified: `_handleSell` line 614 + quote line 1050 both enforce `< totalSupplyPSP` before the `>= qNow` branch could trigger).
- **Factory/controller**: immutable table pin with code-check at construction; contextHash now binds (gameSinePL, sineV3Table) across rebirth; Q≥D admission re-runs the exact genesis calc and both `_validateBootstrap` denominators match their documented share semantics (bonus path excludes the bonus; deposit path includes the new amount — read both call sites).

## Slither triage (287 → 0 new v3-surface positives)

- `arbitrary-send-erc20` (ReferralRegistry:236): the A-1 approved-zap pattern, pre-existing, unchanged this branch — cleared.
- `arbitrary-send-eth` (PSPZapOut:83): sends to `msg.sender` (user's own proceeds) — cleared.
- `uninitialized-state` (PSPStaker.biasAdd): pre-existing staker (untouched this branch), always-0 bias is the designed ve-queue simplification — carry-over INFO.
- `return-bomb` (detonate factory call): trusted callee, gas-capped — cleared.
- `divide-before-multiply` ×4: all intentional decompositions (phase reconstruction, legacy ticket growth, vesting decay, whole-unit flooring).
- `missing-zero-check` ×4, `dead-code`, `locked-ether`: pre-existing LOW/INFO hygiene (factory.setDescriptor / name-gate signer can be zeroed by owner; ControllerDeployer dust) — unchanged by this branch.

## Residuals / notes (report-only)

1. **N-1 (INFO)**: Quote coverage gap (now pinned by T1/T2, uncommitted).
2. **N-2 (INFO)**: Same-block launch + first buy cannot extend the clock (armed at now+72h, cap absorbs it) — pinned in T4; intended behavior worth a doc line in CLOCK-REDESIGN if not already there.
3. **N-3 (LOW, pre-existing)**: `sineV3Table` trust chain is factory-constructor-level (`code.length != 0`), not a codehash pin in the hook; the real table self-authenticates its shards, so the residual is "deploy script + factory constructor honesty" — matches the existing deploy-verification workflow (byte-identity receipts), note only.
4. **N-4 (INFO, pre-existing)**: slither hygiene items above (owner-zeroable descriptor/signer setters, `_anchorNow` dead code) — candidates for a cleanup commit, nothing v3.

## Addendum — rebased onto the reviewer's 471b0443

After this audit (against d0e5507b), the external reviewer pushed `471b0443`
("Fix pre-launch minimum and rehearsal tooling"): `ticketPrice()` now gates
whole-pot pricing on `poolInitialized && sineConfigured`, so the PRE-LAUNCH
minimum is the legacy 0.005 floor instead of a 1-wei degenerate seed (release
spec: tickets start at 0.005). My audit's T-series all run post-launch where
behavior is unchanged; all 6 PoCs were re-run and re-verified against 471b0443
before this report was pushed. Honest coverage note: the pre-launch
`ticketPrice()` window was NOT in my attack surface — the reviewer caught it.

## Plamen leg: still BLOCKED

Claude Code OAuth expired 2026-08-16; refresh endpoint persistently 429s (6 attempts over ~2h). One interactive `claude` login revives it; then `cd ~/clawd/positive-sum-pepes && claude -p "/plamen thorough" --dangerously-skip-permissions` can run against d0e5507b on your word.

## Artifacts

- `test/SineV3AuditPoC.t.sol` — 6/6 PASS (~35s; includes a GuardedSwapper with the 64-byte guarded route and a proper exact-input sell leg)
- `/tmp/psp-slither-v3.json` — full detector dump
- Full-suite green check with the PoC file included: running at report time (expect 721/72→73 suites); no src, gate, or tracked-file changes.
