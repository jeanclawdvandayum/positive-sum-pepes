# Sepolia UI changes — logo, faucet, env/chain wiring

Branch: `sepolia`. All changes in `frontend/`. Build gate: `npm run build` clean (tsc -b && vite build).

## What changed

**Logo (mixETH mark)**
- `public/tokens/mixeth.svg` — the v3 mixWETH logo (dark navy circle, peach #f5c09a ring, white inner disc, grayscale ETH diamond), copied from alchemix-v3-fe-prototype.
- `src/components/MixLogo.tsx` (new) — inline `<img>` component, default 1.3em text-relative sizing; `px` prop for fixed sizes (inline style overrides the tailwind default reliably); `dark:drop-shadow` 1px white halo so the navy disc separates from dark panels; `shrink-0` in flex rows.
- Placements: StakeCard rewards row + faucet row, SwapCard pay-token chip (18px), StatsPanel VOLUME/FEES rows (20px), Landing reserve hero stat.

**Faucet (testnet-only)**
- `lib/abi.ts`: `faucetAbi` = `function drip() payable`.
- StakeCard: dashed-emerald faucet row — logo + "100 mixETH per 0.0001 ETH" + "💧 get mixETH" button → `drip()` with 0.0001 ETH via writeContractAsync.
- Topbar: compact `💧 faucet` pill (label below `lg`), same drip call.
- **Gating:** `FAUCET_ENABLED = Boolean(VITE_MIX && VITE_FAUCET)` — buttons render only when both are set. Anvil dev without them = unchanged UI.

**Env + chain**
- `lib/config.ts`: `sepolia` (11155111) added to the chain switch; `ADDRESSES.mix` / `ADDRESSES.faucet` slots.
- `frontend/.env.sepolia.example` — every VITE_ var documented with Sepolia values; note on Vite's `.env.local` priority.

## Deploy day (Friday)
`cp .env.sepolia.example → edit addresses from deploy output → save as .env.local` → rebuild/redeploy. Faucet UI lights up as soon as VITE_MIX + VITE_FAUCET are real.

## Verification
- Real-chain e2e on local anvil: PSP_ANVIL=1 deploy (factory/round 1/zaps), real MixETHFaucet deployed + seeded 1M mix, `drip()` from a second key → exactly 100 mixETH received.
- Visual: 5 surfaces audited by flash vision vs reference logo — see `qa/sepolia-ui/VERDICT.md`. All PASS after size fixes (v1 chip-size FAILs → 18/20px bumps + dark halo).

## Open for scoopy
- Landing static copy still says mainnet timings (7-day predeposit / 90-day locks) vs testnet 1d/2d — change for the playtest or leave?
