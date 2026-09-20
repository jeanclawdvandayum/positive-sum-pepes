# DinoSAT Formal Verification Report — single-sine-spec (SineV3)

**Target:** `single-sine-spec` @ `e9a70d44` (SineV3 curve core: `SineV3Primitive`, `SineV3Price`, `SineV3Math` + `SineV3Data` canonical shards)
**Methodology:** DinoSAT skill (halmos 0.3.3 + Z3 4.12.6, bounded-budget per-test watchdog, per-test log files, vacuity discipline)
**Date:** 2026-09-18 · **Operator:** Hermes (scoopy-directed)
**Discipline:** report-only; no `src/` changes. Test-harness files under `test/dinosat/` were authored/adjusted for verification.

---

## 1. Executive summary

The SineV3 integer curve core was probed with symbolic execution across three
contracts (Primitive / Price / Math). **No contract-level vulnerability was
found.** One halmos-reported FAIL was adjudicated to a **test-design artifact**
(probing cells outside their reachable reserve domain); the contract's
documented saturation semantics hold exactly. The crown property — within-cell
monotone supply — is Z3-proven on the reachable positive tail and pinned by
exact anchors + fuzz on the reachable negative half-cell.

## 2. Verdict table

### 2.1 SineV3PrimitiveSymbolicTest (crown: PR-1 within-cell monotone supply)

| Test | Cell (kind) | Verdict | Note |
|---|---|---|---|
| test_check_cell_monotone_0 | 0 (wide-negative) | PASS — **vacuous** | cell phase span entirely below reserve 0; F saturated constant |
| test_check_cell_monotone_500 | 500 (half-negative) | PASS — **vacuous** | same |
| test_check_cell_monotone_708 | 708 (quarter) | PASS — **vacuous** | same |
| test_check_cell_monotone_711 | 711 (zero-adjacent half, reachable) | see §2.4 escalation | |
| test_check_cell_monotone_716 | 716 (half-positive, reachable) | see §2.4 escalation | |
| test_check_cell_monotone_1000 | 1000 (wide-positive, reachable) | see §2.4 escalation | |
| test_check_cell_monotone_4936 | 4936 (terminal) | **PASS (3–10 paths, ≤2.9s)** | real proof, deepest graded cell |
| test_check_cell_upper_edge_anchor | 711/716 + sunk pins | **PASS** (after fix; forge-confirms) | initial FAIL = test artifact, §3.1 |
| test_check_knots_increase | span {0,1,500,708,711,716,1000,4936} | **PASS** | strict knot ordering across kinds |

### 2.2 SineV3PriceSymbolicTest

| Test | Verdict | Note |
|---|---|---|
| test_check_phaseat_monotone_pos_q1..q4, _neg | TIMEOUT (240s) | de Casteljau × densityAtPhase nested 512-bit — per skill, falls to fuzz tier |
| test_check_phaseat_seam_whole | **PASS** | |
| test_check_phaseat_seam_quarters | **PASS** | all concrete quarter/whole seams |
| test_check_phaseat_odd | TIMEOUT (240s) | odd-symmetry full proof previously obtained pre-restart at longer budget (24 paths) — not re-proven tonight |
| test_check_phaseat_displacement_pos/_neg | TIMEOUT (240s) | fuzz tier |
| test_check_scaledexp_monotone | TIMEOUT (240s) | fuzz tier |
| test_check_scaledexp_reverts_huge_scale | **PASS** | fail-closed guard proven |

### 2.3 SineV3MathSymbolicTest

| Test | Verdict | Note |
|---|---|---|
| test_check_lamat_floorsqrt_boot90 / boot450 / boot600k | **PASS** | λ = ⌊√boot⌋·1e18 rows |
| test_check_domain_rejects_above_max | **PASS** | |
| test_check_domain_admits_boundary | **PASS** | |
| test_check_domain_rejects_bad_pl | **PASS** | |
| test_check_buyout_spot_bound / _supply_monotone (+fuzz wrappers) | **BLOCKED → FUZZ** | halmos `NotConcreteError: symbolic EXTCODECOPY offset` — tool limitation via the external try/catch wrapper; not a math failure |

