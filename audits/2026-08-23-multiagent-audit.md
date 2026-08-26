# Multi-Agent Audit — 2026-08-23 (curve-teeth + rebirth state)

Scope: full `src/` tree at commit state post-teeth-regen (Curve1 sawtooth / Curve2 sharkfin),
plus test integrity of the suite as of this date.

Method: evm-cortex multi-pass methodology, Pass 1 (three parallel lenses), Pass 2 (review
panel triage), Pass 3 (test-integrity greps + slither + boundary matrix). NOTE: subagent
spawn was unavailable this run (delegation transport 429 — model package missing); the
three lenses were executed sequentially by the orchestrating agent against the same
checklists, with the A-1 finding verified by an executable fork PoC rather than assertion.

## Findings

### A-1 (HIGH) — Referral attribution poisoning via forged hookData — **FIXED 2026-08-26**
**Where:** `CurveHook._payReferrals` (`src/CurveHook.sol`), `PSPReferralRegistry.recordFor`.
**Mechanics:** the hook is the registry's authorized recorder, but it decodes
`(trader, referrerNftId)` from V4 `swap()` hookData — bytes controlled by ANY caller of
`poolManager.swap` (a 30-line attacker contract), not just the canonical zaps. A qualified
attacker (needs only ≥1000 PSP locked) swaps directly with `hookData=(victim, attackerNft)`.
The hook then:
1. `recordFor(victim, attackerNft)` — consumes the victim's ONE-TIME lazy attribution,
2. pays the 50bps carve-out of the attacker's own trade into the freshly-poisoned chain
   (mostly back to the attacker — cost ≈ 0).

From then on every trade the victim makes via the canonical zap pays the attacker's chain
(tier-1 80% of the carve-out). The victim cannot rebind (per-round first-bind-wins).

The registry's own docstring (lines 110-115) considered only a MALICIOUS RECORDER burning
its own users' attribution ("a malicious router can already steal from its users") — it
misses that the LEGITIMATE hook performs the poisoned record when fed forged bytes by a
third party. No zap compromise is required.

**PoC:** `test/integration/PoisonedAttribution.t.sol` (mainnet fork; pre-fix it PASSED
proving the hijack).

**Remediation (2026-08-26, recommended fix applied):** lazy recording is GONE from the
hook — attribution binds exclusively via the user-signed `registry.record(refNft)`
(msg.sender). Concretely:
- `CurveHook` decodes a 32-byte `(trader)` hint from hookData purely for payout
  continuation; the `recordFor` call path no longer exists. Forged 64-byte payloads are
  length-mismatched and ignored wholesale.
- `PSPReferralRegistry` is now fully permissionless: `recordFor`, `setRecorder`,
  `authorizedRecorders`, `owner`, `NotAuthorized`, `NotOwner`, `RecorderAuthorized` and
  the dead `StakerUpdated` event are deleted. Constructor slims to `(staker, minStake)`.
- Zaps (`PSPZapIn`/`PSPZapOut`) drop the `referrerNftId` parameter entirely (pre-deploy,
  clean break; the frontend never referenced it) and encode only the trader identity.
- Unattributed traders' carve-out still defaults to stakers (D6), unchanged.
- UX note: binding is no longer order-sensitive — a trader can record any time; trades
  before the record simply pay stakers (nothing is consumed by trading).

**Regression proof:** `PoisonedAttribution.t.sol` flipped to `test_PoC_ForgedHookDataCannotStealAttribution`
(same fork, same attacker contract, byte-identical forged payload): forged swap binds
nothing (`attributed(bob)` stays false), attacker earns exactly nothing (balance pinned),
victim still binds his intended referrer afterwards and tier-1 pays HER, not the attacker.
`Referral.t.sol` R1/R2/R6 rewritten to the explicit-record semantics.

### Reviewed-and-clean (Pass A/B/C)
- CEI/access: controller privileged fns all `onlyHook`; factory wiring owner-gated;
  create2 probe-then-deploy race-free with post-verify; minimal-ERC721 staker has no
  receiver-callback surface; `zapOut` ETH forward is pull-pattern.
- Math: CurveMath buy path conservative at every step (Newton + 3-pass clamp + 32-pass
  divWad shave + 1-wei + 1bps haircuts); telescoping antiderivatives (B4j) hold for both
  zone kinds; `validate()` enforces exp-first, contiguity, log k ≤ 1e18, exp k·w ≤ 7e18,
  unbounded tail. Teeth zones (Curve1/2) verified mechanically by the generator
  (anchors 4/4 ≤ 2e-6 rel, forge-vs-float dev 6.65e-10, monotone).
- Governance: quorum denominator = max(locked, supply) snapshot at propose (G-1) + M-1
  lockTime guard + 3d public flat window → NK24 dust-drain pattern mitigated by design
  (carry continuity, not theft).
- Slither (74 contracts, 100 detectors, 441 results): zero reentrancy / unprotected /
  dangerous-send findings in src/; remaining items are LOW style (unchecked bool on a
  self-mint transfer in `launchPooledBuy`, naming on generated curves, cosmetic
  inheritance).
- Test integrity: 0 `vm.mockCall`/`vm.expectCall` outside mocks (one doc-comment grep
  hit); absolute `vm.warp` uses are fork-genesis setups only; no `assertTrue(true)`.

### Notes (INFO)
- Genesis claimout can strand a few wei in the controller's virtual position (per-claim
  truncation, non-extractable dust — L-4 family; documented in LongitudinalLifecycle).
- `lockWithPepe` chosen ids are frontrunnable (art squatting — griefing only; dna is
  keccak(id), pick another).
- Husk-merge transfer burns the SENDER's pepe id (documented D9 design).

## New longitudinal coverage (this audit's deliverable)
`test/integration/LongitudinalLifecycle.t.sol` — 8 users, 2 full rounds, ~4 months
simulated: genesis → hatch → 10-epoch trading era (referral flow, rolling fee claims) →
lock expiry/relock/top-up → carpet governance → flat window → finalize + rebirth with
carry → round-2 life. Asserts global mixETH conservation and PSP accounting after every
phase, including round-2 custody (carry parks at the round-2 CONTROLLER pre-launch).
Focused tests: fee-fairness across staggered joins (per-PSP stream-window convergence),
102-cycle buy/sell chains (conservation + no-free-round-trip), rebirth carry exactness
(full-balance drain, boot = curve(carry) exactly).
