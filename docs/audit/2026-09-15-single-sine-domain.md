# Sine v3 numeric domain derivation

This note derives limits from price and token precision. The controller now admits a predeposit aggregate only when its launch supply can give every positive share a nonzero allocation. These are arithmetic limits, not fundraising or wave-count rules.

## Constants and units

- `p`: launch price in WAD price units; the factory accepts `1e9 <= p <= 1e18`.
- `b`: net launch reserve in mixETH wei.
- `lambda = floor(sqrt((955e18)^2 * b / 450e18))` in mixETH wei.
- `x = (R-b)/lambda` in waves.
- `K = ln(1000)/(cuberoot(11)-1)`.
- `a = 1/(2*pi) < 0.159155`.
- `C = 955^2/450 = 2026.722222...` in mixETH.
- `s(x) = x-sin(2*pi*x)/(2*pi)`.

The price, before integer rounding, is `p * exp(K * H(s(x)))`. The supply in PSP wei is `(lambda/p)*1e18 * (F(x)-F(x0))`.

## Negative phase and launch capacity

Require the actual on-chain opening price at reserve zero to be positive. An aggregate that fails this check must fail before the deposit or carry is recorded.

Let `y=b/lambda`, so the opening phase is `-y`. Since `s(y) >= y-a`, a positive opening WAD price requires:

```
y <= yMax(p) = a + (1 + ln(p)/K)^3 - 1
```

This is a conservative analytic bound; the actual rounded evaluator supplies the final acceptance check. Add the price approximation's exponent error to `ln(p)` when generating the bound. An error below `1e-12` leaves the rounded bounds below unchanged. Integer wavelength rounding decreases lambda and therefore does not invalidate the upper bound on boot inferred below.

At the full factory price ceiling, `p=1e18`:

```
yMax < 580.062977
b < C*yMax^2 < 681,937,421 mixETH
lambda < C*yMax < 1,175,627 mixETH
```

A generated negative table ending at a canonical boundary below `-580.062977` covers every potentially admissible launch. The selected boundary, `-580.5`, derives from the price-precision limit. Calls outside that table still need explicit range errors. The controller validates the actual helper quote. The helper rejects an opening price of zero. The old sixteen-wave `BOOT_NET_MAX` rule is removed. It was private, so its removal changes no external ABI.

Approximate zero-price boundaries without the sine displacement are:

| p, WAD price units | negative waves | net boot, mixETH |
|---|---:|---:|
| 1e9 | 100.975 | 20,664,180 |
| 75e12, default | 294.532 | 175,816,868 |
| 1e18 | 579.904 | 681,563,259 |

Use the conservative bounds or the actual integer evaluator in checks. Do not treat these approximations as exact accepted maxima.

## Positive tail bound

For positive `x`, replace `s(t)` by its lower envelope `t-a`. Since price rises with its argument, this gives an upper bound on all remaining reciprocal-price area:

```
u = cuberoot(1+x-a)
T(x) = integral_x^infinity exp(-K * H(s(t))) dt
     <= 3 * exp(-K*(u-1)) * (u^2/K + 2*u/K^2 + 2/K^3)
```

For the factory wavelength, `lambda/p <= C*yMax(p)*1e18/p`. This expression decreases over `1e9 <= p <= 1e18`: differentiate its cubic in `ln(p)` times `1/p`; the derivative is negative at the lower endpoint and remains negative. Thus the maximum occurs at `p=1e9`:

```
lambda/p < 204,969,950,176,592
(lambda/p)*1e18 < 2.05e32
remaining PSP wei <= 2.05e32*T(x)
```

Conservative remaining supply, across every launch accepted by the price rule:

| positive phase | remaining PSP wei, upper bound |
|---:|---:|
| 3399 | 0.994464 |
| 3400 | 0.986416 |
| 3997 | 0.009971 |
| 4000 | 0.009755 |
| 4096 | 0.004867 |
| 4500 | 0.000292 |

A table ending at a canonical boundary with a certified tail and evaluator error below one PSP wei is a numeric capacity limit. The selected endpoint is 4096 waves. The margin must account for all endpoint errors. A tail below one wei does not mean rounded cumulative supply is literally constant: it can cross one integer boundary. It does mean an otherwise exact endpoint difference in this tail is at most one PSP wei. The existing one-wei buy haircut makes such a trade unmintable.

Do not clamp cumulative supply to a manufactured asymptote. Keep canonical endpoints through the last supported boundary, reject unsupported buys before state changes, and retain all sell and death paths from every accepted state.

## Higher precision cumulative supply

For an `F` table with scale `1e36`, use:

```
supplyWei = fullMulDiv(lambdaWei, spanF36, pWei*1e18)
```

One F36 unit changes unrounded PSP supply by at most `0.000205` PSP wei across every allowed launch. Two independently floored endpoints contribute less than `0.000410` PSP wei of error. This bound covers table quantization only, not polynomial or coefficient approximation error.

The worst negative F magnitude has the loose bound `580.063*1e18*1e36 < 5.801e56`, which fits signed 256-bit arithmetic. The denominator is at most `1e36`. A 512-bit multiplication is required when scaling endpoints.

If the generator or price evaluator computes reciprocal density, do not compute WAD density and multiply the result afterward: that already loses the tail. One valid scaling is:

```
density36(x) = expWad(ln(1e18) - exponent(x))
```

Its numerical output equals `floor(1e36*exp(-exponent(x)))`. Higher internal scale may be needed for coefficient generation before conversion to F36.

