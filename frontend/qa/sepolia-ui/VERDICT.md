# Sepolia UI — visual verification verdicts

Method: live local anvil chain (real PSP_ANVIL deploy: factory/round-1/zaps + real
MixETHFaucet seeded with 1M mix; a real drip from a second key paid 0.0001 ETH →
received exactly 100 mixETH on-chain). Screenshots captured against the live dapp;
each image audited by glm-5.3-flash vision (direct multimodal chat, reference logo
compared side-by-side). Human eyeball gate pending (scoopy).

| surface | verdict | notes |
|---|---|---|
| stake-light.png | PASS | logo crisp in rewards row + faucet box; faucet row coherent |
| stake-dark.png (v2) | PASS | 1px light halo separates navy disc from dark panels; no glow artifacts |
| trade-light.png (v2) | PASS | pay-token chip 18px + VOLUME/FEES rows 20px — mark recognizable |
| landing-logo.png (v3) | PASS | reserve stat chip ~24px reads as the coin; chips unoccluded |
| topbar (in all shots) | PASS | compact 💧 faucet, disabled pre-connect, hidden when env unset |

## Revision history
- v1 FAILs: logo at ~14px chip sizes collapsed to "indistinct dot" (trade, landing);
  navy disc melted into dark panels (stake-dark).
- Fixes: `MixLogo` gained `px` prop (inline style beats tailwind default) — chip 18px,
  stat rows 20px; `dark:drop-shadow` 1px white halo for dark theme.
- v2/v3 re-audits: all PASS.

## Non-blocking nits (for the eyeball gate)
- ETH diamond inside the white disc collapses to a ~4-6px speck below ~20px —
  identity at small sizes rests on the navy/peach ring silhouette (inherent to the mark).
- "balance …" truncates pre-connect (pre-existing layout tightness, not from this change).
- Landing static copy still describes mainnet timings ("7-day predeposit", "90 days")
  — Sepolia playtest runs 1d predeposit / 2d locks. Copy decision needed for Friday.
- Topbar faucet label hidden below `lg` breakpoint (intentional).

OVERALL: PASS — pending human eyeball confirmation.
