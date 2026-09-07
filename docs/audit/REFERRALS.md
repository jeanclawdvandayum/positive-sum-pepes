# Referral purchase flow — AUD-15

## User flow

A referral link lands on the explainer and carries the referring NFT ID, Base
Sepolia chain ID and immutable per-round registry address. The app captures it
before navigation removes the query, persists it under that chain/registry, and
keeps a memory copy when local storage is unavailable. Old id-only links need to
be regenerated; they cannot safely identify their original round.

For a compatible round, the existing buy action calls that round's registry:

```
buyWithMix(poolKey, mixIn, minPspOut, deadline, referrerNftId)
```

The normal mixETH allowance is granted to this registry. An approval can still
precede the purchase, just as with the previous zap; there is no separate referral
transaction, typed-data signature or confirmation button. Zero means no incoming
referral. An existing recorded referral always takes precedence over later links.
A failed buy reverts both the proposed attribution and the purchase. A valid new
referral receives its cut of the first successful purchase's fee.

Self referrals, unqualified/missing NFTs and cycles are skipped, with a
`ReferralSkipped` event. The purchase proceeds and leaves the attribution slot
available. A purchase without a referral likewise leaves that slot available.
The eligible link carried by the first successful attributed purchase wins.
`record(referrerNftId)` remains an optional direct contract API with strict errors;
the frontend does not use it.

## Authentication and permanence

The registry authenticates the buyer as `msg.sender`; there is no caller-supplied
trader parameter, authorized third-party recorder, `tx.origin` check or signature
relay. The registry verifies its round's controller, hook, currencies, canonical
pool parameters and the hook's registry before entering V4. Its guarded callback
accepts only the configured PoolManager while a matching purchase is in flight,
and consumes that purchase context before any external token calls. Reentrant
purchases and direct registration are rejected.

mixETH moves directly from the buyer to V4. PSP moves directly from V4 to the
buyer. The registry keeps neither input nor output from purchases. Hook data
continues to carry the buyer for ladder seats, events and fee payouts; forged V4
hook data or `buyWithMixFor` beneficiaries still cannot create attribution.

`traderRefNftOf[wallet]` is the authoritative, write-once entry for the round.
Changing, buying, transferring or losing a primary NFT cannot replace it.
Receiving someone else's NFT does not silently attribute the receiving wallet.
Existing token ancestry is also write-once, so a new owner cannot rewrite the
previous owner's stored NFT edge when recording their personal referral.

The referral is locked to the NFT ID, not to its owner address: transferring the
referring NFT transfers its future referral income to the new owner, as before.
Ancestor traversal remains bounded to five tiers; owner deduplication remains in
place. Subsequent buys, sells and owner-attributed reinvestments use the recorded
entry. A new round has a fresh registry and a fresh attribution graph.

This permanence guarantee is per wallet entry. It does not identify people across
wallets or authenticate every custom router's beneficiary hint. A direct V4
caller can still choose a different payout beneficiary at its own expense,
as described in READINESS.md; it cannot rewrite the victim's recorded entry.

## Deployment boundary

The existing Base Sepolia factory and its referral registries are immutable and
still contain the previous implementation. This source change requires a fresh
factory/round deployment; even later rounds born by the existing factory use its
original registry deployment code. No live balances, NFTs, history or attribution
have been migrated in this change.

The frontend checks `PURCHASE_REFERRAL_VERSION == 1`, the current round ID,
registry target and hook before registry approval/purchase. Legacy rounds retain
ordinary zap purchases. A pending referral on a legacy round is blocked rather
than silently discarded or submitted as a separate transaction. Link sharing is enabled for compatible registries and
produces the scoped URL format. An old-round or other-network hint cannot be
carried into a new round by local storage.

## Sharing on X

The stake page's referral card offers a share preview with 20 rotating quips,
the selected position's on-chain art and the full scoped referral URL. Testnet
posts identify the playtest. Wallet, staker, NFT or link changes reset the preview.

[X Web Intent](https://docs.x.com/x-for-websites/post-button/overview) prefills text
and the URL. It cannot attach a local PNG. The share
button copies an 828×828 PNG and opens the composer, where the user pastes the
image and reviews the post. A PNG download and ordinary composer link remain
available when clipboard permissions or popup blocking intervene. This uses no
X account credentials, upload backend or automatic posting. Incompatible legacy
registries retain the existing disabled-link guard.

## Regression evidence

`test/ReferralPurchase.t.sol` runs 22 tests against an actual local V4 PoolManager,
real curve, ERC20 transfers and NFT positions. Coverage includes exact first-buy
referral payment and fee conservation, buyer output/seats, slippage/expiry/input/
allowance/clock failures, invalid and cyclic referrals, secondary-NFT self referral,
256 fuzzed later hints, immutable wallet entries across NFT transfers, immutable
NFT ancestry, sell/buy continuity, forged beneficiary hints, unauthorized callback
spending, token callback reentrancy, a decoy registry and a complete staged rebirth.

`frontend/tests/referrals.test.mjs` covers scoped links/storage, malformed and
uint256-boundary IDs, round/network isolation, existing-entry precedence, pending
read failures, stale/legacy purchase targets and encoded referral-buy calldata.
The shared transaction tests cover wallet cancellation, receipt reverts and
replacement handling. Latest full gate counts are recorded in GATE-LOG.md.
