# Formal escalation campaign — September 22, 2026

Follow-up to the [September 21 assessment](2026-09-21-current-state.md) and
[FORMAL-VERIFICATION](FORMAL-VERIFICATION.md). Scope: the explicitly unresolved
EVM-tier properties — the two direct ticket properties, the phase/quarter
monotonicity towers, scaledExp monotonicity, the selected nonconstant cells,
and the EXTCODECOPY-blocked buyOut pair. No production contract changed.

## What was attempted

Budget and tool escalation against the pinned harness at `38222f7f` sources:

| Lever | Setting |
| --- | --- |
| Wall budget per property | 90 s → **1,800 s** |
| Solver budget per assertion | 20–30 s → **300 s** (probes to 1,800 s) |
| z3 parallelism | 1 thread → **8 threads** |
| Alternative engines | **bitwuzla 0.8.1, cvc5 1.2.1, yices 2.6.4** (halmos-native downloads) |
| Spec re-engineering | addition-form comparisons + wrap guard (see below) |
| Isolation diagnostics | minimal throwaway contract, no hook, no storage (deleted; logs kept) |

## Root-cause analysis (with receipts)

1. **The old `pot - lower <= 10_000` spec compiles into a symbolic-divisor
   division.** solc 0.8.26 via-IR lowers subtraction-under-comparison into a
   division trick; the saved query (halmos writes timed-out SMT2 queries to
   `$TMPDIR`) contains `(bvmul 10000 d)`-style numerators divided by
   `(bvadd -1 d)` — **bvudiv with a symbolic divisor**. That query shape is
   intractable for every engine tested.
2. **The addition-form respec eliminates symbolic divisors but stays
   intractable.** The v2 query set divides only by the constant 10,000, yet
   still exhausts 1,800 s. The residual hardness is *relational*: connecting
   `q = bvudiv(pot,10^4) + [rem≠0]` (through the etched production runtime's
   branch structure) against the spec's comparisons.
3. **The hardness is not the CurveHook path burden.** A minimal throwaway
   contract (ten-line ceiling implementation, no hook, no storage, no
   fixture) still times out on both the identity-form and product-form
   specs at 60 s/query. The blocker is the 256-bit relational div core
   itself.
4. **Per-query attribution:** bitwuzla closes 4 of the 5 assertion queries
   in ~1 s each; exactly one relational query per property consumes the
   entire budget. The failure is one monster query, not general slowness.
5. **No counterexample was produced by any engine at any budget** — the
   properties are consistent with all evidence (int-tier proofs, fuzz,
   concrete anchors); this is solver-capability, not bug, territory.

## What changed in the tree (test-side only)

- `HookRulesSymbolicTest.check_ticket_interval` — addition-form bucket
  ceiling with an explicit wrap guard for the top 10,000 pots; the original
  subtraction-form property is now pinned **exhaustively** over that wrap
  zone by `test_ticket_interval_top_region_exhaustive` (10,003 concrete
  calls on the etched runtime), plus the boundary seam one pot below.
- `HookRulesSymbolicTest.check_ticket_adjacent` — addition-form successor
  bound (`afterPrice <= beforePrice + 1`; `beforePrice` is bounded far
  below the wrap edge).
- `SineV3PrimitiveSymbolicTest` — cell **712** (the second launch quarter,
  phase4 1→2) added: symbolic check, Forge fuzz wrapper, reachable-cell
  edge anchors, and strict-knot list. Together with 711 this covers both
  graded cells the canonical buyOut launch-row properties read.
- `scripts/formal/run.py` — `check_cell_monotone_712` registered in
  EXTENDED.

## Closure by composition (unchanged tiers, now explicit)

- **Ticket interval / adjacent order:** full-domain integer-tier lemmas
  (Z3 ints, `prove_arithmetic.py`) + no-overflow bridge (the harness's own
  `q` bound documents the product safety) + exhaustive top-region concrete
  check + full-domain Forge fuzz. EVM-symbolic tier: **z3-family-intractable
  at 256-bit** — receipts above; four engines, two spec shapes, isolated
  diagnostic.
- **buyOut spot bound / supply monotone:** EVM-symbolic remains blocked
  (halmos 0.3.3 `NotConcreteError` on symbolic EXTCODECOPY offsets; the
  shard read offset derives from symbolic `spend`). Composition closure:
  per-cell monotone towers 711+712 (EVM) + exact shared-knot seams
  (concrete) + `_supply`'s monotone scaling + price-minimality chain
  (phase monotone → cbrt → scaledExp) + fuzz and the 81-sample validator.
- **Towers (phase/quarters, scaledExp, nonconstant cells):** unchanged —
  structural induction over ordered interpolation (arithmetic lemmas),
  all-cell coefficient validator, fuzz. 30-minute budgets do not close
  the unrolled ~342-op bitvector queries; recorded as such.

## Verdict table (v2 harness, 1,800 s wall / 300 s solver, z3)

| Property | Old (90 s) | This campaign |
| --- | --- | --- |
| check_ticket_interval | timeout | WALL_TIMEOUT ×2 specs (old + addition-form); 5 engines; minimal-diag repro; composition closure |
| check_ticket_adjacent | timeout | WALL_TIMEOUT (addition-form, zero products in spec); composition closure |
| check_phaseat_monotone_pos_q1 | timeout (60 s) | WALL_TIMEOUT at 1,800 s |
| check_phaseat_monotone_pos_q2 | timeout | WALL_TIMEOUT at 1,800 s |
| check_buyout_spot_bound | EXTCODECOPY-blocked | re-blocked identically on the v2 tree (fresh receipt) |
| check_buyout_supply_monotone | EXTCODECOPY-blocked | re-blocked identically on the v2 tree (fresh receipt) |
| Core suite (15) | green | 15/15 green — pinned-tool sanity intact |

Machine-readable records: `v2-run-partial-summary.json` (four wall-timeouts +
core), `aborted-first-run-summary.json` (first max-budget run),
`cell-712-shot-summary.json` (focused attempt: WALL_TIMEOUT at 1,800 s —
same tower class as 711/716/1000), per-probe logs, and the saved SMT2
queries under `smt2-*/` in this directory.

## What would actually close the EVM tier

- An integer-theory encoding of uint256 for these properties (upstream
  halmos feature request territory), or
- a solver that decides 256-bit relational div/mod queries, or
- width-reduced harness variants (EVM proof on `[0, 2^64)` + documented
  width-uniformity bridge) — offered, not applied: the int-tier lemma
  already covers the full semantics; the residual (compiler divergence on
  high-magnitude inputs only) is judged negligible for div/mod/add opcodes.

## Reproduction

```bash
.venv-formal/bin/python scripts/formal/run.py --extended --output <new-dir> --timeout 1800 --solver-timeout 300
# alternative engines (halmos downloads the pinned binaries):
HALMOS_ALLOW_DOWNLOAD=1 .venv-formal/bin/python -m halmos --contract HookRulesSymbolicTest \
  --match-test '^check_ticket_interval\(' --forge-build-out out-halmos --loop 64 \
  --solver bitwuzla --solver-timeout-assertion 300s --panic-error-codes '*' --no-status
```
