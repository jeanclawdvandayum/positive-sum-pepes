# Single-sine v3 numerical review — September 15, 2026

Do not approve this branch for release. The review found a serious sell underpayment and two failures of required monotonicity. The contained inverse repair passes its regressions. Supply and price monotonicity remain unresolved.

The review started from `a80984c8`, with `e8d24e4f` as the implementation baseline. It compared the implementation against the September 14 handoff. No public deployment occurred. Most probes used copied source and a disposable Anvil at port 18547.

## Findings and status

| ID | Priority | Function | Status |
|---|---|---|---|
| V3-R3 | P1 | `SineV3Math._reserveAt` | Fixed: exhausted Newton search could pay almost nothing for a valid sale |
| V3-R1 | P2 | `SineV3Math._F` / `supplyWad` | Open: cumulative supply can decrease when reserve increases by one wei |
| V3-R2 | P2, spec blocker | `SineV3Math._exponentAt` / `priceWad` | Open: rounded price can decrease when reserve increases by one wei |
| V3-R4 | P2, spec blocker | `_checkDomain` / controller capacity validation | Open: fixed table boundaries are presented as arithmetic limits without proof |
| V3-R5 | Verification defect | `SineV3OracleTest.test_Fixtures` | Fixed tolerances; broader independent coverage remains incomplete |

No profitable extraction was proved from V3-R1 or V3-R2. Their observed errors are small. Their significance is the failure of explicit settlement assumptions and binding tests. V3-R3 causes a large relative loss to a seller and needs separate treatment.

## V3-R3 — unresolved Newton bracket underpays a valid sale

Location: `src/SineV3Math.sol`, `_reserveAt`, now lines 263–299.

The original loop allowed Newton steps for all 128 iterations. An interior candidate does not guarantee enough bracket contraction. The loop then returned its upper bound even when that bound remained far from the solution.

Concrete original-bytecode inputs:

```text
boot = 1,000,000,000,000 mixETH wei
lambda = 45,019,131,735,543,525 mixETH wei
launch price = 75,000,000,000,000
reserve = 2,836,206,299,339,242,075 mixETH wei
phase = 63 complete waves
PSP sold = 1,000,000,000,000 PSP wei
Q(reserve) = 483,845,600,008,163,639,340 PSP wei
```

The hook permits the stated sell input. Original `sellOut` returned **5,861,800,334 mixETH wei** before fees. Independent binary search of the same on-chain cumulative function returned **1,690,898,741,711,268 mixETH wei**. The spot clamp permits **1,690,916,039,850,745 wei**, so it does not explain the shortfall.

The seller loses more than 99.9996% of the expected curve payout. The original search exhausted 128 iterations with a bracket **1,690,892,880,082,565 reserve wei** wide. The spot clamp only reduces payouts. It cannot repair an underpayment.

A second case at wave 32 returns 2,977,509,581 wei instead of 19,309,571,239,079 wei. At wave 64, another exhausted search underpays by 59,196 wei. These are distinct depths with the same root cause.

The state is reachable through normal funded routes:

1. Deposit 1,111,111,111,111 mixETH wei into a fresh IBCO.
2. Launch it. The 10% genesis fee leaves exactly 1e12 backing wei.
3. Buy with 3,151,339,221,488,046,750 mixETH wei.
4. Sell 1e12 PSP wei after that buy.

The buy reaches the stated reserve under the initial 10% fee. The buyer owns enough PSP for the sale. The new real-V4 regression executes this sequence and checks the fixed output, quote, balance delta, reserve debit, and gas.

### Contained repair

The code now permits at most 16 Newton steps. It then forces bisection. It also removes the early return from a supply plateau. An unresolved final interval reverts with `SineV3InverseDidNotConverge`.

The factory range gives a concrete iteration proof. Write `C = (955e18)^2 / 450e18` in wei. The wavelength satisfies `lambda^2 <= C * boot`. The accepted prelaunch domain requires `boot <= 16 * lambda`. Thus:

```text
lambda <= 16*C
boot <= 256*C
reserve <= boot + 64*lambda <= 1280*C
reserve <= 5*(16*955e18)^2/450e18 < 2^82 wei
```

After at most 16 Newton steps, 112 forced bisections remain. Only 82 are necessary for any currently accepted factory reserve width. Wider arbitrary helper arguments fail closed if they exhaust this budget. A regression covers that failure path.

