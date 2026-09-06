# PSP security hardening — baseline money map

Baseline: 926e4b46 (contracts include AUD-15 at 6401d134).
Binding design: docs/audit/READINESS.md supersedes historical clock/design prose.
This is a working review map, not a finding or a certification.

## Assets and holders

- mixETH is the sole settlement unit. The testnet public-mint token is a mock; real ERC4626 yield/solvency is outside this testnet evidence.
- Predeposit mixETH sits in RoundController, tracked by per-beneficiary predeposits, totalPredepositMixETH and carryBonusMixETH. _predepositFor and seedCarry credit actual received token deltas; potDeposit separately tracks carryBonusMixETH.
- launchPooledBuy moves boot funds into CurveHook, creates PSP, stakes genesis PSP in virtual NFT position 0, and allocates the initial pot fee. claimPredepositPSP moves a depositor's proportional genesis stake into an owned Pepe.
- CurveHook holds reserveMixETH backing PSP, unpaid pot (potBalance - potPaid), unpaid deployer credit (deployerCredit - deployerCreditPaid), and unpaid staker fees. Referral cuts leave on each trade.
- PSPStaker holds locked PSP principal, including unclaimed virtual genesis principal. NFTs carry principal, fee entitlements, fractional remainder and vesting state. They remain after withdrawal.
- Registry purchases and ZapIn/ZapOut move caller funds through V4. PSPReinvestor claims a position's fees, buys with the claimed delta and stakes the resulting PSP delta into the same owner's positions. Donations to wrappers must not become another caller's entitlement.

## Writer relationships

| Ledger | Increases / initializes | Decreases / consumes |
| --- | --- | --- |
| Hook reserveMixETH | initializeCurve, _handleBuy net input, empty-board Flat transition | _handleSell full gross output, _handleFlatSell, redeemBacking |
| Hook totalSupplyPSP | initializeCurve, _handleBuy | _handleSell, _handleFlatSell, redeemBacking; PSP mint/burn must agree |
| Hook potBalance | initializeCurve genesis fee, _splitFee | empty-board Flat transition only; otherwise frozen after death |
| Hook potPaid / seatClaimed | claimPot before token transfer | never reset within a round |
| Hook deployerCredit / deployerCreditPaid | _splitFee / claimDeployerCredit | no reset; paid cannot exceed credit |
| Staker totalLocked / position amount | _stake, lockGenesis; claimGenesisShare transfers virtual to real | withdraw; virtual share decrement balances recipient increment |
| Staker totalFeesReceived / pendingFeesMixETH | addFees | _distribute consumes ceiling of new fractional credit |
| Staker creditPerWeight | _distribute at current total weight | monotonic; per-position checkpoint consumes earlier credit |
| Staker accruedFees / feeRemainder | _accrue and genesis split | successful payout; failed deferred payout restores entitlement |
| Staker totalFeesPaid | _settleAndPay successful hook transfer | monotonic |
| Global weight / decay schedule | stake, genesis, cancelWithdraw | request schedule, epoch advancement, withdrawal; transfer preserves total |
| Registry traderRefNftOf / attributed | own record or own atomic purchase | immutable within round |
| Factory reservations | reserveGenesis / reserveSpawn | three birthStep transitions or privileged cancellation |

## Invariants to challenge

1. Actual hook mixETH covers reserve + unpaid pot + unpaid deployer credit + outstanding staker liabilities.
2. Staker PSP balance covers totalLocked; principal equals all position amounts including virtual genesis.
3. Every fee allocation is debited once; sum of all fees paid and still owed never exceeds fees received.
4. A new/top-up stake earns no fee accrued before it joined. Immediate weight for subsequent trades is the approved current behavior.
5. Claim frequency, transfer, vesting, cancellation and re-staking do not erase or duplicate earned fees.
6. Every user can completely exit after detonation; final holders retain floor-rounding residue rather than creating excess entitlement.
7. Buy/sell mint/burn and reserve movements agree; chopped trades cannot extract extra backing from arithmetic drift.
8. An unprivileged caller cannot bind another wallet's referral or choose the recipient of another wallet's claims through standing approvals.
9. Callbacks only use authorized in-flight context; failed transactions roll back accounting and attribution.
10. Ladder seats and time come from gross 0.005 mixETH units; 260 seconds each with the immutable clock cap. Halted trading cannot revive the clock.
11. Empty ladders move pot to redemption; occupied ladders preserve historical pot and per-seat claims forever.
12. New rounds have fresh contracts/attribution; creating or interacting with them does not sweep old-round backing or holdings.

## Review constraints

Security-only fixes preserving intended behavior are authorized. Changes to game economics, intended permissions, referral policy or user flows require the user's approval before implementation. Do not deploy or sign wallet transactions during this source hardening pass. Preserve historical dirty broadcast files.

Use code and executable evidence to verify findings; do not assume an explicit narrowing Solidity cast checks overflow (it truncates), and do not convert an uncertain guard into a confirmed exploit. These override erroneous heuristics in third-party review references.

Method: combine the installed Pashov and 0xSimao attack/accounting references with Trail of Bits token, differential, variant and property-testing methods. Domain reviews use available concurrent agent slots, rather than claiming two complete 12-agent campaigns. Keep findings, rejected leads, tested scope and coverage limits in the final report.
