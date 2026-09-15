# Implementation handoff: one sine curve, softened cube-root growth, and pot-priced tickets

## Objective and authority

Implement the approved economic changes in this repository. Complete the Solidity implementation, client integration, independent numerical oracle, regression tests, and local lifecycle verification.

The repository is Positive Sum Pepes (PSP), at `/Users/deepthought/Desktop/dev/psp-sigma-testnet`. Resolve paths from the repository root if your harness uses a different checkout.

This handoff authorizes source changes and necessary functional UI changes. Earlier instructions to avoid implementation applied to the design discussion. This task does not authorize public-chain deployment, publishing, changing live addresses, or sending messages to third parties. Local Anvil deployment with disposable accounts is part of the task.

The user selected these changes:

1. Use one continuous tilted-sine price curve through both the IBCO and active trading.
2. Use softened cube-root growth, reaching 1,000 times the launch spot price after ten complete postlaunch waves.
3. Keep the 500 mixETH gross IBCO baseline, with 10,000 mixETH of curve backing at that target.
4. Apply square-root scaling to the additional backing between launch and the target.
5. Price each ladder spot from the entire current accounted pot: `currentPot / 10_000`.
6. Set the active gross-buy minimum equal to exactly one current ladder spot.

Implement these rules together. Do not retain the old exponential IBCO ramp, three-wave target, constant multiplier per wave, or fixed 0.005 active minimum on new rounds.

This prompt supplies explicit rounding and mathematical choices so implementation can proceed without reopening routine design questions. Preserve the existing launch spot price, use the signed extension below for prelaunch prices, and use a one-wei minimum for an otherwise zero ticket price.

## 1. Inspect the checkout and establish the baseline

Read these files before editing:

- `AGENTS.md`
- `docs/audit/READINESS.md`
- `docs/FINAL-SPEC.md`
- `docs/audit/FEE-ACCOUNTING.md`
- `GATE-LOG.md`, especially the latest entries
- `CLOCK-REDESIGN.md`, with newer readiness and specification amendments taking precedence
- `docs/audit/2026-09-13-final-spec.md`
- `docs/audit/2026-09-13-referral-rewards.md`

This handoff supersedes older curve, ticket-price, and active-minimum rules only. Other current requirements remain binding.

The source inspected for this prompt was commit `6f18dbd76b5279def7353a11f8062b50d1622f01`. Inspect the actual tip before work. Preserve unrelated edits and untracked files. At handoff, untracked files included three broadcast records and `frontend/pinata-upload/`. Do not delete, regenerate, commit, or publish them as part of cleanup.

The latest recorded gate at that source passed 569 Solidity tests across 74 suites, 185 frontend tests, and 11 name-verifier tests. Those are historical observations, not test results for your changes. Obtain fresh results and append them to the gate log.

Keep these existing rules:

- mixETH remains the unit of account. Do not introduce a USD oracle or a vault-rate dependency into settlement.
- Genesis funding sends 10% of gross launch funds to the pot. The remainder becomes curve backing.
- Default IBCO duration remains three days. Deposits remain uncapped economically, subject to demonstrated arithmetic capacity.
- Public predeposits accept any positive amount. Their minimum does not become a ticket price.
- The active clock remains 69:04:20 by default. Each whole ticket adds 69 seconds, subject to the existing cap.
- Constructor timing overrides and four 64-bit timing fields remain intact.
- Withdrawal timing, fee entitlements, referral escrow, owner/operator reinvestment, art reservations, and NFT behavior remain intact.
- Selling does not erase ladder seats. The latest ten tickets remain the ladder.
- Detonation, fee-free dead-round redemption, pot claims, and resumable three-step successor birth remain intact.
- The current keeper remains disabled. The embedded testnet HTML and old deployment records remain historical records.

Run the current deterministic gate before editing if the environment supports it. Record pre-existing failures separately. Use the correct toolchains: Foundry at root, pnpm for keeper tooling, npm in `frontend/`.

## 2. Treat the mathematical specification as binding

### 2.1 Units and launch accounting

Use WAD amounts for mixETH and PSP. All formulas in this section use real human units for clarity. Implement the equivalent scaled integer operations explicitly.

Let:

- `D` be actual gross launch funds: recorded public predeposits plus accepted carry.
- `genesisPot = floor(D * 1000 / 10000)` in integer mixETH wei.
- `b = D - genesisPot` be actual net launch backing.
- `R` be the current accounted curve backing. It excludes the pot and other fee liabilities.
- `P_L = 0.000075 mixETH / PSP` be the default launch spot price, or `75_000_000_000_000` WAD.
- `b_ref = 450 mixETH` be the reference launch backing.
- `lambda_ref = 955 mixETH` be the reference width of one wave.

Use actual `b` in the contract. Do not recompute it as an approximate floating-point `0.9D`. Integer genesis-fee rounding matters for tiny deposits.

