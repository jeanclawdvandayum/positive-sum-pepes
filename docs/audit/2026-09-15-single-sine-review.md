# Single-sine v3 review — September 15, 2026

**Decision: do not deploy this branch yet.** The intended price formula and
pot-based ticket rules are present. Two numerical properties still fail,
and the helper's fixed range does not meet the handoff's capacity requirement.
Local fixes address the other confirmed issues below.

This review covers `single-sine-spec` at `a80984c8` and the local fixes from
this review. No public deployment, publication, or live-address change took place.
Existing deployed contracts do not receive these fixes automatically.

## Results

| Severity | Findings | Fixed locally | Open |
| --- | ---: | ---: | ---: |
| High | 2 | 2 | 0 |
| Medium | 3 | 1 | 2 |
| Low | 3 | 3 | 0 |

The submitted source had two high-severity issues: a graveyard fee-claim
authorization defect and a sell inverse that could return a severe underpayment.
The remaining settlement defect has smaller measured errors, but it breaks an
explicit invariant needed by the inverse. Passing ordinary trade tests is not
enough to approve release.

## Scope and history

The original implementation prompt is the acceptance reference:
`docs/implementation-prompts/2026-09-14-single-sine-cuberoot-pot-tickets.md`.
The implementation's later edits to `FINAL-SPEC.md` do not authorize deviations
from that prompt.

The main curve range is `e8d24e4f..a80984c8`: four commits, 63 changed files,
3,958 added lines, and 531 removed lines. The broader range from the handoff
baseline, `6f18dbd7..a80984c8`, has 78 changed files. That range includes the
graveyard router, which predates the sine commits.

| Commit | Change relevant to this review |
| --- | --- |
| `1a2ee1dd` | Adds the graveyard router and operator withdrawal path |
| `512c6be2` | Adds the v3 helper, generated knots, ticket rules, and launch wiring |
| `0ff62ff5` | Migrates tests and changes the inverse seed |
| `c25f949b` | Adds ticket-price guards to purchase routes |
| `a80984c8` | Records deployment and lifecycle results |

The review used three parallel lanes: numerical settlement, contract and
deployment integration, and explanatory pages. The root review checked the
handoff, caller paths, fixes, gates, and browser layouts. Generated knots were
checked through their generator and independent fixtures. No line-coverage
percentage or complete audit of external dependencies is claimed.

## Findings

### AUD-V3-1 — Medium, open: rounded price and supply can decrease

Locations: `src/SineV3Math.sol:192`, `:212`, and `:230` for `_F`,
`_gl8Partial`, and `_exponentAt`.
These paths entered in `512c6be2`. Regressions are in
`test/SineV3ReviewRegression.t.sol`.

At the 500-mixETH calibration, use these integer inputs:

```text
boot = 450000000000000000000
lambda = 955000000000000000000
launch price = 75000000000000
reserve = 4986249999999999998089
Q(reserve)     = 17671194694734242672866666
Q(reserve + 1) = 17671194694734242660133333
```

One more reserve wei reduces cumulative supply by 12,733,333 PSP wei.
A supported 100,000-mixETH net launch produces another decrease of
189,817,326 PSP wei. At baseline reserve `16207499999999999999999`, one
additional wei reduces price from `613048911149785684` to
`613048911149785681`.

The partial integral is clamped between its cell endpoints. That clamp does
not make its interior values monotone. Its moving quadrature nodes and rounded
density evaluations can still produce a local decrease. The rounded sine,
root, and exponential composition also needs its own monotonicity argument.

These measured drops are small. This review did not prove a profitable
reserve-extraction sequence from them. However, the supply function no longer
satisfies the premise used by the sell inverse. Buy differences can also lose
their expected sign. The handoff explicitly requires both properties.

The original adjacent-wei test sampled only a few points for one launch size.
It missed these cases. The new three assertions deliberately remain failing.
Do not delete, skip, or reverse those assertions to restore a green gate.

Required repair: use an integer representation with a proof of monotonicity
and an independently measured error bound. One candidate is a generated
Bernstein primitive with ordered control points and monotone integer
interpolation. This requires a prototype, code-size checks, and gas checks.
Changing only the partial-cell clamp or the cube-root identity is insufficient.

### AUD-V3-2 — High, fixed locally: incomplete inverse severely underpays a sale

Location: `src/SineV3Math.sol:270`, `_reserveAt`. The v3 search accepted Newton
steps throughout its 128 iterations. An interior step need not halve the
bracket. The function returned its upper endpoint even when the search remained
far from complete.

The funded counterexample uses a tiny launch and reaches wave 63:

```text
gross IBCO = 1111111111111 mixETH wei
net boot   = 1000000000000 mixETH wei
lambda     = 45019131735543525 mixETH wei
gross buy  = 3151339221488046750 mixETH wei
reserve    = 2836206299339242075 mixETH wei
PSP sold   = 1000000000000 PSP wei
old gross output       =       5861800334 mixETH wei
closed-bracket output  = 1690898741711268 mixETH wei
```

