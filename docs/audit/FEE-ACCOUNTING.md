# Fee accounting for this release

Fees are claimable immediately. Withdrawal reduces only future earning weight;
previously earned fees do not decay. A position earns full weight during its
request epoch, then five sixths, four sixths, through zero at the sixth boundary.
The explicit `isWithdrawing` flag distinguishes an epoch-zero request from an
indefinite lock; the five-field positions getter retains its ABI shape.

Each fee feed increments a global credit index by floor(fees × 1e30 / weight).
The pending-fee budget is debited by the ceiling of the entitlement allocated,
so fractional credits cannot be allocated twice. An epoch containing fees stores
the index before its first feed. A binary search retrieves the index before any
epoch, including epochs with no feeds. Static positions settle one interval;
withdrawing positions settle at most six intervals using their historical weight.
Whole credit and fractional remainders survive subsequent claims and mutations.
Fees are floored in aggregate per position, with fractional carry across claims.

Principal-changing actions settle first. Owner actions may defer an unavailable
payout; deferred fees remain attached to the NFT, including after principal
withdrawal. Explicit fee claims revert on failed payout. A donor cannot redirect
the beneficiary's fees or force a payout shortfall through permissionless top-up.
NFT transfers carry principal, vesting, accrued fees and fractional credit.
All financial entry points and NFT transfer share a reentrancy guard.

Claiming a predeposit splits the virtual genesis position's accrued whole and
fractional credit proportionally. Integer split dust remains with the unsplit
position and reaches the final claimant. Remaining predepositors retain their
entitlement; the claim does not reset it to zero.

Every writer of a decay schedule checkpoints the global point first. Outstanding
decays end within seven transitions, so advancing the current point after years
of inactivity is bounded. Cancellation and flat withdrawal remove only the
position's pending or active schedule; a retired slope is never subtracted again.

Evidence: FeeImmediacy covers late/frequent claims, full vesting, partial genesis
claims, deferred husks, transfers, epoch zero, century-long inactivity, early flat
withdrawal and a cross-function payout callback. MultiOwnerStateful combines
these paths with real-V4 trades and reinvestment, tracks all liabilities, and
finishes every campaign by withdrawing every position and redeeming all supply.

Human review should assess integer precision, sparse-index lookup boundaries,
schedule aggregation and external-token assumptions. This is a specification
of the implemented rules, not a proof of their security.