Define:

```text
lambda = 955 * sqrt(b / 450)
R_target = b + 10 * lambda
```

At the reference launch:

```text
D = 500 mixETH
initial pot = 50 mixETH
b = 450 mixETH
lambda = 955 mixETH
R_target = 10,000 mixETH
additional backing required = 9,550 mixETH
```

The square root scales the additional backing, not the entire target reserve. Do not substitute `10_000 * sqrt(D / 500)`. That alternative can put the target below launch backing for large raises.

Round the materialized wavelength conservatively and document its rule. Define the materialized target from the same stored wavelength: `b + 10 * lambda`. This keeps the tenth wave aligned with the target.

Do not first round `b / b_ref` into a WAD ratio and then take its root. That can make the wavelength zero for a one-wei launch. For the fixed default, this algebraic form is a useful implementation candidate:

```text
lambdaWei = floorSqrt(fullMulDiv((955e18)**2, bWei, 450e18))
```

Prove the intermediate and output bounds before using it. At `b = 1 wei`, the wavelength is approximately `45,019,131,735 wei`, not zero. At `b = 450e18`, it must be exactly `955e18`.

### 2.2 One price formula over the full reserve domain

Define dimensionless progress:

```text
x(R) = (R - b) / lambda
s(x) = x - sin(2*pi*x) / (2*pi)
```

The full-amplitude sine makes the price slope zero at each integer wave boundary. It does not make price decrease as backing increases.

Define the signed, softened cube-root function:

```text
H(z) = sign(z) * (cuberoot(1 + abs(z)) - 1)
H(0) = 0
K = ln(1000) / (cuberoot(11) - 1)
K is approximately 5.64368271363719722487
```

The required price curve is:

```text
P(R) = P_L * exp(K * H(s(x(R))))
```

Numerical branches may evaluate this same function with different stable methods. They must not define different economic curves.

Apply this formula for every supported `R >= 0`. In particular, use it below `b`, at `b`, and above `b`. Negative progress before launch is expected. Negative reserves are not allowed.

Do not use an unsigned cube root directly on `1 + s(x)`. That expression becomes negative for sufficiently large prelaunch spans. The signed extension above is part of the specification.

Do not implement `cuberoot(exp(k*x))`. That remains a constant-rate exponential. The root must shape progress inside the exponent, as specified above.

The `+1` softening is required. The unsoftened `1000^((n/10)^(1/3))` reaches about 24.69 times launch in wave one. That is not the selected design.

For cancellation near zero, consider the equivalent identity:

```text
c = cuberoot(1 + abs(z))
H(z) = z / (c*c + c + 1)
```

Handle WAD scaling and rounding explicitly. This identity avoids subtracting nearly equal root values. The installed Solady library already contains `cbrtWad`. Inspect and test its actual rounding and input domain before reuse.

The analytical derivative is nonnegative:

```text
d(log P)/dR = K * (1 - cos(2*pi*x))
                / (3 * lambda * (1 + abs(s(x)))^(2/3))
```

Use that fact to guide bounds and tests. It is not proof that a rounded implementation is monotone.

### 2.3 Binding milestone checks

For integer `n` from zero through ten:

```text
R_n = b + n * lambda
P(R_n) / P_L = 1000^(((1+n)^(1/3) - 1) / (11^(1/3) - 1))
```

Approximate review values follow. Generate high-precision oracle fixtures independently. Do not use these rounded decimals as exact Solidity golden vectors.

| n | Baseline backing / mixETH | Price / launch price |
|---:|---:|---:|
| 0 | 450 | 1 |
| 1 | 1,405 | 4.33582514 |
| 2 | 2,360 | 12.13284521 |
| 3 | 3,315 | 27.52528847 |
| 4 | 4,270 | 54.97502424 |
| 5 | 5,225 | 100.64196972 |
| 6 | 6,180 | 172.82749097 |
| 7 | 7,135 | 282.50117606 |
| 8 | 8,090 | 443.92267925 |
| 9 | 9,045 | 675.37163123 |
| 10 | 10,000 | 1,000 |

The default price at the tenth wave is `0.075 mixETH / PSP`. The starting price at zero reserve is now derived. At the baseline it is about `0.000036028064 mixETH / PSP`. Do not preserve the old `0.00001` origin price or the old 7.5-times IBCO ramp.

The curve continues beyond wave ten within its supported arithmetic domain. Wave ten is a calibration point, not a trading stop, a flat tail, or a new phase.

### 2.4 Supply and inverse must come from the same curve

Define cumulative ideal supply:

```text
Q(R) = integral from 0 to R of [1 / P(r)] dr
Q(0) = 0
Genesis supply = Q(b)
```

Genesis allocation must use the new integral. Do not retain the old exponential genesis supply and attach the new active curve to it.

