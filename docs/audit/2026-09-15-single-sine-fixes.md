# Single-sine repair report — September 15, 2026

**Repair status: implemented locally; final validation is pending.** This report records the changes made after the [initial review](2026-09-15-single-sine-review.md). It does not approve a public deployment. The final gate, runtime sizes, gas measurements and deployment receipts must be filled in below before a release decision is recorded.

The scope is branch `single-sine-spec`, starting from `a80984c8`, plus the local review and repair changes. The [original implementation handoff](../implementation-prompts/2026-09-14-single-sine-cuberoot-pot-tickets.md) remains the acceptance reference. Existing deployments retain their existing bytecode. No public deployment, hosted-page publication or live-address change forms part of this repair.

## Settlement repairs

### Price and supply preserve integer order

The prior helper could return a lower price or cumulative supply after one additional reserve wei. Its moving quadrature nodes and separately rounded cube-root quotient did not preserve order. Clamping a partial integral between its endpoints did not fix its interior decreases.

[SineV3Price](../../src/SineV3Price.sol) now builds the price from operations that preserve order. Ordered Bernstein controls represent the periodic phase. Shared endpoints and exact reflections join quarter waves, whole waves and negative coordinates. An exact floored integer cube root replaces the rounded-denominator quotient. The exponential uses a positive Taylor polynomial and exact powers of two, with checked range reduction and overflow.

[SineV3Primitive](../../src/SineV3Primitive.sol) defines a single cumulative integral from canonical endpoints. It forms positive density controls at fixed nodes, integrates them into ordered cumulative controls, and normalizes the result to the exact stored cell endpoints. Integer interpolation preserves the order of those controls at every level. Adjacent cells share the same canonical endpoint.

The cumulative scale is `1e36`. A cell query retains the exact reserve numerator and denominator until conversion to a `1e54` interpolation fraction. It does not first discard small reserve differences by converting the complete phase to WAD. This matters when launch backing is large but a reserve change is one wei.

These are structural arguments about the integer implementation. The numerical checks serve a different purpose: they test its agreement with the intended analytical curve. The [price analysis](2026-09-15-single-sine-evidence/price-review.md) gives the phase and exponential error derivation and records its isolated tests.

### The sell inverse completes a checked search

The old inverse could exhaust its Newton iterations with a wide bracket, then settle a sale from that incomplete result. The funded wave-63 counterexample underpaid by more than 99.999%.

The new inverse first finds the canonical cell containing the target supply. It prepares that cell's controls once, then performs a bounded binary search in reserve wei. Every query uses the same cached controls. It checks both the returned endpoint and its preceding wei before it returns. A search that does not establish the required bound reverts.

For cumulative supply `Q = floor(lambda*(F-f0)/(pL*1e18))`, the inverse target is exactly `f0 + ceil(qTarget*pL*1e18/lambda)`. Accepted factory cells span fewer than `2^80` reserve wei, within the checked loop's 256-step bound. The [domain and allocation analysis](2026-09-15-single-sine-domain.md) sets out these limits and the buy/sell conservation argument.

The independent sell-price clamp now uses an upper envelope that includes approximation error and final price rounding. A floored price alone was not a valid upper bound; near one price unit it could cut an otherwise valid sale almost in half. The cumulative inverse remains the binding settlement calculation.

### Capacity follows price and token precision

The former limits of sixteen prelaunch waves and sixty-four active waves came from the table layout. They were not limits of the selected curve.

The replacement checks the actual opening price, the factory's launch-price range, the derived wavelength, and supported reserve arithmetic. A zero opening price is rejected. The negative table reaches phase `-580.5`, covering every potential launch with a positive opening price under `1e9 <= pL <= 1e18`. The preliminary 682-million-mixETH net-boot check bounds intermediate arithmetic; the opening-price check sets the tighter limit for each launch price.

