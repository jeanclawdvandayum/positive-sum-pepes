# positive sum pepes 🐸

a memecoin with a mechanical soul. **PSP** mints and burns along a deterministic bonding curve inside a [uniswap v4](https://v4.uniswap.org) hook — no LPs, no rug pulls, no admin keys on the curve. the entire reserve sits in mixETH (an ETH yield token), so the pot earns from *outside* the game: your backing compounds whether the chart is green or not. that outside yield is what makes this **positive sum** — most memecoins recycle nothing.

- **bonding curve market** — every buy climbs a preset price curve; every sell walks it back down. sells pay a toll that flows to stakers.
- **stake & earn** — lock PSP for 90 days and every curve fee flows to you pro-rata, in mixETH.
- **carpet bomb** — if stakers vote with 69% quorum, the round is flattened: locks open, the curve goes flat, everyone exits toll-free at average backing. the remainder seeds round n+1.
- **your pepe** — every stake hatches a fully on-chain generated pepe NFT: 8-axis DNA (expression / eyes / hat / eyewear / item / skin / iris / background), 100,000,000 combinations, rendered to SVG at view time from RLE stamps inside the contract. no IPFS, no servers.

## quickstart

```bash
forge build
forge test          # 612 tests, 69 suites
```

## deploy to sepolia

the full deploy (factory + round 1 + hook + on-chain UI + zaps) is one script:

```bash
cp example.env .env          # fill PRIVATE_KEY, SEPOLIA_RPC_URL, ETHERSCAN_API_KEY
source .env

# free fork dry-run first — zero gas, full path:
PSP_FORK=1 PSP_TESTNET=1 PSP_PM=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 \
  forge script script/DeployPSP.s.sol --fork-url $SEPOLIA_RPC_URL \
  --private-key 0x0000000000000000000000000000000000000000000000000000000000000001

# the real thing:
forge script script/DeployPSP.s.sol --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY --broadcast
```

uses the canonical uniswap v4 PoolManager on sepolia and a mock mixETH with fast timings (24h predeposit window, 3d lock, 1d bomb vote). mainnet Base + anvil modes are in the script header.

## repo map

- `src/` — everything on-chain: `PSPFactory` (round lifecycle), `CurveHook` (the v4 hook), `CurveMath` + `src/curves/` (price curves: glide / longswell / switchback), `PSPStaker` (locks, fees, pepe NFTs), `PepeDescriptor` + `PepeArtData` (on-chain art), `PSPZapIn`/`PSPZapOut` (single-tx ETH routers)
- `script/` — `DeployPSP.s.sol` (one-shot deploy), `DriveAnvil.s.sol` (local e2e driver), `gen_pepe_art.py` (trait files → contract art), `app.html` (the walk-away UI published on-chain via `factory.setHtml`)
- `studio/` — the browser trait studio where the pepe art was authored + compiled (byte-identical to the repo pipeline); try it: `python3 -m http.server` in `studio/dist`
- `test/` — unit / integration / invariant / adversarial suites, incl. curve round-trip fuzzing and multi-system attack tests
- `frontend/` — the dapp (react + viem + rainbowkit), renders art via on-chain `renderSVG` eth_calls

## license

MIT