For buys, derive ideal output from `Q(R + netInput) - Q(R)`. Preserve conservative rounding and a justified haircut so numerical error cannot create backing.

For sells, invert the same cumulative function with a valid bracket. For an active sell, `[0, currentReserve]` gives a useful known-valid reserve bracket. Justify the iteration bound against the supported reserve width. Do not assume the old 96-step limit is sufficient. The returned reserve endpoint must not produce an excessive payout. Preserve and re-prove the independent spot-price bounds where applicable.

Cumulative supply must be a deterministic function of the reserve endpoint. A trade sequence must not change the curve's mathematical definition. Separate three effects in tests: ideal endpoint telescoping, per-trade conservative haircuts, and per-trade fee rounding.

## 3. Solve the numerical architecture before wiring the contracts

Read `src/libraries/SineMath.sol` in full. Several current optimizations are invalid for this new curve:

- `_preSupply`, `_preReserveAt`, and the separate prelaunch exponential price path.
- The fixed per-wave growth `g` and first-wave supply `W` used for all later waves.
- The geometric-series endpoints in `supplyAt`.
- The closed-form geometric inverse seed in `reserveAt`.
- Exponential-argument bounds derived from a constant `waveTrend`.
- Any assumption that translating one wave gives the same integral scaled by a constant factor.

Changing only `WAVES`, `pTarget`, or the price function would leave settlement inconsistent. Replace the dependent numerical logic.

Build a small high-precision prototype first. A useful dimensionless primitive is:

```text
F(x) = integral from 0 to x of exp(-K * H(s(t))) dt
Q(R) = (lambda / P_L) * [F(x(R)) - F(x(0))]
```

This separates the fixed curve shape from the round's scale. It can support a bounded evaluator with canonical intervals and immutable shared approximation data.

Choose a numerical method with measured error and bounded on-chain cost. Candidate components include canonical cumulative knots, a fixed amount of local quadrature, bracketed interpolation, and a certified treatment of the distant tail. Prototype them before selecting one.

The implementation must satisfy all of these constraints:

- No loop proportional to every completed wave or every prelaunch wave on each swap or deposit.
- No unbounded adaptive integration or inverse search in a public transaction.
- No hidden ten-wave cutoff or fallback to the previous exponential curve.
- No large trade sliced into unrelated local approximations that lose endpoint consistency.
- No off-chain oracle or keeper needed to define or update settlement prices.
- Any numerical table or helper must be immutable for the round. Validate its identity and configuration in the deployment path.
- If coefficients or tables are generated, check their generator and exact output deterministically. Do not hand-edit generated data.
- Cumulative values at shared cell boundaries must agree. Test both sides of every relevant boundary for price and supply decreases.
- Tiny endpoint differences must remain usable. A large cumulative supply must not erase the output of an otherwise valid one-ticket buy through cancellation.
- The inverse must terminate with a correct bound, including near flat wave points and fixed-point plateaus.
- Normal and worst-supported swaps must fit realistic transaction gas limits.

Inspect `scripts/check-sizes.py` early. The recorded hook runtime was 24,019 bytes. The current gate requires selected contracts to remain below 24,076 bytes, leaving only 57 bytes at that snapshot.

Plan code placement before adding the new math. A shared immutable math helper or existing deployment-shard pattern may be necessary. Include every new production artifact in size and deployment checks. Do not raise the limits or add exclusions to make the gate pass.

### 3.1 Define arithmetic capacity explicitly

The current implementation accepts enormous launch values in tests. The new fixed launch price and signed prelaunch curve cannot inherit that domain by assumption.

As `b` grows, the prelaunch price decreases. With this proposed curve, very large backing eventually makes `P(0)` smaller than one WAD price unit. Existing tests with boot values such as `1e30` or `1e36` wei therefore need deliberate treatment.

Derive and document supported ranges for net boot, phase, price, cumulative supply, input amounts, and intermediates. Use explicit capacity errors. Distinguish those arithmetic limits from an economic fundraising cap.

Preserve one-wei public deposits and prove that the resulting pooled launch works under the new defaults. Reject an unrepresentable aggregate before recording its deposit or accepted carry. Validate the actual launch path, including minting, supply, integer casts, and genesis allocation. A successful `sineGenesisPSP` quote alone does not prove that `initializeCurve` and launch can execute within gas and type limits. Do not accept funds into a configuration that can never launch.

Review `RoundController._validateBootstrap`. It currently validates only when net boot reaches 450 mixETH. That condition is an old numerical assumption, not a rule to preserve blindly.

Also test factory carry and unsolicited donations. Invalid excess funds must not make successor birth or the next predeposit window unusable.

For any accepted active buy, ensure the resulting state retains supported sell, detonation, claim, and redemption paths. Reject an out-of-domain buy before state changes. Do not silently clamp price, manufacture zero-price regions, or strand backing.

