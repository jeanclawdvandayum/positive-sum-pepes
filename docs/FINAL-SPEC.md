# September 14 final spec — sine rules v3

These rules apply to fresh deployments. Existing contracts retain their deployed rules.

**September 15 review status: release blocked.** The source implements the intended
price shape and pot-based tickets, but its rounded price and supply can decrease
at adjacent reserve values. Its fixed table range also lacks the arithmetic
justification required by the original handoff. See the
[review](audit/2026-09-15-single-sine-review.md) and the regression tests before
deploying. This document describes intended rules; it is not proof that the
current source meets all of them.

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

## Curve — one continuous tilted sine (version 3)

One price formula governs the entire reserve domain — the pooled raise and the active market are the same curve. There is no separate IBCO ramp and no phase change at launch or at the target.

Let `b` be the actual net launch backing: gross launch funds minus the genesis pot fee. Define

`lambda = 955 * sqrt(b / 450)` and `R_target = b + 10 * lambda`.

At the reference raise — 500 mixETH gross, 450 mixETH net — the wavelength is exactly 955 mixETH and the target is exactly 10,000 mixETH of reserve. The square root scales the ADDITIONAL backing to the target, never the whole target; larger raises widen each wave instead of pushing the target below the launch reserve.

With progress `x = (R − b) / lambda` (negative before launch) and tilted progress `s(x) = x − sin(2·pi·x) / (2·pi)`, the price is

`P(R) = P_L * exp( K * H(s(x)) )`, where `H(z) = sign(z) * (cbrt(1 + |z|) − 1)` and `K = ln(1000) / (cbrt(11) − 1) ≈ 5.6436827136371972`.

The launch spot price `P_L` defaults to 0.000075 mixETH per PSP. The full-amplitude sine makes the price slope zero at each wave boundary; prices never decrease as backing grows. The signed, softened cube root in the exponent makes the tenth wave land at exactly 1,000 times the launch price — 0.075 mixETH per PSP at the reference calibration. Wave ten is a calibration point, not a phase: the curve continues past it within its supported arithmetic span.

| Wave n | Reference reserve / mixETH | Price / launch price |
| ---: | ---: | ---: |
| 0 | 450 | 1 |
| 1 | 1,405 | 4.336 |
| 2 | 2,360 | 12.13 |
| 3 | 3,315 | 27.53 |
| 4 | 4,270 | 54.98 |
| 5 | 5,225 | 100.6 |
| 6 | 6,180 | 172.8 |
| 7 | 7,135 | 282.5 |
| 8 | 8,090 | 443.9 |
| 9 | 9,045 | 675.4 |
| 10 | 10,000 | 1,000 |

The price at zero reserve is derived, not pinned: about 0.000036 mixETH per PSP at the reference calibration. The prelaunch span uses the same signed formula — there is no exponential IBCO leg.

Genesis supply comes from the same curve's cumulative integral. Initial PSP equals `Q(b)`, the integral of `1/P` from reserve zero to launch. Buys use differences between cumulative values. Sells invert that function. The implementation must bound numerical error and preserve backing.

Ideal interval differences telescope. Actual receipts also reflect fees, integer rounding, and per-buy output reductions. Passing a telescoping identity alone does not prove safe settlement.

The wavelength formula supports a one-wei net launch backing. Admission checks require a positive opening price, a representable genesis mint, and at least one PSP wei per unit of pooled contribution. That allocation check keeps every accepted positive contribution claimable, including after later deposits or carry. Some tiny aggregates at the highest custom launch price fail this precision check; the default one-wei deposit remains supported.

The helper covers every launch whose opening price is at least one price wei, over the allowed custom launch prices. The old sixteen-wave launch limit is removed. Trading continues through wave 4,096: beyond that point, the entire remaining analytical integral is less than 0.005 PSP wei for every admitted launch. The one-wei output reduction makes that tail unmintable. Buys that cross this capacity fail before state changes. Sells and death redemption remain available from accepted states. See the [capacity derivation](audit/2026-09-15-single-sine-domain.md).

Settlement uses a monotone price approximation and a cumulative primitive with ordered Bernstein controls. Four immutable data contracts hold canonical endpoints at 36 decimal places; the helper checks each complete code hash at construction. Exact reserve fractions retain 54 decimal places before interpolation. The inverse searches the canonical endpoints, caches one cell, and verifies its final adjacent-reserve bracket. The specified error tolerances remain 1e-11 relative plus one price unit, and 1e-9 relative plus one PSP wei for supply.

The trade fee remains 10% at or below the launch reserve. It decreases linearly to 2.5% at the tenth-wave target. Fee splits and referral rules remain in place. Pot-based ticket pricing is defined below. Split trades sample a fee rate at each new reserve state. Their full receipts include rounding and output reductions, so the difference from one large trade is not fixed.

## Ladder tickets — pot pricing (version 3)

Each ladder spot is priced from the entire current accounted pot, sampled before the purchase contributes its own fees:

`ticketPrice = ceil(potBalance / 10,000)`, floored at one wei.

The active gross-buy minimum equals exactly one current ticket. A purchase below that price reverts; every successful active buy therefore earns at least one ticket, and `MIN_BUY_INPUT()` returns the live `ticketPrice()` for new rounds. Whole tickets only: `units = floor(gross / ticketPrice)`, so a purchase of `2·price − 1 wei` earns one ticket. The fee split, ladder weights (25/18/14/10/8/7/6/5/4/3, newest to oldest), absolute ticket numbering, ten-seat bounded writes, and 69-second cap-aware time per ticket are unchanged. Buy and sell fees both grow the pot, repricing later tickets only. Selling never removes seats.

The purchase routes the interfaces use carry an optional ticket-intent guard: a quoted `maxTicketPrice` bound reverts the trade (`TicketPriceMoved`) if the pot repriced tickets beyond the quote before execution — PSP-output slippage alone cannot protect a ticket count.

The ideal 2,500x comparison is the full-board first prize divided by one ticket's gross qualifying amount at the same pot. Integer ceiling and payout rounding make the actual same-pot ratio no greater than 2,500. Dust amounts can differ substantially. Later pot growth changes that comparison again. It is not a probability or a guaranteed return.

## lePSP

lePSP means locked earning PSP. It names the PSP principal held in a Pepe NFT position. This is a display name for the existing position, not a new ERC-20 token. Deposit inputs, withdrawals and unlocked balances still use PSP. NFT transfer and fee rights stay unchanged.

## Scope

The original frontend, alternative frontend, rolling paper, and deployment settings use this spec. Both interfaces read transaction rules from the selected deployment. The explanatory figures use example inputs and do not supply trade quotes.

Sine rules versions 1 and 2 describe older rounds and keep their original formulas for reading; the version is read before selecting any interpretation. No public deployment forms part of this change. Test results belong in the corresponding GATE-LOG entry.

## Referral reward claims

Each round's referral registry holds the mixETH allocated to eligible referrers. The hook credits each recipient at trade time using the existing five tiers. Recipients call `claimReferralRewards()` to collect their full balance.

Earned rewards belong to the wallet that owned the referral NFT at accrual. An NFT transfer changes the recipient of future rewards. Existing credits stay with their original recipient, even after all of that recipient's NFTs move. Claims remain open after detonation and after successor rounds launch.

The 60% staker share, 35% base pot share, 5% referral allocation, and 1% unattributed deployer credit retain their current rules. Missing tiers and rounding retain their existing treatment. Referral credits stay separate from lePSP trading fees, pot claims, and deployer credit. Existing deployments continue direct referral payouts until replaced with a fresh deployment.
