# Independent primitive and settlement review

No open defect was found in the reviewed helper, primitive, and data snapshot. This finding applies to the source hashes below. The final repository gate must check later changes and full integration.

## Settlement and data checks

The reviewer traced the helper's canonical wavelength and launch-price checks before arithmetic and before external state changes. The buy capacity check subtracts the current reserve from the validated capacity before adding the spend. Thus an excessive spend fails before reserve addition or hook settlement.

The sell price envelope adds room for both approximation error and the final price floor. This matters when the opening price is near one integer price unit. The monotone cumulative inverse remains the binding payout calculation; the envelope can only reduce it.

The inverse uses the exact equivalence:

```text
floor(lambda * (F - F0) / (pL * 1e18)) >= qTarget
iff
F >= F0 + ceil(qTarget * pL * 1e18 / lambda)
```

Its knot search finds the first endpoint that reaches this target. The preceding cell has a lower endpoint below the target. The reserve bracket uses floor and ceiling on the exact rational cell positions, including negative phases. It caps the upper reserve at the caller's current reserve. Cached-cell bisection ends with an explicit adjacent-reserve check. Independent tests then compare the result against fresh calls to the canonical cumulative function, which may choose a different cell.

The reviewer checked signed conversions, radicand bounds, matrix products, signed matrix sums, cumulative subtraction, and the 512-bit multiply/divide operations. The factory domain keeps these values within their declared integer types. The negative-side records use 24 bytes; positive records use 16 bytes. Both fit the signed cumulative representation.

The helper constructor authenticates all four data shards by code hash and byte length, then stores their addresses immutably. Each shard starts with STOP and exposes no executable path that can change or destroy its data. No delegatecall, setter, or owner can replace these addresses.

Independent payload decoding confirmed:

- All four runtime hashes and lengths match `SineV3DataInfo`.
- The 4,938 signed knots are nondecreasing and the zero anchor is exact.
- Every record ends within one shard. The switch from 24-byte to 16-byte records and all shard boundaries align.
- Runtime sizes are 21,993, 22,001, 22,001, and 18,705 bytes, all below the EIP-170 limit.

## Independent numerical campaigns

The reviewer copied the six source files into an isolated Foundry project. It used the repository's pinned Solidity 0.8.26, Cancun, via-IR, optimizer, and vendored dependencies. It did not share build output or cache with the parent gate.

The first exhaustive loops reached Foundry's per-test gas allowance. The checks were then split into batches of at most 200 cells. The bounded version passed all 50 tests:

- Every one of the 4,937 cells has ordered integer cumulative controls, including cells with a zero rounded span.
- The boundary loop inspects all 4,938 anchors at a 680-million-mixETH net boot. Of these, 4,935 are strictly inside physical reserve space and pass `Q(R-1) <= Q(R) <= Q(R+1)`. The two lower anchors lie below reserve zero. The final anchor is the upper capacity endpoint. Permanent tests add separate one-sided checks at reserve zero and maximum reserve.

A second campaign passed 12 tests:

- 10,000 adjacent cumulative-supply pairs.
- 10,000 inverse cases, each checked against canonical `Q(r) >= target` and `Q(r-1) < target` when `r > 0`.
- One-wei and 1e12-wei burns, plus larger fractional burns, at waves 0, 1, 10, 32, 63, 64, 128, 512, 1,024, and 4,096.

The campaigns span one-wei, 1e12-wei, 450-mixETH, 100,000-mixETH, and 680-million-mixETH net boots. They include negative prelaunch phases, nonintegral reserve coordinates, and deep-tail supply plateaus. They found no decreasing cumulative output, invalid coefficient, or incorrect inverse endpoint in the tested cases.

The source reasoning establishes the integer order property. These campaigns check its implementation and boundary behavior; they do not replace the independent Decimal accuracy tests or complete economic lifecycle tests.

## Reproduction and snapshot

Original isolated logs:

```text
/tmp/psp-primitive-allcells-audit.log       50 passed
/tmp/psp-primitive-inverse-audit.log        12 passed, with two 10,000-case properties
```

The permanent `SineV3CanonicalInverse` suite preserves the bounded exhaustive cases and the canonical inverse property. Its fuzz distribution also targets tiny burns directly, since uniformly chosen supply targets rarely reach deep-tail inverses. The standard gate uses its configured fuzz count; use `FOUNDRY_FUZZ_RUNS=10000` for the larger campaign.

Reviewed SHA-256 source hashes:

```text
SineV3Math.sol        151c973eed985ce47db7b7926884268ef0636ec1fafc8e174cb6c00db144355b
SineV3Primitive.sol   2b0a2fa1c0f3db57676d5a197e405b9c061f2b3379067ff6576f6b4108113ca1
SineV3Price.sol       7a071d5e16aa1627d75a622bbce5808e04920073abc49a97ac9141346ac66b43
SineV3DataInfo.sol    ad088dca12fce4b731397042b72cc5d3860cf758e567e62b6102dd2e07a0a7af
SineV3Data.sol        62acf262e94fec37add5f0e9d2a301a16cd6c6dff21fa2db8cb8de27267ddefb
SineV3Bernstein.sol   10f1af5547e56bc65a0f0833f9827f9e4aeaa7b8f15bf2c202259152618570fa
```

No public deployment occurred.