If an earlier huge-value test becomes mathematically incompatible, document why. Preserve its arithmetic, rollback, and exit protections through equivalent supported-range tests or isolated arithmetic harnesses. Do not simply delete it.

## 4. Implement pot-priced tickets and an equal minimum buy

### 4.1 Exact integer rule

Use the entire current accounted `CurveHook.potBalance` before the purchase contributes its own fees.

```text
rawTicket = ceil(potBalance / 10_000)
ticketPrice = max(1 wei mixETH, rawTicket)
minimumActiveGrossBuy = ticketPrice
units = floor(grossMixInput / ticketPrice)
```

Use overflow-safe ceiling division. For example:

```text
q = potBalance / 10_000
if potBalance % 10_000 != 0: q += 1
if q == 0: q = 1
```

Do not implement ceiling division as `(potBalance + 9999) / 10000` without proving the addition safe.

The one-wei floor only resolves zero and sub-wei prices. It must not become a 0.005 floor or any other economic minimum.

Do not subtract `genesisPotBalance`. Do not use raw ERC-20 balance, curve backing, total contract funds, or `potBalance - potPaid` as the active price base.

The ticket amount is a gross qualifying PSP purchase amount. It is not an extra fee or a second token transfer. Keep the existing trade fees and fee allocation.

### 4.2 Buy behavior

In the authoritative hook path:

1. Enforce active mode and the existing clock-expiry checks.
2. Read the ticket price once from the pre-purchase pot.
3. Reject gross input below that price.
4. Calculate the current trade fee and the PSP output using the new curve.
5. Compute all ticket units from that same sampled price.
6. Apply state changes, ladder entries, clock additions, and fee routing in the existing safe order.

Do not recalculate ticket units after the buy's own pot contribution. Do not reprice each ticket within a single purchase. Every successful active buy must earn at least one ticket, subject to other valid execution checks.

Keep `units = floor(gross / q)`. A purchase of `2q - 1 wei` earns one ticket. Fractional remainders earn no additional ticket or time.

Preserve bounded seat writes: store at most the latest ten tickets even for huge `units`. Preserve absolute ticket numbering and checked arithmetic. A wallet may own multiple seats.

Keep actual-seconds `TimeAdded` reporting after the cap. Do not replace it with nominal time or ticket count. Preserve the 69-second unit.

Per-seat display amounts can round to zero for extreme ticket counts. Do not invalidate an otherwise valid seat because `pspOut / units` is zero.

### 4.3 Remove every conflicting minimum

Inspect at least:

- `CurveHook.beforeSwap`: the universal `MIN_SWAP_INPUT = 1e12` check currently runs before buy/sell dispatch.
- `CurveHook._handleBuy`: the static `MIN_BUY_INPUT` check.
- `CurveHook.getBuyOutput`: the quote-side static check and its output/range behavior.
- `src/libraries/GameRules.sol`.
- Both single and batch paths in `src/PSPReinvestor.sol`.
- Router, referral-purchase, direct PoolManager, and wrapped-input paths.

Changing `_handleBuy` alone is insufficient. For new sine buys, a ticket below `1e12 wei` must not face a hidden `1e12` minimum. Preserve sell-side and legacy numerical protections separately unless a justified fix requires changing them.

Expose an authoritative live minimum. Prefer retaining the `MIN_BUY_INPUT()` selector but making its version-3 result equal `ticketPrice()`. If another API is cleaner, provide a documented compatibility layer and update every caller. New clients must not mistake a historical constant for the current minimum.

The one-ticket threshold is an amount rule. Existing mode, deadline, slippage, signed-128, and representable-output constraints still apply. Prove that exact-ticket purchases work across the supported active domain. Report a mathematical output limit explicitly instead of hiding it behind a static amount floor.

Quotes and execution must agree at the same block and state. A quote must not advertise a valid exact-ticket buy that the hook rejects through an obsolete minimum.

For reinvestment, use the authenticated round's current price. Preserve owner/operator authorization, owner attribution, single-owner batches, duplicate rejection, and claim/buy/restake atomicity. A failed minimum check must not consume earned fees or strand tokens.

### 4.4 Fee and ladder behavior to preserve

- Genesis still contributes 10% of gross launch funds directly to the pot.
- The sine trade fee remains 10% at or below boot, decreasing linearly to 2.5% at the new tenth-wave reserve target.
- Fee distribution, referral escrow, staker credit, deployer credit, and rounding destinations retain their current rules.
- Buy fees and sell fees can increase the ticket price. A buy's own fees affect subsequent buys only.
- Selling reduces backing but does not reduce the accumulated pot or remove seats.
- Ladder weights remain 25/18/14/10/8/7/6/5/4/3, with existing partial-board normalization.
- No-ticket detonation still moves the pot into redemption backing.

