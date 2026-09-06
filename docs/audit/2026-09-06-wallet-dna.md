# Wallet-derived genesis pepes and round uniqueness

Baseline: `8808f3fb`. The user requested predeposit NFTs matching their wallet
avatar, then required that the same DNA never mint twice in a round.

The later [block-hash art amendment](2026-09-06-blockhash-pepes.md) supersedes the
address-only genesis DNA below. The canonical uniqueness guard, collision handling
and immutable minted art described here continue to apply.

## Rules implemented

A genesis claim prefers NFT ID `uint256(uint160(wallet))` and DNA
`keccak256(abi.encode(uint256(uint160(wallet))))`. This matches the frontend's
existing hash of the address padded to 32 bytes. Claim order and block time do
not change an available wallet's art. If its ID is occupied, the claim uses the
normal fresh-ID allocator. It never overwrites or merges into an existing NFT.

Every production mint path reserves the canonical **eight-trait combination**,
not just the 256-bit hash. The v2 renderer ignores bits above bit 31 and applies
modulo to each nibble. Consequently different hashes can render the same traits:
chosen IDs **4046 and 5249** are a concrete regression pair. Zero DNA, high-bit
aliases and modulo aliases also share a reservation. `PepeDna` derives counts
from the production `PepeArtData` constants without editing generated art.

- `lockWithPepe` mints exactly the previewed art or reverts `PepeDnaTaken`.
- `lock` and genesis claims use their preferred art when available, otherwise
  the first free canonical combination. The fallback can differ from the wallet
  avatar when a prior mint has already reserved that combination.
- NFT DNA is stored once and remains unchanged on transfer, top-up, withdrawal
  or reinvestment. No art reservation is ever released during the round.
- Each staker has independent reservations, so the same art may exist in a
  different round. The finite production trait space is 100,000,000 combinations;
  complete exhaustion makes new automatic/genesis mints revert atomically with
  `PepeArtExhausted`. No duplicate is admitted to bypass exhaustion.

## Collision handling and accounting

The first free art key is maintained incrementally using contiguous occupied-run
boundaries, separately from NFT-ID boundaries. Minting merges at most two adjacent
runs. A collision reads the maintained first-free key, with no retry loop through
user-selected IDs or hashes. Tests fill 1,024 adjacent art keys and 2,048 NFT IDs
and exercise the claim under a 450,000-gas bound. This increases the previous
300,000-gas test allowance to account for the added immutable-art/reservation writes;
it does not change any contract-level gas or economic limit.

Genesis shares, fee credits, total weight, ownership accounting and permission
checks retain their existing flow. Reservation, mint, accounting and any fee
callback execute atomically under the existing reentrancy guard. A failed chosen
mint leaves both tokens and the genesis pool untouched. Occupying a target wallet's
preferred ID or art can change its eventual face, but cannot redirect its PSP or
force an unbounded claim search.

## Frontend

`PEPE_DNA_VERSION`, `isPepeAvailable` and `genesisPepeDna` expose the rules and
current preview. Picker candidates already minted by ID or trait are disabled;
chosen mints recheck availability before approval. Transaction ordering can still
invalidate a preview, in which case the contract rejects the chosen duplicate.

The wallet button, account modal, activity feed, last-buyer chip, ladder and
graveyard winners share the same wallet/NFT reader. Its query cache is scoped by
chain, staker and address and polls ownership; an old permanent address-only ladder
cache was removed. Owned position cards now read `dnaOf` rather than rehashing an
ID, including valid zero-DNA fallbacks. Long wallet-derived IDs use compact labels;
full IDs remain in transactions, referral links, tooltips and transfer review.
Legacy rounds retain their actual immutable art and use the old address fallback
when the new preview selector is unavailable.

## Validation and release boundary

Golden Solidity/TypeScript vectors cover padded, low and maximum-width addresses.
Foundry properties cover reversed claim order across independent rounds,
production-decoder agreement, canonical key round-trips, mixed mint/transfer
uniqueness and an independent occupied-set model for the first-free allocator.
Pins cover chosen-ID/art squatting, real modulo collisions, zero DNA, transfers,
withdrawals, automatic fallback and bounded gas. Existing real-V4 pooled claims,
fees, lifecycle, NFT interface and stateful accounting tests remain in the gate.
See GATE-LOG.md for actual final results.

The first complete gate passed 500 Solidity tests and found one stale deployment
gas canary: the cheapest sampled composed birth cost 14,570,501 gas, above its old
14M margin. The actual release script has used three birth transactions since
September 3. The revised canary retains 30M composed containment and exercises
the deployed staged path with explicit 10M / 10M / 2M gas forwarding, plus phase
and final-round checks. The independent staged-genesis budget tests also remain.
No production gas limit or deployment flow was changed to accommodate this work.

Uniqueness refers to the production v2 **trait tuple**, not a bytewise/raster image
comparison. Different trait tuples can obscure details behind other layers. Custom
or historical descriptors with different codecs need separate compatibility review;
the production deploy script uses `PepeDescriptor` with the v2 codec. This patch
does not change descriptor admin permissions or generated art.

Fresh factory/staker deployment is required. Existing testnet NFTs, balances and
contracts remain unchanged; old factories continue birthing their old staker code.
No live transaction or domain operation is part of this source change.