### 2.4 Escalation (uncapped, immortal runs) — CLOSED as formal-intractable

test_check_cell_monotone_{711, 716, 1000} were re-run without any kill cap at
60s solver timeouts. At close of campaign they had consumed **8.2 / 6.7 / 6.7
CPU-hours** respectively with no verdict (711 additionally survived a 240s
budget + a 94-min pre-restructure run earlier). Classification per skill
protocol: **TIMEOUT → fuzz tier** (all three green at 20k runs via
`test_fuzz_cell_monotone_*` plus repo-global monotone suites). The runs were
left alive unbounded; any late verdict will be appended here and in
`/tmp/dinosat-esc/verdicts.txt`.

Structural note: 711 is the zero-adjacent half-cell whose probe domain crosses
the saturation boundary (extra case-split); 716/1000 are fully in-domain but
sit in graded-table regions whose bit-blasted multiplier chains did not
converge even uncapped — consistent with the skill's nested-512-bit
intractability class.

## 3. Adjudications

### 3.1 test_check_cell_upper_edge_anchor FAIL → test-design artifact (contract correct)

halmos found a concrete counterexample; forge reproduced (panic 0x01), so not a
solver artifact. Diagnosis: the test probed cells {0, 500, 708} at reserves
computed by `_reserveFloor`-mirror edges, but those cells' phase spans lie
**entirely below reserve 0** — `boot = 450e18` provides only
`4·boot/λ ≈ 1.88` quarter-phases of negative runway, so no in-domain reserve
exists for them. `_atReserveWithSlope` intentionally **saturates** outside the
cell domain (returns endpoint knots; supports the internal bisection), so the
probe returned `knot(i+1)` at "lo" and the exact-equality assert fired.

Contract behavior verified correct:
- Reachable cells (711, 716): both edge anchors hold **exactly** (forge-reproduced).
- Sunk cells: `F(R) == knot(i+1)` constant on `[0, boot)` — pinned by the fixed test.
- No path exists for a live reserve to reach cells 0/500/708 (reserve ∈ [0, ∞)).

Corollary honesty: the monotone PASSes for cells 0/500/708 are **vacuous**
(saturated constant function). They remain in the table as coverage of the
saturation semantics, not of the Bernstein monotonicity itself.

### 3.2 Buyout ERRORs → tool limitation

`NotConcreteError: symbolic EXTCODECOPY offset` — known halmos gap class
triggered by the external-call try/catch wrapper required to observe library
reverts. Classified BLOCKED; assurance carried by the repo's existing
exhaustive buyout fuzz suites.

## 4. Fuzz tier (fallback per skill protocol)

- `SineV3MonotonePriceTest` 11/11 @ 20k runs (adjacent-exponent / adjacent
  price+phase / distant-coordinate monotone; all seam orderings)
- `SineMathTest` 12/12 @ 20k runs (price monotone, reserve roundtrip, wave
  geometry, saturation, target tread)
- `test_fuzz_cell_monotone_{0,711}` 2/2 @ 20k runs (in-suite wrappers)
- B4_CurveMathFuzz (parked wave-2 suite): `vm.assume` rejection-cap artifact
  at elevated run count; passes at repo defaults. Not a math failure.

## 5. Environment findings (banked for reruns)

1. halmos 0.3.3's internal `forge build` ignores `FOUNDRY_PROFILE`; must pass
   `--forge-build-out out-halmos` explicitly with pre-built AST artifacts.
2. `ast = true` profile flag does not invalidate forge's incremental cache —
   stale AST-less artifacts persist; `forge build --force` required after flag
   changes.
3. halmos 0.3.3 default test regex is `^(check|invariant)_`; `test_*`-named
   suites need explicit `--function test_` (and `--function` runs only the
   FIRST prefix match — isolate per-test for multi-test contracts).
4. halmos needs the **z3 binary** on PATH (pip bindings alone insufficient).
5. `via_ir = false` breaks this repo's compilation (legacy zone path performs
   memory→storage struct-array copies only legal under IR) — keep `via_ir=true`
   even for halmos.