The ideal `2,500x` comparison is the full-board first prize divided by one ticket's gross qualifying amount at the same pot. Integer ceiling and payout rounding make the actual same-pot ratio no greater than 2,500. Dust amounts can differ substantially. Later pot growth changes that comparison again. It is not a probability or a guaranteed return. Preserve this distinction in any updated explanatory text.

### 4.5 Protect ticket intent in new client purchase routes

Dynamic pricing can change the ticket count while a transaction waits. PSP-output slippage protection alone does not fully protect that count.

Add a bounded ticket-intent guard on the new purchase routes used by the UI. A `minTickets` parameter or equivalent `maxTicketPrice` guard is suitable. Apply it against the actual price used by the trade, in the same transaction.

Keep existing selectors where compatibility requires them. An old selector must still face the authoritative one-ticket minimum in the hook. Do not break owner attribution or referral authorization when adding guarded routes.

Use the guarded route for ordinary buys and propagate equivalent protection through referral purchases and reinvestment where those flows quote a ticket count. Test the guard across pot changes. Do not claim multi-ticket slippage protection if only PSP output is protected.

## 5. Version contracts and update the deployment pipeline

Treat this as a new economic version. Use `SINE_RULES_VERSION = 3` and `TICKET_RULES_VERSION = 3`, unless those numbers are occupied at the actual tip. In that case, choose the next explicit versions and update this specification consistently.

Existing contracts remain immutable. Do not reinterpret an old deployed tuple or old event under the new rules.

Define a clear version-3 curve getter containing the data needed for pricing and display. It must expose actual boot, wavelength, target, launch price, and genesis supply, directly or through an explicit documented structure.

Avoid silently changing the meanings of the old eleven tuple fields. Client decoding must read the version before selecting an incompatible ABI. A distinct version-3 getter is acceptable.

Review these files and their callers:

- `src/CurveHook.sol`
- `src/libraries/SineMath.sol`
- `src/PSPFactory.sol`
- `src/RoundController.sol`
- `src/HookDeployer.sol` and `src/HookInitCode.sol`
- `src/ControllerDeployer.sol` and `src/StakerDeployer.sol`, if creation dependencies change
- `script/DeploymentSupport.sol`
- `script/DeployPSP.s.sol`
- `script/DeployReinvestor.s.sol`
- `scripts/deployment/base-sepolia.mjs`, including its duplicate environment defaults and related tests
- `frontend/scripts/deployment-manifest.mjs`
- ABI interfaces and creation-code or verification tooling affected by new helpers

Update source defaults and assertions. `DeploymentSupport` currently expects a static 0.005 minimum and version-2 tickets. The manifest currently expects version-2 sine/ticket rules and the old parameter tuple.

Do not reuse `p0` or `preK` to mean unrelated new parameters without an explicit versioned interface. Obsolete environment overrides must either have a documented compatibility path or fail clearly. Do not silently ignore them.

The selected default shape is fixed by this prompt. A generic configurable curve designer is not required. If custom amplitudes or other parameters remain supported for new rounds, define and test their domains separately.

Keep launch coefficients fixed once materialized. Later buys, sells, pot growth, or configuration changes for future rounds must not move an existing round's curve.

Include any new math-helper identity and configuration in the staged-birth context checks. Preserve CREATE2 prediction, entropy salts, code-size shims, and resumable birth. Use actual factory state for deployed addresses.

Update the read-only manifest to record versions, curve inputs, helper identities, snapshot pot, ticket price, and minimum at one block. Historical manifests must remain unchanged.

## 6. Integrate both frontends without a redesign

Make functional updates and correct explanations. Preserve layouts, artwork, navigation, and the established transaction flow unless a functional change requires an adjustment.

Inspect these current dependencies:

| Area | Files and changes |
|---|---|
| Price math and versions | `frontend/src/lib/sineVersion.ts`, `sine.ts`, `sineChart.ts`: add explicit v3 decoding, full-domain price sampling, ten-wave markers, and a bounded chart beyond the target |
| Game rules | `frontend/src/lib/gameRules.ts`: version-aware live minimum and ticket calculations, no default 0.005 denominator for v3 |
| Cached metadata | `frontend/src/lib/roundMetadata.ts`: cache immutable capabilities and addresses, not the dynamic minimum |
| Live state | `frontend/src/lib/useRound.ts`: read pot, current ticket price, minimum, and quote-relevant state consistently |
| Transaction checks | `frontend/src/lib/useConfirmedWrite.ts`: validate v3 capabilities and dynamic price at a pinned block, while preserving separate old-round exit validation |
| Main buys | `frontend/src/components/SwapCard.tsx`: remove static minimum checks and copy, use exact bigint amounts and guarded ticket intent |
| Reinvestment | `frontend/src/components/PepeCards.tsx`, `frontend/src/pages/Stake.tsx`: single and aggregate fee thresholds must use the current round's price |
| Alternate UI | `frontend/src/alt/AltTrade.tsx`, `AltCommon.tsx`, and shared components: use the same live rules and versioned chart math |
| Predeposit compatibility | `frontend/src/lib/predeposit.ts`: keep any-positive rules and retain the historical 0.005 fallback only for old versions that require it |
| ABI and scripts | `frontend/src/lib/abi.ts`, ABI checker, deployment manifest, and `frontend/scripts/anvil-tickets.mjs` |
| Current explanations | Maintained paper, landing, and diagram sources, including `frontend/public/rolling-paper.html` and relevant alternate-UI sources |