The positive endpoint is 4,096 waves. An analytical upper envelope bounds all supply remaining beyond that point by less than `0.004867` PSP wei across the admitted launch domain. This is below the existing one-wei buy haircut. The [derivation](2026-09-15-single-sine-domain.md) also separates that tail bound from table quantization and approximation errors. The helper rejects buys outside its supported range before any state changes. It does not replace the curve with a linear tail or manufacture a constant cumulative supply.

### Every admitted positive contribution retains an allocation

[RoundController](../../src/RoundController.sol) no longer applies the old sixteen-wave boot constant. Before recording a deposit or carry, it runs the same genesis calculation used at launch. It rejects a zero result and requires genesis supply `Q` to be at least the prospective share denominator `D`.

For every positive contribution `d`, this proves `floor(Q*d/D) >= d >= 1`. The sum of independently rounded claims cannot exceed the genesis allocation. Every later deposit and bonus must preserve the condition. The calculation uses full-precision multiplication and division; minting, genesis locks, principal and direct redemption use uint256. V4's signed128 limits continue to apply to individual swaps, not to the total genesis mint.

Factory `seedCarry` creates shares and increases the denominator. Legacy `potDeposit` adds a bonus without shares and keeps the denominator unchanged. The repair preserves this distinction. At the maximum custom launch price, some tiny aggregates cannot represent a positive proportional allocation after the genesis fee. They now fail before funds or shares are recorded. One-wei default and custom launches, later-deposit rollback, bonus funding, large allocations and complete exits have dedicated [bootstrap tests](../../test/SineV3BootstrapCapacity.t.sol).

## Authorization and accounting repairs

| Finding | Final source behavior | Evidence |
| --- | --- | --- |
| Approved graveyard zap could redirect another wallet's earned fees | Each selected NFT must belong to the transaction caller before any exit leg runs. Approval of the zap does not authorize strangers. | [GraveZap](../../src/PSPGraveZap.sol), [funded regressions](../../test/wave2/auditorB/B6_GraveZap.t.sol) |
| Reinvestment read a caller-selected hook | Both routes require the hook to match the NFT staker's own controller before fee claims. Owner and operator checks remain in force. | [Reinvestor](../../src/PSPReinvestor.sol), [attribution tests](../../test/ReinvestAttribution.t.sol) |
| Batch allocation could overflow before division | Proportional allocation uses `Math.mulDiv` and a snapshot of the selected principals. | [allocation tests](../../test/ReinvestAllocation.t.sol) |
| A small PSP donation could block later batch reinvestment | The final selected position with nonzero principal receives the exact remainder. Every new PSP is staked; the balance present before the batch remains unchanged. Empty positions receive no remainder. | [integration follow-up](2026-09-15-single-sine-evidence/integration-follow-up.md) |
| Buy and sell quotes accepted inputs that execution rejected | Quotes apply the route's mode, clock, amount, supply and output checks. The V4 sell quote retains its dust and complete-supply restrictions; direct redemption remains a separate full-exit route. | [sell parity tests](../../test/SellQuoteParity.t.sol), [ticket tests](../../test/TicketRulesV3.t.sol) |

The batch repair also prevents ordinary rounding remainders from building up inside the wrapper. Its isolated tests use real ERC20 transfers with controlled fee and position fixtures. A separate funded real-V4 test checks owner-attributed compounding after a 1,001-PSP-wei donation. These tests cover different layers of the repair.

## Immutable data and deployment checks

The helper pins four data-contract addresses at construction. It checks each address against the generated runtime length and code hash. The data runtimes begin with STOP and have no write or replacement path. Missing, reordered, duplicated or altered data must prevent helper deployment. [Data security tests](../../test/SineV3DataSecurity.t.sol) cover these cases.

The deployment script creates the data contracts before the helper, then passes the helper to the factory. Deployment tools now use `PSP_SINE_PL` and reject retired curve settings. The manifest reads versions before incompatible getters, validates v3 materialization and exact pot-ticket arithmetic, and checks factory/helper wiring and all four returned data runtimes. Legacy v2 interpretation remains explicit. Source-verification tooling includes the helper and its data contracts.