This proves termination and the final endpoint check for the current supported width. It does not repair the global monotonicity assumption. If the supported domain expands, update this proof and its gas limits together.

## V3-R1 — cumulative supply decreases inside a partial cell

Locations: `src/SineV3Math.sol:192`, `:212`, and `:109`.

`_F` changes every quadrature node when the partial interval changes. The integer density evaluations can move by enough to make the resulting partial integral decrease. Clamping that integral between two knots prevents overshoot. It does not make its interior evaluations monotone.

The defect occurs within the main 500-mixETH calibration, before the tenth wave:

```text
boot = 450,000,000,000,000,000,000
lambda = 955,000,000,000,000,000,000
launch price = 75,000,000,000,000
R = 4,986,249,999,999,999,998,089
Q(R)   = 17,671,194,694,734,242,672,866,666
Q(R+1) = 17,671,194,694,734,242,660,133,333
loss = 12,733,333 PSP wei
```

Both coordinates lie inside the partial cell immediately below phase 4.75. This is not a mismatch between two different economic curves.

A larger accepted launch amplifies the same defect:

```text
boot = 100,000,000,000,000,000,000,000
lambda = 14,236,299,456,748,661,067,138
R = 167,622,422,419,556,140,040,432
Q(R)   = 97,770,880,328,780,142,869,233,225,775
Q(R+1) = 97,770,880,328,780,142,869,043,408,449
loss = 189,817,326 PSP wei
```

The first drop is about 0.0000000000127 PSP. That does not establish material extraction through a complete trade. It does disprove the required nondecreasing cumulative function. Endpoint algebra still telescopes, so a telescoping test alone cannot detect this defect.

The two required assertions remain failing in `test/SineV3ReviewRegression.t.sol`. Do not relax them or exclude them from the release gate.

## V3-R2 — rounded price decreases

Locations: `src/SineV3Math.sol:99`, `:230`, and `:307`.

With the baseline boot, wavelength, and launch price:

```text
R = 16,207,499,999,999,999,999,999 mixETH wei
P(R)   = 613,048,911,149,785,684
P(R+1) = 613,048,911,149,785,681
```

This is the phase-16.5 quarter-wave boundary. The decrease is three price units, about 4.9e-18 relative. Additional baseline probes found decreases of 65, 707, and 2,740 price units at later boundaries.

The signed sine, floored cube root, cancellation identity, multiplication, and exponential form one rounded composition. A proof about their real-valued formula is insufficient.

A direct-root experiment replaced the quotient identity with `cbrtWad(1+abs(s))-WAD`. A 100,000-case adjacent-coordinate fuzz campaign still found a price decrease. That experiment was confined to `/tmp` and is not an accepted repair.

## V3-R4 — fixed table boundaries do not establish arithmetic capacity

Locations: `src/SineV3Math.sol:181`, `src/RoundController.sol:390`, and the knot generator's `XMIN` / `XMAX`.

The implementation fixes the table to phase -16 through +64. This limits net IBCO backing to about 518,840.888889 mixETH. At the 500-mixETH baseline, the upper reserve limit is 61,570 mixETH.

These limits follow from the selected table length. They do not follow from price representability, integer overflow, or a demonstrated gas limit. Independent Decimal examples show substantial headroom:

| Prelaunch span | Net boot / mixETH | Default origin price, WAD integer units |
|---:|---:|---:|
| 16 waves | 518,840.888889 | 10,563,753,297 |
| 32 waves | 2,075,363.555556 | 291,306,312 |
| 64 waves | 8,301,454.222222 | 2,959,383 |
| 100 waves | 20,267,222.222222 | 81,593 |

The default origin-price envelope approaches one price unit near 295 prelaunch waves, around 176 million mixETH of net backing. That envelope neglects the bounded sine displacement. It is illustrative headroom, not a proof that the full settlement stack supports that range.

The accepted custom launch price also changes the true representability limits. A single price-independent 16-wave cutoff cannot establish those limits for every accepted configuration.

The +64 endpoint has default price **1,900.733801594627 mixETH per PSP**, not the documented approximate 1,927. At +128 the same formula gives about 643,418.136 mixETH per PSP. That number remains representable. A new evaluator would still need to prove supply precision, small outputs, type bounds, and gas there.

Do not remove the guard alone. The generated knot dispatcher returns its last leaf for excessive indexes. Without a new evaluator, out-of-range cumulative supply would silently flatten.