The current chart assumes eleven fields, a separate IBCO ramp, and twelve quarter-wave markers. Update those assumptions for v3. Keep v1/v2 curves readable with their original formulas.

Use on-chain materialized values for an active round. Before launch, label estimates and derive them from the current pooled backing. Do not show a hypothetical final IBCO amount as a fixed live calibration.

Display ten postlaunch waves and the 1,000-times launch-price milestone. The cube-root function shapes log-price growth. Do not label each new wave as a fixed doubling.

Display the current dynamic minimum and ticket price as the same amount. A one-ticket action must fill the exact integer amount, including when it is below 0.005 mixETH. Do not round a positive minimum to zero in labels or input fields.

An unavailable or incompatible price must disable exposure-increasing actions with a useful error. Do not fall back to 0.005 for v3. Retry transport failures rather than treating them as proof of a legacy version.

Re-read and simulate after approvals. A price increase while an approval is pending must produce a clear new quote or a safe revert. A multi-ticket request must not silently receive fewer tickets than its signed guard permits.

Keep legacy chart reads and old-round exits working. Do not require an old round to satisfy the current round's minimum or feature versions before a user can claim, withdraw, or redeem.

Do not hand-edit generated build output or the pre-existing `frontend/pinata-upload/` directory. Do not publish the UI. Keep the disabled keeper disabled.

## 7. Build an independent oracle and meaningful numerical tests

Update `scripts/sine_oracle.py` or add a clearly versioned successor. Preserve an independent high-precision Decimal implementation with at least 60 digits of working precision.

Use independent sine, cube root, exponential, and Simpson or other demonstrably converged numerical integration. Do not copy the Solidity quadrature tables, approximation coefficients, or rounded helper implementation into the oracle.

Check convergence by increasing precision and integration resolution. Derive fixtures from the mathematical specification, not from the Solidity output.

Cover at least:

- All eleven launch-to-target milestones and the baseline absolute prices.
- `R = 0`, `R = b`, and `R = b + 10*lambda`.
- Negative, zero, and positive phase through the signed extension.
- Wave boundaries, quarter-wave boundaries, and every approximation-cell boundary, including adjacent wei.
- Samples on both sides of launch and the target.
- Reserves beyond wave ten, including many-wave scenarios.
- Tiny launch pools, the 500 baseline, moderate larger pools, and values near every supported arithmetic boundary.
- Inputs near root cancellation and signed phase reduction.
- Cumulative supply, genesis supply, buy outputs, and inverse/sell results.

Maintain or improve the current oracle accuracy goals where applicable: relative price error around `1e-11` and relative supply error around `1e-9`. Use explicit absolute tolerances for tiny values. Do not weaken tolerances merely to accommodate an implementation defect.

Those global relative tolerances alone do not prove tiny trades safe. Add tests for local endpoint differences and strict conservation in integer wei.

Produce a reproducible `--check` path for every generated vector or numerical data file. Include it in the deterministic gate if the existing command does not cover it.

## 8. Add contract regression, fuzz, and invariant coverage

Use existing harness conventions. Read relevant tests before updating them. Keep retired historical suites outside the normal run, but do not move new failures into the retired directory.

### 8.1 Curve properties

Test all of the following:

- Positive representable prices throughout the accepted domain.
- Price and cumulative supply never decrease as reserve increases, including adjacent-wei and cell-boundary tests.
- `Q(0) == 0`; genesis allocation equals the same curve's `Q(b)`.
- The launch is continuous with no separate exponential branch.
- All materialized tenth-wave targets exceed boot and use the stored wavelength.
- Square-root reserve scaling matches multiple IBCO sizes, including accepted carry. Check `lambda(4b)` against `2*lambda(b)` within rounding.
- At matched normalized postlaunch coordinates, prices agree across round sizes and postlaunch supply increments scale with wavelength. Genesis supply does not scale linearly.
- Where both reserve points are nonnegative, `P(b+d)*P(b-d)` agrees with `P_L^2` within the documented price tolerance.
- Changing pot balance does not move the curve.
- Equivalent reserve endpoints give the same ideal supply, independent of trade history.
- Buy/sell round trips cannot extract mixETH through numerical error. Account separately for fees and conservative haircuts.
- Inverse outputs satisfy a correct bracket and never overpay a seller.
- Large and small trades crossing multiple waves work without per-wave gas growth.
- Failure at an arithmetic boundary leaves balances, supply, reserves, tickets, and fee liabilities unchanged.
- Every accepted buy state retains supported exits, including after the target and after detonation.