The old output is more than 99.999% below the completed search result.
This sale meets the hook's sell minimum. The test builds the state through
real Uniswap v4 purchases, then checks the sale's exact net payment after fees.

The repair permits at most sixteen Newton steps, then forces bisection.
It rejects a bracket wider than one reserve wei at termination. The current
factory domain has reserves below `2^82` wei, so the remaining 112 iterations
are sufficient. Removing the equality shortcut also avoids choosing an
arbitrary point inside a fixed-point plateau.

Tests cover waves 32 and 63, wider arbitrary helper arguments, and the funded
v4 route. The repaired real-route sale uses 6,372,725 gas in the focused test.
This fixes search termination. A global inverse guarantee still depends on
resolving AUD-V3-1.

### AUD-V3-3 — Medium, open spec deviation: the table defines unapproved limits

Locations: `src/SineV3Math.sol:57`, `PRE_WAVES` and `POST_WAVES`, and
`src/RoundController.sol:390`, `BOOT_NET_MAX`. Added in `512c6be2`.

The helper stops at phase -16 before launch and +64 after launch. The
controller therefore limits net launch backing to about 518,841 mixETH.
Those are table limits, not demonstrated arithmetic limits of the formula.

For example, the independent Decimal formula gives about 2,134.038105
mixETH/PSP at phase 65. That price remains representable. At phase -17,
the default price is about `0.000000007990818561` mixETH/PSP, also above
one price wei. The current guards reject those coordinates because the table
ends earlier.

The handoff requires continued waves within justified numerical limits and
rejects an arbitrary fixed-wave cutoff. The branch's previous description of
these bounds as arithmetic capacity does not satisfy that requirement.

Keep the existing guards until the evaluator supports a wider range. Required
work is a bounded continuation and a derivation of limits for price, supply,
casts, intermediate values, gas, and launch allocation. Explicit user approval
would be required to adopt these limits as new economic rules instead.

### AUD-V3-5 — High, fixed locally: approved graveyard zap can redirect earned fees

Location: `src/PSPGraveZap.sol:61`, `exit`. Introduced in `1a2ee1dd`.
The public exit route accepted arbitrary NFT IDs without checking the caller's
ownership. Approval of the zap let it claim those IDs' fees to its caller.

Once an owner approved the zap, another wallet could request that owner's
exit with zero redemption. Earned fees went to the caller. Principal went to
the owner, so the withdrawal leg did not stop the transaction. With no earned
fees, the same omission still allowed an unwanted withdrawal.

The fix checks `ownerOf(id) == msg.sender` for every requested position before
any exit leg. Tests cover collection approval, individual approval, fee
retention, principal retention, and a later successful owner exit. The nine
GraveZap tests pass. The original stranger test lacked the owner's zap approval
and therefore tested a different guard.

This issue lies outside the four sine commits but inside the requested local
branch review. The reinvestor's existing caller authorization does not share it.

### AUD-V3-6 — Medium, fixed locally: deployment tools still require v2

The deployment runner exported retired sine settings, which the new Solidity
script rejects. The manifest called removed `sineParams()`, required v2,
and required a fixed 0.005-mixETH minimum. It also omitted helper identity.

The runner now exports bounded `PSP_SINE_PL`. The manifest reads versions
before selecting a tuple and checks v3 ticket arithmetic, materialization,
factory/helper wiring, and helper runtime. Source-verification tooling includes
the helper. Explicit v2 handling remains for older deployments.

The deployment runner and manifest suites pass 21 tests. A fresh local
deployment also passes the receipt lifecycle described below. Historical
manifests remain unchanged. Public source verification was not submitted.

### AUD-V3-4 — Low, fixed locally: live charts and displayed minima become stale

The sine loader cached an inactive result for the same hook indefinitely.
After launch, a user could keep seeing a prelaunch chart until a page reload.
The new reader retries inactive and failed reads, then caches only the
materialized coefficients. Tests cover launch, retries, successor rounds,
address casing, and chart expansion without extra chain reads.

The live chart also included negative reserves and extended past the current
helper's supported range. It now starts at reserve zero and stops at that
range. The swap panel displays the exact live minimum and uses the quote's
ticket price for its ticket estimate. Missing rule versions no longer select
a default minimum. Errors from the helper remain readable through v4 wrappers.

The rolling paper, both landing pages, and the curve explainer had stale text
or executable v2 math. Their examples now use the signed softened cube root,
ten wave markers, square-root reserve scaling, and pot-based tickets. The
paper's ticket and clock inputs use exact integers, including one wei.

### AUD-V3-7 — Low, fixed locally: buy quotes omit execution limits

`src/CurveHook.sol:1012`, `getBuyOutput`, omitted the signed-128 input bound and zero/oversized
output checks. It now uses the same errors as execution. Tests check oversized
quotes and exact quote/output agreement through v4 for a `1e11`-wei ticket.

### AUD-V3-8 — Low, fixed locally: reinvestment reads a caller-selected hook

The reinvestor read its minimum from `key.hooks` before checking that the hook
belonged to the NFT's round. No unauthorized loss was demonstrated: caller
authorization and claim/buy/restake rollback already protected the position.
Still, this did not meet the handoff's authenticated-hook requirement.

