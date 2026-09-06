# Block-hash predeposit pepes

Baseline: `1615683c`. The user requested seemingly random predeposit NFT art based
on a block hash, replacing the same address-derived face across rounds.

## Entropy and preview

Each `PSPStaker` constructor freezes an immutable cosmetic seed:

```solidity
keccak256(abi.encode(previousBlockHash, block.chainid, address(this)))
```

The preferred genesis DNA is `keccak256(abi.encode(seed, wallet))`. Including the
staker address separates rounds even when they are created in the same block.
The previous block hash is read once during construction, so it never expires
after the EVM's 256-block lookup window. At block zero, a zero block hash is used
with the same chain and address separation.

`genesisPepeDna(wallet)` and `claimGenesisShare` share this calculation and the
existing collision resolver. Moving to another block or waiting to claim keeps
the same available face. An intervening mint can occupy that trait combination,
in which case the preview and claim use the first free combination. Minted DNA
stays immutable through transfers, withdrawal and reinvestment.

The wallet address remains the preferred **token ID**, independent of the art.
An occupied ID uses the existing fresh-ID allocator. Every mint still reserves
its canonical v2 trait combination, including modulo and unused-bit aliases.
Collisions use bounded storage work and never permit duplicate art within a round.

This is pseudorandom cosmetic selection. Block producers, deployers and wallets
can influence or search its inputs. There is no fairness, secrecy or cryptographic
randomness claim. The seed has no role in principal, fee credits, staking weight,
pot allocation or access control. It adds no transaction, keeper or oracle.

## Frontend and compatibility

The shared wallet/NFT reader already uses `genesisPepeDna` for an unminted wallet
and `dnaOf` for an owned NFT. It therefore displays the round's preview followed
by the saved art without reconstructing either hash locally. The stable address
avatar remains a loading/legacy fallback. Query identity includes chain, staker
and wallet. All current selectors and the version-1 stored-DNA/availability
interface remain compatible. Chosen-art staking keeps its existing previews.

Fresh factory/staker deployment is required. Existing NFTs and testnet contracts
keep their deployed behavior, including successors born from an old factory.

## Regression coverage

- Same contract address and wallet, with only the birth block hash changed.
- Different rounds created in the same block produce different preferred hashes.
- Reversed claim order and claims delayed beyond 256 blocks preserve available art.
- Block-zero construction and claims remain valid.
- Real-V4 one-wei and sub-minimum predeposit claims mint their contract preview.
- Existing canonical trait, mixed mint/transfer, occupied-art/ID, first-free oracle,
  and bounded-gas regressions remain active with seeded collision fixtures.
- The frontend uses each round's preview for the same wallet and keeps the saved
  minted DNA, including zero DNA and legacy fallback behavior.

See GATE-LOG.md for the final deterministic gate results and deployment boundary.