Update or extend `test/SineMath.t.sol`, `SineScaling.t.sol`, `SineOracle.t.sol`, `SineFee.t.sol`, and `SineStateful.t.sol`.

Also review `test/UncappedCapacity.t.sol` and `test/PredepositPrecision.t.sol`. Their huge-value and one-wei launch coverage must receive explicit treatment under the new domain.

### 8.2 Ticket arithmetic and thresholds

Test pots of `0`, `1`, `9999`, `10000`, and `10001` wei, plus fractional human-unit amounts and `uint256.max` in an isolated arithmetic harness.

At the same sampled price `q`, test:

| Gross input | Expected behavior |
|---|---|
| 0 | Revert |
| `q - 1` | Revert, including the zero case when `q == 1` |
| `q` | One ticket when output is representable |
| `2q - 1` | One ticket |
| `2q` | Two tickets |
| `10q` | Ten tickets and at most 690 seconds |
| Huge valid multiple | Correct total count, at most ten seat writes, capped time |

Never form an overflowing test input such as `10q` without bounding `q` first.

Check the following baseline launches:

| Gross IBCO / mixETH | Initial pot | Ticket and active minimum |
|---:|---:|---:|
| 50 | 5 | 0.0005 |
| 125 | 12.5 | 0.00125 |
| 250 | 25 | 0.0025 |
| 500 | 50 | 0.005 |
| 1,000 | 100 | 0.01 |
| 2,000 | 200 | 0.02 |

Add an IBCO small enough to produce a ticket below `1e12 wei`. For example, a gross `0.01 mixETH` launch produces a `1e11 wei` initial ticket. Exercise the exact minimum through a real V4 PoolManager.

Test initial pot inclusion, buy-fee growth, sell-fee growth, and unaccounted token donations. A raw token transfer must not change the price unless existing accounting explicitly accepts it into the pot.

Test sampling before the buy's own fee. An exact one-ticket buy must not lose its ticket because its fee increases the pot during execution.

### 8.3 Purchase paths and state transitions

Exercise direct V4 buys, ordinary mixETH zaps, referral purchases, owner-attributed buys, single reinvestment, and batch reinvestment. Cover both currency address orders. If an ETH wrapper remains supported, its resulting mixETH amount must face the same hook rule.

Test price changes between quote, approval, and purchase. Include multi-ticket intent protection, caller identity, deadlines, min-PSP output, and rollback after rejection.

Preserve and extend these tests where relevant:

- `test/unit/ClockDetonation.t.sol`
- `test/RealV4Lifecycle.t.sol`
- `test/ReinvestAttribution.t.sol`
- `test/ReferralPurchase.t.sol`
- `test/ReferralRewards.t.sol`
- `test/MultiOwnerStateful.t.sol`
- `test/unit/Factory.t.sol`
- `test/unit/StagedGenesis.t.sol`
- `test/unit/DeploymentScripts.t.sol`
- Deployment gas and creation-code tests

Update old zero-ticket active-buy tests: in v3, a below-ticket active purchase now reverts. Preserve their old behavior only in explicit legacy tests.

Update stateful handlers to derive amounts from the current ticket price. Include successful operations and targeted rejected operations. Do not configure a handler so that most actions merely revert without exercising the state machine.

Keep `fail_on_revert = true` where the harness requires successful generated actions. Use explicit rejection tests for invalid inputs. Preserve meaningful conservation assertions across curve backing, pot, staker liabilities, referral credits, and deployer credits.

Use `skip` or anchored absolute warps according to `AGENTS.md`. Avoid the known via-IR timestamp common-subexpression issue.

## 9. Test client behavior and compatibility

Add or update frontend tests for:

- Correct v3 decoding and preserved v1/v2 formulas.
- Unknown-version rejection and retryable RPC failures.
- All ten milestone markers and full-domain v3 price samples against real contract tuples.
- Dynamic ticket/minimum updates after buys and sells.
- No immutable cache of the dynamic minimum.
- Exact bigint one-ticket inputs below 0.005 and below `1e12 wei`.
- Correct decimal formatting for very small prices.
- Reinvestment eligibility against live single and aggregate fee balances.
- Approval-time pot changes and signed ticket guards.
- Any-positive predeposits, including historical version fallbacks.
- Old-round claims, withdrawals, redemptions, and referral reward claims.
- No use of the new rules to decode historical deployment state or events.

Run browser checks on both active UIs at desktop and mobile widths. Check the predeposit page, buy controls, ladder price, clock estimate, stake/reinvest controls, and graveyard exits.

Use a fresh local deployment for interactive verification. Test rejection, a successful one-ticket buy, a multi-ticket buy, and a price update after a sale. Confirm receipts rather than assuming transaction submission succeeded.

