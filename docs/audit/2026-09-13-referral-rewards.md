# Claimable referral rewards

This source update changes referral payout timing. It requires a fresh
contract deployment. The existing Base Sepolia deployment keeps its direct
payout behavior.

## Reward flow

The hook uses the existing referral graph, owner deduplication and tier
weights. It transfers the sum of eligible rewards to the round's registry,
then credits each wallet. The registry accepts credits only from its round's
hook and checks that its mixETH balance covers all unpaid rewards.

Recipients call `claimReferralRewards()` to collect their full credit. The
registry updates its balance records before the transfer. A failed transfer
reverts the transaction and preserves the credit. Claims stay open after
detonation and successor launches.

Earned balances belong to the wallet that owned the referral NFT at trade
time. NFT transfers change future recipients. They leave existing credits
with the original wallet. Referral rewards remain separate from lePSP fees,
ladder winnings and deployer credit. The fee percentages stay the same.

`creditReferralRewards()` authenticates the hook without taking the registry's
purchase guard. This permits the hook callback during `buyWithMix()`.
`claimReferralRewards()` uses the reentrancy guard. The registry emits
`ReferralRewardsCredited` and `ReferralRewardsClaimed`; the hook's former
immediate-payout event is retired in fresh deployments.

## Interface and deployment

`REFERRAL_REWARDS_VERSION() == 1` identifies this implementation. Stake and
graveyard show wallet credits and a claim control for each supported round.
These controls remain available after the wallet transfers all its NFTs.
Older registries retain their existing UI paths.

Registry creation code now lives in an immutable `ReferralRegistryInitCode`
helper created by `ControllerDeployer`. The deployer remains the CREATE2
creator and shares the exact initcode between prediction and deployment.
Unsalted CREATE nonces advance once for the helper's construction. Release
manifests and source verification include the helper.

## Validation

Focused tests cover atomic referral purchases, buys and sells, credited
backing, duplicate claims, unauthorized credits, failed payouts, callback
reentry, NFT transfer, detonation and a successor round. Fuzz tests check
conservation across hook custody, staking custody, registry custody and
recipient wallets. Helper tests check initcode, address prediction and
constructor reverts. Frontend tests cover historic-round claims, version
checks and rejection of unrelated transaction targets.

The deterministic gate passed 569 Solidity tests, 185 frontend tests and
11 verifier tests, plus size, ABI, art, curve, TypeScript and build checks.
A local `PSP_ANVIL=1` deployment simulation passed without broadcasting.
See the matching entry in GATE-LOG.md for commands and contract sizes.
