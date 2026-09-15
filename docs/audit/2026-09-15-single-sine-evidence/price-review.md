# Monotone single-sine price repair

The new price library resolves the rounded-price order defect without a wave-count limit. It preserves the selected single-sine, softened cube-root formula within the required price tolerance. This report covers the price evaluator only. The parent review owns supply, settlement, launch capacity, integration, and the final release gate.

## Changed files

- `src/SineV3Price.sol`: monotone phase, cube root, exponential, marginal price, and scaled reciprocal density.
- `scripts/sine_v3_price.py`: independent Decimal coefficient checks, error bounds, and fixture generation.
- `test/SineV3PriceFixtures.sol`: 117 generated independent price vectors.
- `test/SineV3MonotonePrice.t.sol`: eleven focused tests, including three fuzz properties.

The existing main helper and supply generator were not changed in the price lane. The library also exposes `exponentAtPhase` and `densityAtPhase`, so fixed canonical nodes can use independently checked phase offsets without repeating the periodic polynomial.

## Integer order proof

1. The periodic primitive is approximated on two quarter waves. Each polynomial has nondecreasing Bernstein controls. The first ends at the exact same integer control where the second starts. Their endpoints at zero and one-half are exact.
2. The evaluation uses `a + floor((b-a)*t/1e18)`. For ordered endpoints, this operation is monotone in each endpoint and in `t`. Adjacent interpolated controls remain ordered. Induction proves monotonicity at every evaluation level, including adjacent integer inputs.
3. Exact reflection covers the second half wave. Exact integer addition covers whole waves. Odd reflection covers negative coordinates. The shared endpoints preserve order at quarter, wave, and sign boundaries.
4. The integer cube root is `FPML.cbrt((1e18 + abs(s))*1e36)`, which returns the exact floor. Subtracting the constant `1e18` preserves order. This avoids the non-monotone quotient that used a separately rounded denominator. Multiplication by the positive fixed `K` and signed reflection preserve order.
5. The exponential reduces its argument to `k=floor(e/ln2Wad)` and `r` in `[0,ln2Wad)`. A degree-20 Taylor polynomial with positive coefficients evaluates the reduced exponential at precision `1e36`. Every floored Horner operation is monotone.
6. The reduced polynomial is below two at the right endpoint and exactly one at zero. The transition to the next exact power of two cannot decrease. Positive exponents shift the original scale before final division; negative exponents divide and then shift. Both paths preserve order and final integer precision.

This proof concerns the exact integer operations in the implementation, rather than only the corresponding real-valued formula.

## Error and arithmetic bounds

The first quarter uses the sine Taylor expansion through degree 17. The second uses the cosine expansion through degree 18. Alternating remainder bounds, endpoint correction, control quantization, interpolation rounding, and final phase conversion give an absolute phase error below `1.5e-14` waves.

The softened cube-root derivative is at most one-third. The phase error therefore contributes less than `2.9e-14` to log price. Exact root rounding contributes less than `6e-18`. The stored growth constant and exponential range reduction add smaller errors throughout the representable output range. The total relative price error before the final floor is below `4e-14`.

The tests retain the stronger original requirement:

```text
absolute price error <= expected price / 100,000,000,000 + 1 integer price unit
```

The library accepts signed phase magnitudes up to `uint256.max/1e36 - 2e18`. This guard follows from the exact root radicand multiplication. It is not an economic wave limit. Exponential overflow fails closed. An exponential result of zero reports underflow at the requested scale; the calling helper must reject a state when a positive price or density is required.

`scaledExp` accepts scales up to `uint256.max/2`. That bound prevents the intermediate negative-exponent result from overflowing before its final division by a power of two. The active launch-price range and density scales through `1e54` fit this bound.

The evaluator supports positive phases of 4,096 and 10,000 waves. High-precision reciprocal density remains positive at 10,000 waves with scale `1e54`. This statement establishes evaluator capacity only; the supply and settlement domains still require their own proof.

## Observed tests

The isolated Foundry project copied only the new price library, its test, and its fixture file. It used the repository's pinned Solidity 0.8.26, optimizer, via-IR, Cancun settings, and vendored dependencies. Its cache and output remained under `/tmp` to avoid races with the parent gate.

Command:

```sh
FOUNDRY_FUZZ_RUNS=100000 forge test --root /tmp/psp-price-isolated -vv
```

Result: **11 passed, 0 failed, 0 skipped**. The campaign completed in 56.90 seconds.

- 100,000 adjacent exponent pairs, including high-precision density scales.
- 100,000 adjacent phase, exponent, and price pairs across -1,000 through +10,000 waves, with custom launch prices.
- 100,000 distant ordered coordinate pairs across the same range.
- 117 independent 90-digit Decimal price vectors, including all ten milestones, negative phases, the original failure seams, beyond 64 waves, and three launch prices.
- Exact quarter, wave, sign, and binary-exponential boundary checks.
- A custom-price precision case that detects premature rounding before positive binary scaling.
- Explicit arithmetic overflow and underflow checks.

The coefficient checker also passes:

```sh
python3 scripts/sine_v3_price.py --check
```

The external test harness runtime is 2,875 bytes. A typical marginal-price call costs approximately 60,000 gas. Whole-system code size and swap gas must be measured after integration.

Logs: `/tmp/psp-price-final-review.log`. No commit or public deployment occurred.

## Adversarial follow-up

The follow-up checked signed minimum inputs, the exact cube-root radicand capacity, and both signs at that boundary. It also checked binary scaling with `scale=uint256.max/2`, the last representable positive shift, the first invalid shift, and the first reduced exponential that makes an otherwise valid shifted scale overflow. All such regression assertions passed.

For positive binary scaling, `scale << k` is guarded before shifting. Since the normalized exponential is at least one, a shifted scale that does not fit cannot produce a valid final result. A shifted scale can fit while its final product does not; checked `fullMulDiv` rejects that case. For negative scaling, the normalized exponential is below two, so the `scale <= uint256.max/2` bound makes the intermediate result safe. The final right shift is exact integer division.

For signed phase reflection, `int256.min` is rejected before negation. The phase magnitude guard leaves one extra wave for the periodic displacement and one for adding the root's constant. Thus `(1e18 + abs(s))*1e36` cannot overflow. The new direct primitive API repeats the exact radicand bound, so cached node inputs cannot bypass it.

The generator checks every phase control, every exponential coefficient, the stored growth constant, and the stored logarithm constant against independent Decimal calculations. It also regenerates all price fixtures and compares the complete file. The formatter was run before the final coefficient check.

Writing check: 1.83 findings per 100 words.
