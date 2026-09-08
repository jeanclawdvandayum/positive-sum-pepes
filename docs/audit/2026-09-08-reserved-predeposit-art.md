# Predeposit art reservation

Source update, not deployed.

`predepositWithPepe(amount, pepeId)` accepts the deposit and reserves its exact
ID and canonical rendered trait combination atomically. The first choice stays
fixed for the wallet in that round. Further deposits add to the same allocation.
Permissionless `predepositFor` cannot choose or replace someone else's art.
Existing deposit routes remain available for integrations without selection.

Reservations occupy the same bounded ID and trait indexes used for minted NFTs.
They cannot be minted by ordinary staking or consumed by automatic minting.
A failed transfer, cap check, ID check or trait collision rolls back everything.
One positive funded allocation gets one reservation. Deposits as small as one
wei remain supported, so this is not Sybil-resistant art allocation.

Both claim selectors use the reserved choice. An attempt to override it reverts.
Claiming consumes the reservation without releasing its permanent uniqueness
indexes. Principal and fees still split from the genesis position through the
existing accounting path. Claims after detonation work the same way, including
through the Graveyard's original claim selector. No NFT exists until claiming.

The predeposit page detects `PREDEPOSIT_ART_VERSION == 2`, requires a choice,
and submits it with the deposit, using the existing approval/batching flow.
After confirmation it shows the reserved face and keeps it for top-ups.
The claim-time picker remains only for version 1 deployments.

Regression coverage includes duplicate rendered art under different IDs,
deposit/fund rollback, fixed top-up choice, controller-only reservations,
sequential ID skipping, and claiming the exact reserved face after detonation.
Gate results are recorded in GATE-LOG.md when complete.
