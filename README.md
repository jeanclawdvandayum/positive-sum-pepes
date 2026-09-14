# positive sum pepes 🐸

a memecoin with a mechanical soul. **PSP** mints and burns along a deterministic bonding curve inside a [uniswap v4](https://v4.uniswap.org) hook — no standard LP positions; round settlement follows the detonation clock. the entire reserve sits in mixETH (an ETH yield token), so the pot earns from *outside* the game: your backing compounds whether the chart is green or not. the intended external yield source is production mixETH; the public-mint testnet token does not demonstrate that yield.

- **bonding curve market** — every buy climbs a preset price curve; every sell walks it back down. sells pay a toll that flows to stakers.
- **stake & earn** — lock PSP and every curve fee flows to you pro-rata, in mixETH. unstaking vests in six steps over about 28 days; detonation opens every lock instantly.
- **detonation clock** — a countdown capped at 69:04:20 arms at launch, and buys add 69 seconds per whole ticket unit at the current ticket price. at zero anyone can settle the round: the fee pot pays a last-ten-buyers ladder, the curve flattens, locks open, and the next round is born in the same transaction.
- **your pepe** — every stake hatches a fully on-chain generated pepe NFT: 8-axis DNA (expression / eyes / hat / eyewear / item / skin / iris / background), 100,000,000 combinations, rendered to SVG at view time from RLE stamps inside the contract. no IPFS, no servers.

## quickstart

```bash
forge build
bash scripts/check-audit.sh  # deterministic contract + frontend audit gates
```

## deploy to base sepolia

the full deploy (factory + round 1 + hook + on-chain UI + zaps) is one script,
plus a required second pass for the reinvestor:

```bash
cp example.env .env          # fill PRIVATE_KEY, BASE_SEPOLIA_RPC_URL, ETHERSCAN_API_KEY
source .env

# free fork dry-run first — zero gas, full path:
PSP_FORK=1 PSP_TESTNET=1 PSP_PM=0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 \
  forge script script/DeployPSP.s.sol --fork-url $BASE_SEPOLIA_RPC_URL \
  --private-key 0x0000000000000000000000000000000000000000000000000000000000000001

# the real thing:
forge script script/DeployPSP.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY --broadcast --slow

# second pass — staged round addresses are entropy-salted, so the reinvestor
# reads the REAL chain (PSP_FACTORY / PSP_ZAPIN come from the console output):
PSP_FACTORY=0x… PSP_ZAPIN=0x… forge script script/DeployReinvestor.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

uses the canonical uniswap v4 PoolManager on base sepolia, a 1:1 testnet
mixETH with a free faucet, and env-tunable fast playtest timings. mainnet
Base, ETH sepolia and anvil modes are in the script header. full checklist +
gotchas: TODO-SEPOLIA.md.

## repo map

- `src/` — everything on-chain: `PSPFactory` (round lifecycle), `CurveHook` (the v4 hook) + `SineMath` (the tilted-sine curve), `RoundController` (deposits → launch → detonation), `PSPStaker` (locks, fees, pepe NFTs), `PSPReferralRegistry` (referral escrow), `PSPGraveZap` (one-tx post-detonation exit), `PepeDescriptor` + `PepeArtData` (on-chain art), `PSPZapIn`/`PSPZapOut` (single-tx ETH routers)
- `script/` — `DeployPSP.s.sol` (one-shot deploy), `DriveAnvil.s.sol` (local e2e driver), `gen_pepe_art.py` (trait files → contract art), `app.html` (the walk-away UI published on-chain via `factory.setHtml`)
- `studio/` — the browser trait studio where the pepe art was authored + compiled (byte-identical to the repo pipeline); try it: `python3 -m http.server` in `studio/dist`
- `test/` — unit / integration / invariant / adversarial suites, incl. curve round-trip fuzzing and multi-system attack tests
- `frontend/` — the dapp (react + viem + rainbowkit), renders art via on-chain `renderSVG` eth_calls

## license

MIT

Current approved rules and audit preparation: [audit readiness](docs/audit/READINESS.md).

## Current testnet release

Use the [playtest guide](docs/audit/TESTNET-PLAYTEST.md),
[current readiness packet](docs/audit/READINESS.md) and latest GATE-LOG entry.
The fee engine preserves accrued fees through vesting. The legacy yield keeper
is disabled; compounding uses the owner/operator-authorized staking UI. The
embedded testnet HTML is a read-only deployment record; wallet flows use the
React app. Frontend dependencies are installed from `frontend/package-lock.json`
with npm.