Both reinvestment paths now compare the supplied hook with the staker's
controller before claiming fees. The regression checks single and batch
rejection while fees, router balances, and ticket count remain unchanged.
Existing owner and approved-operator paths remain covered by their tests.

## Spec checks and dependencies

The following intended rules match the source and focused tests:

- A 500-mixETH gross launch gives 50 pot, 450 backing, wavelength 955,
  and a tenth-wave reserve target of 10,000.
- Price targets 1,000 times launch spot after ten complete postlaunch waves.
- The signed price expression covers prelaunch and active reserves.
- Genesis, buys, and sells use the same cumulative coordinate.
- Tickets use the whole accounted pot, with ceiling division and a one-wei floor.
- The active gross minimum equals one ticket, sampled before the buy's fees.
- Ticket count is `floor(gross / price)`. Writes remain bounded to ten seats.
- Ticket time remains 69 seconds, subject to the existing clock cap.
- Sell fees can grow the pot. Sales retain ladder seats.
- Referral purchase guards, allocation rules, and old-round exits remain present.

These checks do not close the numerical findings. In particular, no full-domain
proof of exact-ticket execution, monotone supply, or fair inversion is claimed.

Caller analysis found eight production call sites for `supplyWad`: two in the
hook and six inside the helper. They serve launch quotes, initialization, buys,
sells, and inversion. `buyOut` and `sellOut` each have two hook call sites:
execution and quoting. `_validateBootstrap` serves both public deposits and
carry. Thus a numerical change affects every new round and all settlement
entry routes, rather than one isolated chart or router.

## Test quality

The original price oracle supplied `1e11` to Foundry's WAD-scaled relative
tolerance. This allowed `1e-7` relative error despite the stated `1e-11` goal.
The test now uses an explicit `expected / 1e11 + 1` price allowance.
Supply uses `expected / 1e9 + 1`. This also removes the prior absolute
`1e12`-PSP-wei allowance that concealed errors in tiny launch fixtures.
The tightened oracle's six tests pass.

The endpoint telescoping test only subtracts values of the same function.
That identity cannot establish integral accuracy, conservation, or monotonicity.
It remains useful as an accounting identity, but the independent oracle,
funded trade tests, and adjacent-value properties carry the stronger evidence.

## Final validation

`bash scripts/check-audit.sh` exits with status 1: **607 tests pass and three
fail across 81 suites**. All three failures are the required monotonicity
assertions in `SineV3ReviewRegression.t.sol`. No other contract test fails.
The initial contract run, before these regressions, passed all 600 tests.

The deterministic gate stops on the contract failure. Its remaining checks
were therefore run separately, without excluding failures from the gate:

| Check | Result |
| --- | --- |
| Generated art and renderer fixtures | Pass |
| No-governance check | Pass |
| Production sizes | 42 artifacts pass |
| Legacy sine oracle and v3 generated files | Pass |
| ABI | 172 functions/events match |
| Frontend tests | 207 pass, zero failures |
| Name-verifier tests | 11 pass, zero failures |
| TypeScript and normal/alternative Vite builds | Pass |
| Changed script syntax and whitespace | Pass |

Measured runtime sizes are 20,261 bytes for CurveHook, 12,162 for SineV3Math,
19,795 for PSPFactory, and 5,297 for PSPReinvestor. No size limit was raised.
Both Vite builds retain the existing large-chunk advisory.

The fresh local lifecycle passed 46 action receipts: 39 successes and seven
expected reverts. All eighteen deployment receipts succeeded. Twenty-seven
runtime/data checks covered both rounds, nested helpers, creation-code shards,
art data, and the reinvestor. The largest action used 9,797,172 gas. The
[evidence directory](2026-09-15-single-sine-evidence/README.md) preserves the
receipts and detailed numerical report. Historical broadcast records were
not changed.

The browser check covered the desktop curve diagram and a 390-pixel mobile
ticket calculator. Both layouts were readable. DOM checks exercised pot
repricing, tiny inputs, and both explainer entries. Temporary browser settings
were reset.

Slither was not available on PATH in this review environment. Historical
zero-high/zero-medium counts were not treated as a new static-analysis result.
The review did not run a live Base Sepolia fork or submit a public transaction.
The local deployment uses a mock PoolManager. The funded inverse regression
and lifecycle suite separately use the real Uniswap v4 implementation.

## Required work before release

1. Replace the rounded price and primitive with a monotone numerical design.
2. Preserve the three failing regressions and add range-based tests around
   every cell boundary, flat wave point, launch scale, and custom price limit.
3. Derive the supported range and implement a bounded continuation beyond the
   current table, or obtain approval for different economic limits.
4. Recheck inverse accuracy, one-ticket execution, custody, gas, and all
   production bytecode sizes after that numerical change.
5. Run the complete deterministic gate and a fresh local fork rehearsal.

The contained fixes in this review do not require a new economic choice.
The unresolved numerical work does require a new implementation and another
review. This report is not a security certification.

Writing check: 2.19 findings per 100 words.