The handoff permits justified arithmetic limits. It does not approve a new fundraising cap selected solely by a table's length. The limit needs a numerical design and explicit justification before release.

## V3-R5 — oracle tolerances and coverage

The original price assertion passed `1e11` to Foundry's WAD-relative tolerance. That permits 1e-7 relative error, although the comment promised 1e-11. The original supply assertion allowed 1e12 PSP wei of absolute error. That swallowed the complete 13,333-wei one-wei genesis fixture.

The updated test uses:

```text
price error <= expectedPrice / 100_000_000_000 + 1 price unit
supply error <= expectedSupply / 1_000_000_000 + 1 PSP wei
```

The one-unit allowance covers final integer rounding. All 24 existing fixture rows pass these stricter checks. That does not expand their coverage.

The generator uses 70-digit Decimal GL16 for knots and converged tanh-sinh integration for fixture supply. The integration method is independent of the on-chain GL8 method. Fixture construction and knot construction share the same high-level density implementation. The code does not import Solidity output into the reference.

The current fixture set lacks independent buy and inverse vectors across the full supported range. It also lacks near-cap fixtures, broad custom-price coverage, and systematic checks of every cell's nearby coordinate steps. The test named `test_AdjacentWeiMonotone` samples nine locations at one boot. It does not test every boundary.

## Repair architecture for the open numerical defects

A new monotone primitive is a concrete candidate. This is a design proposal, not a validated implementation:

1. Generate a cumulative polynomial for each canonical interval, independently checked against the Decimal integral.
2. Express its normalized cumulative values as Bernstein coefficients ordered from zero through one.
3. Evaluate them with integer de Casteljau steps: `left + mulDiv(right-left, t, scale)`.
4. Scale the result by the interval's positive cumulative span and add its canonical starting knot.
5. Prove coordinate conversion, coefficient ordering, every interpolation step, and final scaling preserve monotonicity.

Ordered coefficients give a monotone polynomial. The stated interpolation operation is monotone in its two endpoints and in the interpolation fraction. Induction can extend that property through the integer evaluation. Coefficient quantization must preserve order. Shared endpoints must use exactly equal integers.

Price needs its own proof. Options include a monotone approximation to the signed log-price map, or a stable monotone construction of the phase map and root. A small absolute approximation bound must preserve the required relative price accuracy and the geometric payout bounds.

More coefficients increase deployment data. Immutable code shards or another bounded, authenticated data layout can hold them. The implementation must measure deployment size, creation gas, lookup cost, and swap gas. No mutable table or off-chain update may define settlement.

For the expanded domain, assess a multiscale immutable approximation or a certified tail evaluator. A closed-form envelope can help bound a tail integral. It must not silently replace the selected sine curve. Local trade differences need strict error bounds even when the cumulative tail looks flat.

A simple alternative remains unsafe: integrate from the nearer cell endpoint. That experiment fixed the known pin but failed a 50,000-case adjacent-coordinate supply campaign. Global relative error and spot clamps do not establish integer monotonicity.

## Observed checks

Repository checks after the inverse repair:

```text
forge test --match-contract 'SineV3(Oracle|InverseLifecycle|Economics)Test' -vv
13 passed, 0 failed
  Oracle: 6
  Economics: 6, including 256 roundtrip fuzz runs
  Real V4 inverse lifecycle: 1
Real V4 repaired small-sale gas: 6,372,725
```

Review regression suite:

```text
forge test --match-path 'test/SineV3*ReviewRegression.t.sol' -vv
3 passed inverse regressions
3 failed required monotonicity assertions
```

Additional isolated probes included every sampled quarter boundary across five launch sizes. They found the stated price and supply decreases. A 10,000-case sell endpoint campaign found no overpayment relative to the evaluated cumulative function. A 291-case inverse search probe found three exhausted original brackets. Those limited observations are not a security certification.

Changed files in this review lane:

- `src/SineV3Math.sol`: contained inverse repair and explicit open-issue comments.
- `test/SineV3ReviewRegression.t.sol`: inverse regressions and required failing monotonicity assertions.
- `test/SineV3InverseLifecycle.t.sol`: funded real-V4 payout regression.
- `test/SineV3Oracle.t.sol`: corrected numerical tolerances.

The knot table, generator, and economic formulas remain unchanged. The parent review coordinates the final gate and any other branch changes.

Writing check: 0.71 findings per 100 words.