Do not use display-only JavaScript floats for token amounts, minimum outputs, or ticket counts. On-chain quotes remain authoritative.

## 10. Run the gates and the local lifecycle

Use focused tests during development. When the implementation is coherent, run the complete deterministic gate:

```sh
bash scripts/check-audit.sh
```

It currently includes:

```sh
forge test --no-match-path 'test/integration/*'
node script/gen_expanded_art.mjs --check
node script/expanded-art-fixtures.mjs --check
bash scripts/check-no-governance.sh
python3 scripts/check-sizes.py
python3 scripts/sine_oracle.py --check
node --experimental-strip-types frontend/scripts/check-abi.mjs
node --experimental-strip-types --test frontend/tests/*.test.mjs
node --experimental-strip-types --test scripts/names/*.test.mjs
```

The gate also runs the frontend TypeScript and Vite build. Add coverage for new generators or helpers without removing existing checks.

Explicitly build the alternate frontend too:

```sh
cd frontend
npm run build:alt
```

Return to the repository root before root commands.

Update and run the local lifecycle script:

```sh
bash scripts/anvil-ticket-e2e.sh
```

That script currently starts a fresh local Anvil and uses a disposable development key. Inspect its RPC target before running. Never replace its local endpoint with a public network for this task.

The updated lifecycle must cover:

1. Fresh deployment with every creation receipt successful and every production contract under size limits.
2. A 500 mixETH IBCO and a second round with a different IBCO size.
3. One-ticket and multi-ticket buys, a below-ticket rejection, sell-driven ticket growth, and owner-attributed reinvestment.
4. Advancement through all ten waves and beyond the target within the supported domain, with contract/oracle/client agreement.
5. Clock expiry, rejected post-expiry trades, detonation, pot claims, full old-round exits, and resumable successor birth.

Use snapshots or separate scenarios where a deep-reserve stress branch would prevent the rest of the lifecycle from completing. Verify rollback when an expected failure occurs.

Measure gas for launch, representative buys, sells, deep-range trades, detonation, and all birth steps. Measure both runtime and creation code. A mock-only unit test is not evidence that production CREATE or V4 execution succeeds.

Use a supported local script configuration. If the old lifecycle script assumes linear scaling or allows zero-ticket buys, update those assertions to this specification before treating its result as evidence.

Run the relevant full gate again after fixes uncovered by local lifecycle or browser tests. Do not report a green gate from a revision that predates the final code changes.

## 11. Update documentation and deliver a reviewable result

Update `docs/FINAL-SPEC.md`, the top of `docs/audit/READINESS.md`, and relevant current explanations. Add a dated implementation and numerical-validation note. Append actual results to `GATE-LOG.md`.

Document:

- The complete signed cube-root sine formula and its units.
- The 500/450/955/10,000 calibration and the 1,000-times launch-price reference.
- Square-root scaling of additional backing.
- Genesis allocation from the same cumulative curve.
- Pot-based ticket pricing, integer ceiling, one-wei zero-pot behavior, and minimum equal to one ticket.
- Pre-own-fee sampling, gross purchase semantics, and the unchanged fee split.
- Version boundaries and legacy behavior.
- Supported arithmetic ranges, approximation errors, gas limits, and any capacity changes from previous releases.
- The effect on IBCO discounts and supply allocation across round sizes. Do not claim constant dilution across IBCOs.
- Tests and local receipts actually observed, with reproducible commands.

Leave historical deployment manifests, hosted artifacts, and old audit findings intact. Mark new rules as source/local changes until a separate authorized deployment occurs.

The final report must state what changed, why, how it was tested, and any remaining material limitation. Include exact test counts, size results, gas measurements, local lifecycle results, and file links. Report failures plainly. Do not claim a security certification from a passing test suite.

Complete the authorized implementation and checks. Do not stop after producing a plan, changing only chart formulas, or updating only hook constants. If an actual mathematical conflict prevents the specified behavior, isolate it with a reproducible case and explain the concrete decision required.

## Completion checklist

- One price formula governs both prelaunch and active reserves.
- The softened cube-root milestones match the independent oracle.
- Ten waves reach 1,000 times launch price at 10,000 backing for the 500 baseline.
- Additional backing scales by square root of actual launch backing.
- Genesis supply, buys, and sells use the same cumulative curve and safe inverse.
- Settlement work is bounded and production code passes unchanged size gates.
- The ticket uses the entire accounted pre-purchase pot.
- The active minimum equals one ticket, including below historical minima.
- Every successful active buy earns at least one ticket.
- Quotes, routers, referrals, reinvestment, and both frontends use the new live rule.
- Legacy read paths and old-round exits remain valid.
- Independent oracle, regression tests, invariants, full gates, browser checks, and local lifecycle pass on the final source.
- No public deployment, publication, live-address change, or unrelated cleanup occurred.
