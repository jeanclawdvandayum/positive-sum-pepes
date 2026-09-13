# September 13 final spec

These rules apply to fresh deployments. Existing contracts retain their deployed rules.

## Timing and deposits

| Setting | Default |
| --- | --- |
| IBCO duration | 3 days, or 259,200 seconds |
| IBCO total cap | Uncapped, represented by `PREDEPOSIT_CAP() == 0` |
| Wallet cap | Uncapped by default |
| Maximum active clock | 69:04:20, or 248,660 seconds |
| Time per whole ladder ticket | 69 seconds |
| Withdrawal horizon | 28 days across six epoch boundaries |

The controller reports predeposit rules version 2. The UI treats a zero cap as unlimited only for that version. Older rounds keep their cap checks.

A large deposit cannot open the public launch early. Public launch becomes available after the window expires. Existing deposit behavior remains: deposits can continue until launch closes the pool.

The default protocol has public deposits and no wallet whitelist. Every wallet can deposit without a wallet cap. Constructor profiles retain the optional wallet cap for private playtests.

Constructor timing overrides remain available. The fields are predeposit duration, withdrawal duration, maximum active clock and optional wallet cap. Successor rounds inherit the profile. Their predeposit window starts at final wiring, even after a delayed respawn.

The withdrawal engine keeps its six steps. Each default epoch lasts 4 days and 16 hours. The actual wait is about 23 days and 8 hours to 28 days, depending on the request time. Detonation still opens every lock.

## Curve calibration

The curve uses the actual net IBCO backing. Ten percent of the gross IBCO still funds the pot. The other ninety percent forms the launch reserve, `b`.

The starting price remains 0.00001 mixETH per PSP. The opening ramp rises 7.5 times, reaching approximately 0.000075 at launch. This is slightly flatter than the previous 7.943-fold rise at a 450 mixETH net launch reserve.

The third wave reaches approximately 0.06 mixETH per PSP, or 800 times the launch price. The reserve target scales with the actual raise:

`targetReserve = b * 10,000 / 450`

| Gross IBCO / mixETH | Net backing / mixETH | Third-wave reserve / mixETH |
| --- | --- | --- |
| 50 | 45 | 1,000 |
| 500 | 450 | 10,000 |
| 5,000 | 4,500 | 100,000 |
| 50,000 | 45,000 | 1,000,000 |

These are curve coordinates, not forecasts. Prices still move down when reserves decrease. The wave continues beyond the third-wave target within the supported arithmetic range.

Deployment parameters retain the five-field ABI. They now describe a reference curve at 450 mixETH of net backing. The default reference `preK` is 4,477,562,267,871,699 in WAD units.

Sine rules version 2 uses dimensionless coefficients. The eleven-field getter replaces physical `preK` with `preGrowth` and physical `slope` with `waveTrend`. Their positions remain the same. The UI reads the version before selecting the formula. Legacy charts retain their original formula.

The trade fee remains 10% at or below the launch reserve. It decreases linearly to 2.5% at the third-wave reserve target. Fee splits, referral rules, the fixed active-buy minimum and linear ticket pricing stay unchanged.

## Arithmetic limits

An uncapped IBCO still operates within the contract's integer range. Deposits that exceed that range revert before the contract records them. Invalid unsolicited funds stay at the factory and cannot block a successor round.

Large claims, fee allocations and redemptions use full-precision multiplication and division. Individual swaps must fit Uniswap V4's signed 128-bit amounts. Buy and sell outputs also use conservative spot-price bounds to contain numerical error at extreme reserve scales.

## lePSP

lePSP means locked earning PSP. It names the PSP principal held in a Pepe NFT position. This is a display name for the existing position, not a new ERC-20 token. Deposit inputs, withdrawals and unlocked balances still use PSP. NFT transfer and fee rights stay unchanged.

## Scope

The original frontend, alternative prototype, rolling paper and deployment settings use this spec. The original frontend continues to read the actual settings of existing deployments. The alternative frontend remains a local simulation.

No public deployment forms part of this change. Test results belong in the corresponding GATE-LOG entry.
