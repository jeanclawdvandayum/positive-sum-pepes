# September 13 final-spec verification

The final spec is implemented in source. Public deployment addresses remain unchanged. Tests used a fresh local Anvil chain and disposable accounts.

## Rules checked

- Three-day IBCO with uncapped pooled and wallet deposits by default.
- Maximum clock of 69:04:20 and 69 seconds per whole ladder ticket.
- Constructor overrides for shorter playtests, inherited by successor rounds.
- Four-week withdrawal horizon across the existing six epoch boundaries.
- lePSP as the display name for locked earning PSP.
- Curve reserve distances scaled to each round's actual net IBCO backing.

The reference curve raises its opening price 7.5 times. Its third wave reaches 0.06 mixETH per PSP, approximately 800 times the launch price of 0.000075. A gross 500 mixETH IBCO supplies 450 of curve backing and places that third wave at 10,000 reserves.

## Deterministic gate

`bash scripts/check-audit.sh` passed:

- 553 Solidity tests across 72 suites.
- 175 frontend tests and 11 name-verifier tests.
- 165 ABI function and event declarations.
- 38 production artifact size checks.
- Independent Decimal and Simpson oracle vectors.
- Original and expanded art fixtures, governance-surface checks, TypeScript and Vite build.

CurveHook runtime is 23,899 bytes, retaining 677 bytes under EIP-170 and passing the existing 500-byte reserve requirement. The separate curve property campaign used 4,096 cases per property. Seven capacity regressions cover large deposits, claims, pot payouts, redemptions, rejected arithmetic overflow and signed-128 swap limits.

The build retains its existing large-chunk warning. It completes successfully.

## Two-round Anvil test

`scripts/anvil-ticket-e2e.sh` passed on chain 31337. All 16 deployment receipts succeeded. It checked 44 action receipts: 39 successes and five expected reverts. The separate local-fork lifecycle, stateful and clock suites passed 35 tests.

Round one pooled 2,000 mixETH, exceeding the former cap. Round two pooled 5,000 mixETH. Both rejected early public launch and opened after three days. The second round was created twelve hours after detonation and received a fresh complete window.

The test covers reserved-art collisions, claims before and after detonation, ticket growth, buys below the current ticket price, fee-bearing sells, reinvestment, withdrawal cancellation, expired-trade rejection, pot claims and backing redemption. It also tests a ten-million-mixETH buy on a snapshot branch. Further buys at exhausted output precision revert with user balances intact. The snapshot is then rolled back to continue the lifecycle.

## UI and paper

The original and alternative frontends agree with actual Anvil curve tuples at all thirteen markers from launch through the third wave. Net backing of 1,800 places the third wave at 40,000 reserves. Net backing of 4,500 places it at 100,000 reserves. Both retain the 800-times price ratio.

Prototype tests passed 25 of 25. Browser checks covered light and dark themes at widths 360, 390, 768 and 1,440 pixels. The rolling paper's adjustable IBCO example follows the same scaling. The updated capacity errors appear as readable transaction feedback.

See [the saved local evidence](anvil-final-spec-2026-09-13.json) and [the final spec](../FINAL-SPEC.md). Full command logs are available locally at `/tmp/psp-final-spec-gate.log` and `/tmp/psp-final-spec-anvil.log`.
