# Predeposit precision and minimum — September 6, 2026

Baseline: `ae9bc79e`. The user reported a near-full cap being displayed as full,
then explicitly removed the 0.005 mixETH minimum from individual predeposits.
Active curve buys retain their existing minimum, ticket and clock rules.

## Cause and scope

The dedicated predeposit page already calculated MAX with bigint and serialized
the input exactly. Its compact total display rounded a near-cap total to 500,
while both its submit guard and the deployed controller enforced the 0.005
mixETH floor. Thus fixing display precision alone could not accept the dust.
The play-page swap form shared the minimum/display issues and its MAX used the
whole wallet balance without subtracting either cap's headroom.

Read-only checks against current Base Sepolia round 2 observed:

- Controller: `0x6bE9c6c31f7BDAB6Bc3834D8551E3fD214515977`.
- Total: `499999999999900000000` wei (`499.9999999999` mixETH).
- Cap: `500000000000000000000` wei; remainder: `100000000` wei.
- An `eth_call` of `predeposit(100000000)` reverted with `0x91e88d61`, the
  selector for `PurchaseTooSmall()`. No transaction was broadcast.

## Changes

- Controller accepts any positive public predeposit through the shared
  `predeposit`/`predepositFor` path. Zero, closed-round and cap guards remain.
- `PREDEPOSIT_RULES_VERSION() == 1` identifies the new immutable behavior.
  The UI reads it separately from existing state calls. Missing, unreadable or
  unknown capability retains the legacy floor; round/chain keys isolate caches.
- Both forms display exact totals, remaining capacity, wallet headroom and
  transaction amounts. MAX takes the minimum of wallet balance, global headroom
  and beneficiary wallet headroom, clamping already-filled caps to zero.
- Both forms allow top-ups after the time window expires until launch closes
  deposits, as the contract already does. A full cap still accepts no further
  public deposits. Races for the final headroom remain transaction-order dependent;
  an overshoot reverts rather than partially accepting the remaining amount.
- The embedded deployment-record template describes the new source rules.
  Previously deployed HTML and contracts remain unchanged.

## Variant review

Manual variant-analysis searches started with `MIN_BUY_INPUT`/`PurchaseTooSmall`
in the predeposit path, then expanded to `predeposit`, `predepositFor`, MAX and
`fmtAmount` across the controller, zap and frontend. Confirmed variants were the
dedicated page and SwapCard. The ETH zap delegates to the same controller path.
Active buy/reinvestment minimum checks are intentional and remain. The original
hypothesis that the dedicated MAX arithmetic rounded its transaction amount was
refuted by its bigint calculation and exact formatter.

## Evidence and limits

Regression coverage includes positive sub-minimum deposits, direct/on-behalf
one-wei deposits, zero rejection, dust completing both caps, and ETH zap credit.
Real-V4 tests use the production sine parameters to launch a normal pooled raise
with a one-wei or fuzzed tiny participant and claim both positions. Frontend
checks cover exact round-tripping of amounts, the observed live remainder,
legacy detection and 512 deterministic combinations of balance/cap headroom.
See the latest GATE-LOG entry for the completed full gate.

Browser verification of the rebuilt local app confirmed the exact live total and
remainder on both routes, plus the legacy-minimum notice. At 390px, the remainder
label fits within the viewport. The existing global navigation still overflows
at that width; this was traced to its fixed-width controls, outside this change.
No connected-wallet submission was made. The temporary viewport was reset.

A tiny individual deposit is distinct from a tiny entire pool. With production
sine parameters, a whole pool of one wei fails `SineMath.InvalidParams` during
launch. The transaction remains atomic, leaves deposits open, and a post-window
top-up allows launch. This is explicitly tested; numerical precision guards were
preserved. PSP allocations still use the existing floor rounding documented in
READINESS.md.

The current testnet controller still enforces its deployed minimum. This source
change requires a fresh factory/controller deployment; a UI rebuild or ordinary
next-round birth from the old factory cannot upgrade it. No live deployment or
wallet-signed transaction was performed for this fix.