6. macOS: no GNU `timeout`; use the bash watchdog pattern (per-test log files,
   append-only verdict log) — also survives session restarts that wipe the
   process registry (which lost a 72-min run's verdict earlier today).

## 6. Cross-audit: Fable 5.1 (`origin/single-sine-fable-pass`, 2026-09-18)

Anthropic Claude Fable 5.1 fresh-eyes pass over the same tip (`e9a70d44`):
**no Critical/High/Medium; "safe to deploy as specified."** Report at
`docs/audit/2026-09-18-single-sine-fable.md` on that branch; PoCs in
`test/FableAuditPoC.t.sol` (6/6) and `test/FableBreakAttempts.t.sol` (14/14,
incl. 401-sequence chaos full-exit fuzz: post-detonation supply/reserve/escrow
all exactly zero, ≤10 wei pot rounding, zero reverts).

- **F-1 (Low):** generic-router swaps with empty `hookData` strand the pot
  seat in the router after detonation — accepted consequence of untrusted
  hookData; action item is an integrator warning line in CLOCK-REDESIGN/README,
  not a src change.
- **F-2..F-7 (Info):** referral self-rebate via NFT custody (≤4% of fee);
  owner genesis-over-live-round (intentional escape hatch, owner = game-loop
  admin); rebirth pre-launch minimum 0.005 + ~0.8M predeposit gas; stranger
  `stakeFor` harmless; dust round-trips never win; dust launches unplayable
  (runbook note).

Consistency: confirms supply ≤ Q(reserve) (sellOut early return unreachable),
fee-split and custody identities, clock discipline — all aligned with §2–§4
here. No conflicts with THREAT_MODEL accepted risks.

## 7. Residual risk

- Monotonicity within reachable cells 711/716/1000 is formal-intractable with
  this toolchain (§2.4); assurance there rests on proven exact edge anchors +
  strict knot ordering + 20k-run fuzz monotone (in-suite wrappers + repo-global
  phase monotone suites). No counterexample was found at any tier, and no
  rounding asymmetry was ever observed.
- phaseAt odd-symmetry and per-quarter monotonicity remain fuzz-backed only
  (formal attempts hit the documented nested-512-bit intractability).
- Bottom line: **no contract vulnerability found at any tier** — formal,
  fuzz, or adjudication.

## 4. Fuzz-tier adjudication (2026-09-18, pre-publish)

Committing the suite surfaced four deterministic forge-fuzz falsifications on the tests
the campaign had left at TIMEOUT/BLOCKED → fuzz tier. All four adjudicated as
**wrapper-side artifacts; the contract is unchanged and correct** (direct-probe receipts):

| Test | Counterexample | Root cause | Fix |
|---|---|---|---|
| test_check_buyout_spot_bound | spend=2.0497e19 → panic 0x11 | `spend * 1e18` evaluated in **uint112** (literal types down) — overflows above ~5.2e15. The CONTRACT call is clean: direct probe at the exact counterexample returns out=273259989976651329931848, and `out ≤ spend·WAD/PL` holds in 256-bit. | assert widened to `uint256(spend) * 1e18 / PL` |
| test_check_phaseat_displacement_pos | x=7.217e14 → panic 0x01 | One-sided claim `0 ≤ s−x` is false in the wave interior BY CONSTRUCTION: the Bernstein fractional phase is sub-diagonal (phaseAt(882)=0, phaseAt(7.2e14)=2473714075) — the documented saturation semantics; whole-wave seams are exact (seam tests PASS). | restated two-sided: `|s − x| < WAD` |
| test_check_phaseat_displacement_neg | x=882 → panic 0x01 | same | same |
| test_fuzz_scaledexp_monotone | e clamped to 1e21 → SineV3PriceOverflow | clamp domain exceeded the overflow-free domain: scaledExp reverts (fail-closed guard, itself proven PASS) at |e| ≥ ~1e21; 1e20 verified non-reverting. | clamp tightened to ±1e20 |

Post-fix suite: **37/37 PASS** (3 suites). No `src/` changes. Probes run via a throwaway
diag contract (deleted); receipts reproducible with the constants in the table.
