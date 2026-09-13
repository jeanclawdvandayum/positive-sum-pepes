# Linear ticket release: local end-to-end checks

Run on September 12, 2026. No public-chain transactions were sent and no UI
deployment settings were changed.

## Results

- 16 fresh deployment receipts succeeded on Anvil, chain 31337.
- 42 action receipts checked: 38 successes and four expected reverts.
- 35 tests passed on the local fork, including the real Uniswap V4 lifecycle,
  clock tests and stateful buy/sell/settle sequences.
- An isolated production UI build passed at 1440px and 390px. Selecting one
  ticket loaded the exact current price and showed one seat / 69 seconds.
  No horizontal overflow or browser script errors appeared.

The broadcast flow uses DeployPSP's Anvil mock PoolManager. The separate
RealV4LifecycleTest suite exercises the real PoolManager on the local fork.
Browser checks cover reading state and selecting an amount, not wallet popups.

## Covered flows

Selected-art predeposits, duplicate-art rejection, the 1,000 mixETH cap,
pooled launch, immediate and post-detonation claims, exact ticket price growth,
zero-ticket buys, capped time additions, sell fee contributions, a 10-million
mixETH buy, reinvestment, withdrawal cancellation, expiry rejection, pot claims,
withdrawal and redemption, and permissionless staged respawn after a 12-hour
wait. Round two starts with a fresh predeposit window and a 0.005 mixETH ticket.

## Extreme-reserve limit

After the 10-million-mixETH buy, subsequent curve output can round to zero.
A quote returned zero and an attempted purchase reverted without taking funds.
A separate trace confirmed that reinvestment also reverts with `ZeroOutput()`
at that extreme. This is a curve precision limit, not the new ticket formula.
The run reverts that stress-test snapshot before testing normal reinvestment
and settlement. No economic behavior was changed to bypass the limit.

## Repeat

Run `bash scripts/anvil-ticket-e2e.sh`. It requires port 18545 to be free,
starts a disposable local node, deploys with the public Anvil development key,
runs the receipt flow and the targeted fork tests, then stops its node.

Action receipts: [anvil-ticket-2026-09-12.json](anvil-ticket-2026-09-12.json).
The stress-test receipts were checked before their snapshot was reverted.