The [size gate](../../scripts/check-sizes.py) checks helper runtime and initcode with constructor arguments. It separately checks the actual returned data lengths, since compiler metadata for the data constructors cannot establish those runtime sizes. No size threshold or failing test is excluded to make this repair pass.

## Paper, explainers and live views

The rolling paper, both landing-page variants and the curve explainer now use one signed sine curve with softened cube-root growth. Their examples use 500 mixETH gross predeposit, 450 backing, a 955-mixETH wavelength, and 1,000 times launch spot price at the tenth postlaunch wave. They show square-root wavelength scaling, whole-pot ticket pricing, and a minimum active gross buy equal to one ticket.

The paper's executable ticket and clock examples use exact integers, including one-wei cases. The live chart starts at reserve zero, resolves early waves, and respects supported settlement capacity. The reader retries failed or inactive reads and caches only materialized coefficients. Displayed minimums and ticket estimates use the live or quoted ticket price. Missing rule versions do not select an invented fallback minimum.

These changes explain the implemented rules. Chart arithmetic is for display; contracts remain the settlement authority. Historical deployments and their exit paths retain their own versioned rules.

## What the evidence establishes

1. **Integer order:** ordered controls, positive arithmetic and shared endpoints give the monotonicity argument for all supported integer query coordinates. This is stronger than checking a sample of reserve values.
2. **Finite coefficient domain:** the [primitive validator](../../scripts/sine_v3_primitive_validate.py) enumerates every canonical cell's deterministic coefficient assembly and checks positivity and signed intermediate bounds. It is a finite check of those coefficient sets, not a proof about arbitrary substituted data or a complete formal verification of the EVM program.
3. **Approximation accuracy:** the same validator compares density at 81 fractions per cell. Those comparisons are sampled evidence; they do not prove a uniform interpolation-error bound between the samples. Independent price fixtures, cumulative-supply fixtures and the small-reserve oracle add separate accuracy checks.
4. **Local reserve precision:** the [small-reserve oracle](../../scripts/sine_v3_small_reserve.py) generates 150 vectors with 90-digit Decimal Simpson integration. It imports no settlement tables or coefficients. Whole-versus-halves convergence is `6.0845e-35` relative at worst. The contract tolerance is `1e-9` relative plus one PSP wei.
5. **Execution:** funded route tests cover custody, fees, ticket intent, rollback, large genesis allocations and exits. Fuzz tests explore additional states but do not establish that every possible transaction sequence is safe.

This is a bounded source review and validation record, not a security certification. It does not claim a new audit of all external dependencies, economic guarantees for players, or source verification on a public chain.

## Final validation record

The existing [review evidence directory](2026-09-15-single-sine-evidence/README.md) contains the earlier local run, including three failing monotonicity regressions. Its old gate summary and receipts must not be presented as proof of the final repair. Final evidence must identify the source state it tested.

| Required check | Final result |
| --- | --- |
| Source revision and working-tree state | **PENDING: fill from final run** |
| `bash scripts/check-audit.sh` | **PENDING: exit code and durable log** |
| Solidity suites, tests, failures and skips | **PENDING: final counts** |
| Price and primitive generation; all-cell validation | **PENDING: output and accuracy statistics** |
| Original monotonicity regressions; small-reserve and bootstrap tests | **PENDING: final integrated result** |
| Runtime, returned data and initcode sizes | **PENDING: final measured values** |
| Frontend, names, ABI, art and governance gates | **PENDING: final counts/results** |
| Normal and alternative frontend builds | **PENDING: final result** |
| Fresh local deployment and lifecycle | **PENDING: deployment receipts, expected reverts and evidence paths** |
| Worst tested swap, inverse and lifecycle gas | **PENDING: measured values and limits** |
| Static analysis or public-fork checks, if run | **PENDING: exact scope, or state not run** |

Keep the release block in READINESS until the required gates pass. Record the final result in GATE-LOG without rewriting the earlier failed review.
