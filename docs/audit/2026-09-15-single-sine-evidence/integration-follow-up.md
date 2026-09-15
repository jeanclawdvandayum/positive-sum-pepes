# Integration follow-up repairs

Two variants found during the numerical repair are fixed in source. The parent gate must validate their final integration with the new primitive.

## V3-INT-4: batch reinvestment could fail after a tiny donation

`PSPReinvestor.reinvestAll` previously floored each proportional allocation and retained the remainder. Its final check reverted when the wrapper balance exceeded 1,000 PSP wei and the current batch added any new dust. A stranger could transfer 1,001 PSP wei to the wrapper, making any later batch with a nonzero division remainder revert. The wrapper had no path to consume that donated balance. Repeated normal batches could also reach this state through accumulated dust.

The original share calculation also multiplied `bought * position.amount` in 256 bits before dividing. A valid large principal can make that intermediate product overflow even when the final share is small enough to store.

The repair snapshots all selected principals and uses `Math.mulDiv` for each share. The final position with nonzero principal receives the exact remaining PSP. All new PSP is staked, and any balance present before the transaction stays unchanged. Empty positions receive no rounding remainder. All selected positions must still have the same owner, and caller authorization and the round-hook check remain in place.

The isolated allocation test uses real ERC20 transfers with controlled fee, position, and buy-output fixtures. It passed four tests:

- The 1,001-wei donation and a batch that produces a remainder.
- An empty final selected position.
- A multiplication that exceeds 256 bits while the resulting share fits.
- 10,000 fuzz cases that check complete allocation and preservation of donated balances.

Command and log:

```sh
forge test --root /tmp/psp-reinvest-isolated -vv
# /tmp/psp-reinvest-allocation-test.log
```

`test/ReinvestAttribution.t.sol` also contains a funded real-V4 regression. It verifies that its chosen batch has a nonzero old rounding remainder, transfers 1,001 PSP wei to the wrapper, and requires successful owner-attributed compounding. The parent gate runs that test after primitive integration.

## V3-INT-5: the sell quote did not mirror execution guards

The previous repair added buy-quote guards, but `CurveHook.getSellOutput` still accepted inputs that the V4 sell route rejected. These included the sell dust floor, signed-128 input limit, complete supply, inactive states, and zero or oversized output. A quote could therefore report an output for a transaction that could not execute.

The sell quote now follows the execution guard order: active or flat mode, active clock, signed input limit, the existing sell minimum, supply exclusion, calculation, nonzero output, and signed output limit. Flat sells remain fee-free. The separate `redeemBacking` exit still permits complete remaining-supply redemption; the sell quote describes the V4 route.

`test/SellQuoteParity.t.sol` adds five tests covering funded real-V4 sells at the exact sell minimum, invalid inputs, zero and oversized helper outputs, clock and mode transitions, flat execution, and predeposit state. The helper-output cases use controlled read results to isolate the output guards, while checking that failed execution leaves balances and accounting unchanged. The parent gate runs these tests after primitive integration.

## Authorization and custody review

The follow-up traced every live caller of `claimFeesTo`, `claimAllTo`, `withdrawFor`, and `claimPotFor`.

- GraveZap checks that each selected NFT belongs to the transaction caller before any exit leg. Fee claims pay that caller. Principal withdrawal pays the NFT owner. PSP redemption pulls tokens only from the caller's wallet. The prior arbitrary-caller fee theft route remains closed.
- Reinvestor checks owner or per-position/operator authorization and requires a common owner for a batch. It reads the dynamic minimum only from the NFT's own round hook. A caller cannot substitute another hook to choose the minimum.
- The canonical hook rejects initialization of other currencies, fee tiers, or tick spacing. An arbitrary pool key with the same hook cannot create a second usable pool through the public initialization route.
- Permissionless pot claims pay the recorded seat owner. They do not redirect the payout to the caller.

No additional theft variant was found in those paths during this follow-up. This bounded review does not replace the full repository gate or an external security audit.
