# TODO — Deploy Positive Sum Pepes on Sepolia

End-to-end checklist for shipping a playtest round of PSP to Sepolia
(chain `11155111`). Work top to bottom; every box is a verifiable step.

Timings cheat-sheet (testnet profile, packed by the deploy script):
24h predeposit offer · 2d unstake vest (6 × 8h decay epochs) · 1d bomb
vote · 3d flat exit.

---

while testing a deployment version of this, I encountered something I REALLY DO NOT LIKE AND MUST BE ADDRESSED. Using the infinifi system for stake weights, you made it so trading fee distribution is delayed. this seriously degrades UX and sucks.

> **RESOLVED 2026-08-28 (same day, post-deploy).** Fees are no longer
> epoch-based: a single live `creditPerWeight` accumulator is advanced the
> instant fees arrive, and claims/`pendingFeesOf` settle in O(1) at real time —
> no epoch walk, no boundary wait. Static positions keep exact bucket-math
> splits (weights are frozen within an epoch); decayers claiming epochs late
> under-credit only (accepted precision trade). Fresh stakes still earn from
> the next epoch — the anti-sandwich property is untouched. See
> `test/unit/FeeImmediacy.t.sol` and `docs/VESTING-DESIGN.md`. Requires a
> fresh deploy (round 2) — the live round-1 contracts keep the old engine.

**2026-08-28 CURVE NOTE (scoopy: "ensure the curve is still the staircase").**
Round 1 on-chain is the PSP_CURVE=4 two-zone S-curve, NOT the anchor-ladder
staircase (chain-verified: controller 0x1666…0903, P0=1e-4, exp k=2e-6 over
[0, 3.5M PSP] + log tail). Why: ETH Sepolia enforces a 2^24 = 16.78M per-tx
gas cap; measured deployRound floors are ~12.6M fixed + ~600k/zone + on-chain
mining luck — the 34-zone ladder needs 27.5M and no ladder variant beyond
~2 legs can ever fit. **Rebirth is single-tx (spawnNextRound), so over-cap
curves can never be reborn either.** Options shipped: PSP_CURVE=5 lean
10-zone ladder (17.5M — fits OP-stack chains only) and the finding that
**Base Sepolia (block limit 1.2B, no per-tx cap) runs the full 34-zone
staircase with 44x headroom — fork dry-run verified.**

**2026-08-28 CHAIN DECISION: testnet moves to Base Sepolia (scoopy).** Round
2 = PSP_CURVE=0 full staircase, PM 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408.
Full code-verified v4 periphery table recorded in script/DeployPSP.s.sol
(ReservesLens is NOT deployed on 84532 — 0 bytes on three RPCs). Frontend
wired for 84532 (baseSepolia chain, Coinbase faucet link; testnet deployers:
PSP_PM=0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 PSP_CURVE=0).

**2026-08-28 MAINNET VERDICT: no such wall exists there.** Mainnet has no
per-tx cap (a tx may consume the whole block) and the block limit is 60M
(verified via two independent RPCs). The full 34-zone staircase deployRound
(~27.5-29.5M incl. mining luck) is ~46-49% of a block — routine. Rebirth
fits identically; worst-case mining is bounded by the 4-candidate squat cap
(~11M) → absolute worst ~35.5M < 60M. Mainnet-fork dry-run ran deployRound +
on-chain UI green; it stopped only at router wiring because the throwaway
fork key held no real mixETH (fund the broadcaster for a real run). Also
fixed: PM_BASE was stale (0x498581fF…, no code on mainnet) — now the
canonical v4 PoolManager 0x000000000004444c5dc75cB358380D2e3dE08A90.

## 0) Prereqs (local machine)

- [ ] Foundry installed and current (`foundryup`)
- [ ] Repo synced: `git pull` on `sepolia` branch
- [ ] `forge build` — zero errors
- [ ] `make test` — full suite green (595+ tests)
- [ ] A **throwaway** deployer wallet (new key, testnet-only, no funds
      beyond what this deploy needs — never a mainnet key)
- [ ] Sepolia ETH in it: ≥ 0.5 ETH. Faucets:
      https://sepoliafaucet.com · https://www.alchemy.com/faucets/ethereum-sepolia
- [ ] A Sepolia RPC endpoint (Alchemy free tier is fine; publicnode
      works but is rate-limited)