## Reserve, supply, swap, and inverse bounds

With coverage ending at positive phase 4096, all accepted factory reserves are below about `5.497e27` wei, below `2^93`. The inverse first finds a canonical cell with a binary search of the immutable knots. It then searches reserve wei inside that cell. The widest cell spans one wavelength, with at most one extra wei from endpoint rounding. The wavelength bound puts that interval below `2^80`. The implementation permits 256 binary contractions and checks the final bracket. It prepares the cell controls once, then reuses them throughout the search.

The inverse predicate is exact: `floor(lambda*(F-f0)/(p*1e18)) >= q` if and only if `F >= f0 + ceil(q*p*1e18/lambda)`. The search returns the first reserve wei that satisfies this predicate. With monotone F, this gives a conservative sale. A buy mints fewer PSP wei than its cumulative supply increase. Selling that minted amount therefore leaves a reserve strictly above the reserve before the buy. The independent spot-price upper bound can only reduce the payout further.

Because every supported price is at least one WAD price unit, the loose supply bound is `Q(R) <= R*1e18`. This fits uint256 by a wide margin in these reserve domains. Genesis supply can exceed signed128, but genesis minting, allocation, and staker weights use uint256. Do not invent a signed128 genesis limit. Active V4 input and output deltas retain their existing signed128 bounds and must reject before casts. Large positions can use multiple active sells, and direct redemption after death retains uint256 quantities.

The actual launch path must be tested at lower and upper accepted aggregates: helper quote, opening price, nonzero Q, initial mint, genesis lock, allocation claim, activation, buy, sell, death, fee/pot claims, and redemption. Include all pL endpoints and one-wei launch. Donations exceeding capacity must not block successor birth; failed carry remains unaccepted by the successor.

## Genesis allocation admission and proof

`RoundController._validateBootstrap(totalBoot, shareDenominator)` now requires the helper to return a nonzero genesis supply `Q` with `Q >= shareDenominator`. Every successful later deposit, carry share, or bonus runs this check again before its accounting is recorded. Aggregate addition overflow has an explicit capacity error. Token transfers revert with the entire transaction when admission fails.

The distinction between the two factory funding routes is preserved:

- `seedCarry` records a predeposit in the factory's name. It creates shares and increases the denominator.
- Legacy `potDeposit` adds only `carryBonusMixETH`. It creates no shares and keeps the denominator unchanged.

For any recorded contributor amount `d >= 1` and denominator `D >= d`, the claim is `floor(Q*d/D)`. Admission requires `Q >= D`, so the claim is at least `d`, and therefore at least one PSP wei. Each claim is at most `Q`. The sum of independently floored shares is at most `Q`, so the genesis lock cannot run out before all contributors claim. The use of `Math.mulDiv` preserves the product without a 256-bit intermediate overflow. Genesis minting, the virtual lock, global weight, account principal, and direct redemption all use uint256.

At the maximum custom launch price, a ten-wei gross pool has a one-wei genesis fee and can produce only nine PSP wei. Such an aggregate cannot promise a positive proportional allocation for every positive contribution. It is rejected before funds or shares are recorded. A one-wei launch remains admitted, including at this custom price. A bonus that creates no shares can still enlarge a pool when the existing denominator remains representable. The default launch price has much more PSP precision per mixETH wei.

The dedicated test file is `test/SineV3BootstrapCapacity.t.sol`. It covers one-wei default and custom launches, rollback of a later deposit or carry that would erase a prior allocation, bonus funding without shares, and refusal of a zero genesis quote. Its large-pool cases run the factory, controller, token, staker, and real V4 PoolManager through launch, a one-ticket buy, sale, fee and pot claims, death, and full redemption. The large cases include both factory price endpoints and supplies above the V4 signed128 swap limit. Test results are recorded in the final gate log; this note does not substitute a source inspection for a passing run.

## Independent local supply oracle

`scripts/sine_v3_small_reserve.py` generates 150 fixtures with 90-digit Decimal arithmetic. It integrates the reciprocal analytical price with composite Simpson quadrature, then doubles the panel count to check convergence. It imports no settlement code, curve generator, coefficients, or data tables. The largest whole-versus-halves difference is `6.0845e-35` relative.

The fixtures use opening phases near -16, -17, -64, -100, -290 and -579, at both exact waves and a 0.37-wave offset. They cover all admissible launch-price endpoints and reserves of 1, 2, `1e6`, `1e12` and `1e15` mixETH wei. `test/SineV3SmallReserveOracle.t.sol` permits an error of `1e-9` relative plus one PSP wei. These local integrals test accuracy that a large cumulative-supply comparison can hide, including loss of small reserve changes during phase conversion.

## Required proof and tests

1. Derive table coverage constants in the deterministic generator from the price and tail inequalities. Check exact generated output.
2. Prove monotone price and F interpolation under integer evaluation, including endpoint joins and coefficient rounding.
3. Bound approximation error separately from one-unit table quantization. Use an independent high-precision integration method.
4. Test both sides of the first rejected launch and positive reserve endpoints. Verify atomic rollback.
5. Test the final supported buy, all remaining sell routes, and death/redemption at the highest accepted state.
6. Sample tiny buys near cumulative plateaus. Require a positive output where the integer curve and existing haircut permit it.
7. Measure worst inverse and table access gas with actual contract calls. Shards and helpers must remain immutable, identity-checked, size-gated, and deployed by the normal scripts.