- [ ] Etherscan API key (free, https://etherscan.io/myapikey) for
      source verification

## 1) Env setup

- [ ] `cp example.env .env`
- [ ] Fill in `PRIVATE_KEY` (the throwaway), `SEPOLIA_RPC_URL`,
      `ETHERSCAN_API_KEY`
- [ ] Leave the deploy flags as shipped:
      `PSP_TESTNET=1`, `PSP_PM=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`
      (canonical Uniswap v4 PoolManager on Sepolia), `PSP_CURVE=1`
      (glide) — or 2/3 if you want a different flavor
- [ ] Confirm `PSP_FORK` is EMPTY (never set for a real deploy)
- [ ] `source .env`

## 2) Fork dry-run — free, catches everything except gas

- [ ] Run the fork dry-run command from `example.env` §deploy flags
      (PSP_FORK=1 + PSP_TESTNET=1 + PSP_PM=… + `--fork-url`)
      with any throwaway key — must complete with
      `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`
- [ ] Note the console addresses (factory / round 1 / hook / zapIn /
      zapOut / TESTNET mixETH / faucet) — these are fork addresses,
      only the SHAPE matters here

## 3) Real deploy

- [ ] Fund check: `cast balance $DEPLOYER --rpc-url $SEPOLIA_RPC_URL`
      ≥ 0.5 ETH
- [ ] Deploy with serialized txs (avoids the nonce-race failures we hit
      on anvil — hook mining sends many txs in one script):

      forge script script/DeployPSP.s.sol \
        --rpc-url $SEPOLIA_RPC_URL \
        --private-key $PRIVATE_KEY \
        --broadcast --slow

- [ ] Let it run to completion — do NOT kill mid-broadcast (a partial
      broadcast can leave the factory alive but round 1 never landing)
- [ ] From the console output, record:
      - `factory:` ______________
      - `round 1 id:` (should be 1) ______________
      - `hook:` ______________
      - `zapIn:` ______________
      - `zapOut:` ______________
      - `TESTNET mixETH (1:1, no yield):` ______________
      - `TESTNET faucet (0.0001 ETH -> 100 mix):` ______________

## 4) On-chain verification (trust the chain, not the console)

- [ ] Round 1 registered:

      cast call $FACTORY "currentRoundId()" --rpc-url $SEPOLIA_RPC_URL
      # → 0x...01

- [ ] Hook + zones exist (curve data the chart needs):

      cast call $FACTORY "roundHook(uint256)" 1 --rpc-url $SEPOLIA_RPC_URL

- [ ] UI published on-chain: fetch `factory.html()` from any RPC —
      should return the app HTML with the factory address substituted
- [ ] Etherscan source verification:

      forge script script/DeployPSP.s.sol \
        --rpc-url $SEPOLIA_RPC_URL \
        --private-key $PRIVATE_KEY --verify --resume

- [ ] Skim the factory + hook on sepolia.etherscan.io (readable? no
      unexpected constructor args?)

## 5) Frontend

- [ ] `cd frontend && cp ../example.env .env.local` (VITE_* half only)
- [ ] Fill in:
      - `VITE_CHAIN_ID=11155111`
      - `VITE_RPC_URL=` browser-reachable Sepolia RPC
      - `VITE_FACTORY=`, `VITE_ZAP_IN=`, `VITE_ZAP_OUT=` from step 3
      - `VITE_MIX=` and `VITE_FAUCET=` from step 3 — **required**: the
        faucet card is env-gated and stays hidden without BOTH
- [ ] (Optional) own WalletConnect project id — `VITE_WC_PROJECT_ID`
      from https://cloud.walletconnect.com (a dev placeholder ships by
      default)
- [ ] `npm run build` — green
- [ ] Local smoke test against the real deployment: `npm run dev`,
      connect wallet, check trade page shows the live curve, faucet
      card visible, and a test drip works (0.0001 ETH → 100 mixETH)

## 6) Ship the UI

- [ ] Publish `frontend/dist` (here.now, Vercel/Netlify, wherever) —
      SPA routing on if the host needs it (`/trade`, `/stake` must
      deep-link)
- [ ] Verify the deployed URL on a fresh browser: wallet connect,
      curve renders with real zones, stake page rolls pepes from the
      on-chain renderer

## 7) Playtest kickoff

- [ ] Share the URL + these instructions for testers:
      - get Sepolia ETH (faucets above)
      - drip mixETH from the in-app faucet (0.0001 ETH → 100)
      - predeposit inside the 24h window → launch → trade/stake
- [ ] Watch round 1 state through the first predeposit window
      (`roundInfo(1)`, hook events on Etherscan)
- [ ] Debrief + tune: curve params (`PSP_CURVE`), timings
      (`_testnetTimings()`), faucet drip size — then redeploy fresh
      for round 2 playtests

## Known gotchas (from prior deploys)

- **Nonce races**: always `--slow` on real broadcasts; the script sends
  many txs (hook mining) and parallel sends have failed before.
- **Partial deploys**: if a broadcast dies midway, do NOT assume the
  factory is fine because it exists — always check `currentRoundId()`.
  Redeploy from scratch on a clean nonce rather than resuming blind.
- **Faucet gating**: no `VITE_MIX` + `VITE_FAUCET` = faucet card
  silently hidden in the UI.
- **`PSP_FORK`**: fork-dry-run ONLY. Setting it on a real deploy deals
  the broadcaster free ETH via `vm.deal` — which does nothing real, but
  signals you're on the wrong path.
