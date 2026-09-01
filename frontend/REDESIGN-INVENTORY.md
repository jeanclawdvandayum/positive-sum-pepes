# PSP FRONTEND — REDESIGN INVENTORY
Map of `~/clawd/positive-sum-pepes/frontend` for a full visual redesign. Everything below read from source on 2026-09-01. NO code was changed to produce this doc.

Stack: Vite 6 + React 19 + TS 5.7, react-router-dom 7 (HashRouter), wagmi 2 + viem 2 + RainbowKit 2.2 (ConnectButton), @tanstack/react-query 5, Tailwind CSS v4 (via `@tailwindcss/vite` — NO tailwind.config file). Build gate: `npm run build` = `tsc -b && vite build`.

---

## 1. FILE TREE + ROLES

```
frontend/
├── index.html                  # SPA shell: title, 2× theme-color metas, pre-paint theme script. NO OG/favicon/description.
├── vite.config.ts              # react + tailwindcss plugins; dev /rpc proxy → VITE_RPC_PROXY_TARGET (CORS killer)
├── package.json                # psp-frontend 0.1.0; scripts: dev / build / preview only
├── tsconfig.json / tsconfig.tsbuildinfo
├── .env.local                  # anvil (31337): RPC 127.0.0.1:8545, FACTORY/ZAP_IN/ZAP_OUT/MIX addrs
├── .env.production             # base overrides: public RPC only (no key in bundle)
├── .env.sepolia.example        # documented env template; WC project id, faucet slots
├── UI-CHANGES.md               # sepolia-branch changelog: mixeth logo, faucet gating, env/chain wiring
├── debug_*.m{s,ts} dump_zones.mjs decode_zones.mjs   # throwaway curve-debug scripts (root, not bundled)
├── qa/                         # icon-iter1 (pixel-icon PNG proofs) · sepolia-ui (screenshots + VERDICT.md)
├── dist/                       # last prod build (mirrors public/: fonts/, tokens/, index.html — zero og: tags)
├── public/
│   ├── fonts/GeistPixel.woff2  # variable pixel font, weight 100–900 + ELSH morph axis
│   └── tokens/{mixeth,eth}.svg # token marks (mixeth = navy disc/peach ring/ETH diamond, from v3 fe prototype)
└── src/
    ├── main.tsx                # boot: rainbowkit css → index.css → App (StrictMode)
    ├── App.tsx                 # providers (wagmi→query→rainbowkit→theme) + HashRouter + Topbar + 4 routes + footer
    ├── index.css               # ENTIRE styling system (140 lines) — see §3
    ├── vite-env.d.ts
    ├── pages/
    │   ├── Landing.tsx         # "/" explainer: hero + what-is-this + 6 mechanic cards + lifecycle strip
    │   ├── Trade.tsx           # "/trade" (play): RefBanner, SwapCard (2/5) + CurveChart (3/5), StatsPanel
    │   ├── Stake.tsx           # "/stake": StakeCard + right column (CarpetBombCard, ReferralCard)
    │   └── Predeposit.tsx      # "/predeposit": window progress, deposit form, launch/claim, ReferralCard
    ├── components/
    │   ├── Topbar.tsx          # sticky glass nav + random-pepe logo + FaucetButton (exports it too)
    │   ├── SwapCard.tsx        # buy/sell/predeposit swap; quotes, slippage, fee haircut, mode-aware
    │   ├── CurveChart.tsx      # hand-rolled SVG curve: linear/log x, price/supply y, live dot, hover, sine markers
    │   ├── StatsPanel.tsx      # "pot board": 3 cards — volume / price history+spark / fees generated (log-driven)
    │   ├── StakeCard.tsx       # stake orchestrator: totals, multiclaim/reinvest, PepePicker, input, PepeCards, PepePanel
    │   ├── CarpetBombCard.tsx  # governance: propose/vote(quorum 69%/majority)/execute/finalize + pepe selector
    │   ├── ReferralCard.tsx    # default: link generator; RefBanner: ?ref capture→localStorage→bind record()
    │   ├── PepePanel.tsx       # "your pepe": on-chain renderSVG of primaryOf(addr), teaser fallbacks, 🥚 state
    │   ├── PepePicker.tsx      # 6 candidate pepes (ids ≥1e12), on-chain or local render, refresh reroll; exports dnaOfId
    │   ├── PepeCards.tsx       # per-staked-pepe card (Art ALWAYS local-rendered), vest countdown, claim/reinvest
    │   ├── PixelIcon.tsx       # 8 hand-drawn 24×24 pixel icons (chart/window/diamond/bomb/sum/shield/die/unlock)
    │   ├── MixLogo.tsx         # /tokens/mixeth.svg img wrapper (1.3em default, px prop, dark halo)
    │   ├── TokenIcon.tsx       # PspIcon (base pepe dna 0n → data URI) · EthIcon
    │   └── ThemeSwitcher.tsx   # 3-way system/light/dark pill, inline SVG icons
    └── lib/
        ├── config.ts           # chain pick (31337/1/11155111/84532/8453→base), ADDRESSES, FAUCET/REINVEST gates, wagmi cfg
        ├── rpc.ts              # raw JSON-RPC eth_call/eth_getLogs via fetch(VITE_RPC_URL) — bypasses wagmi idle bug
        ├── abi.ts              # hand-rolled minimal ABIs: factory/controller/staker/descriptor/hook/erc20/zaps/registry/faucet/reinvestor + buildPoolKey (v4 dynamic-fee 0x800000, spacing 60)
        ├── useRound.ts         # THE shared store: singleton pub/sub, one 4s loop for whole app (RoundInfo), useBalances
        ├── useRpcReads.ts      # generic ordered batch poller (6s default, 8s→60s backoff, key-serialized deps)
        ├── useEthUsd.ts        # CoinGecko ETH spot, 5-min module cache, null when offline
        ├── curve.ts            # zone-curve TS port (marginalPrice walk + per-zone geometric sampling)
        ├── sine.ts             # tilted-sine curve: one-shot ~110-call sample cached per hook + markers + labels
        ├── pepeRender.ts       # client mirror of PepeDescriptor.renderSVG (RLE→rects, 4-bit dna codec, randomDna)
        ├── pepeArt.json        # 21KB single-line art data: base/expr/eye/hat/wear/item RLE + palette ramps (GENERATED — do not hand-edit)
        ├── format.ts           # fmtAmount/fmtPrice/fmtPct/fmtCountdown/parseAmountToWad/wadToExact(no-rounding max-fill)
        ├── theme.tsx           # ThemeProvider (psp-theme localStorage, system-watch, .dark class on <html>)
        ├── curveConfigs.json   # curve generator sidecar (prototype bounds) — DEV ONLY, imported by referee, not by app
        ├── curveMath.mjs/.d.mts/.referee.mjs   # byte-exact solady port + CSV referee — DEV ONLY, not bundled
```

## 2. PER-PAGE COMPONENT MAPS

**Shell (App.tsx):** light `bg-gradient-to-b from-sky-50 via-white to-emerald-50` page wrapper (NOT dark-remapped — only inner surfaces are) → Topbar → `<main class="mx-auto max-w-6xl px-4 pb-16 pt-4">` → routes → footer `positive sum pepes — the game that pays you to stay` (slate-400 xs).

**Topbar (all pages):** sticky top-0 z-20, `bg-white/80 backdrop-blur-md border-b border-sky-100`. Left: 32px random pepe (rerolled per load — "the header IS the art") + wordmark (hidden <sm). Center: NavLinks home/trade/stake + **predeposit link injected dynamically** while `round.mode===0 || predepositClosed===false`; active = sky→emerald gradient pill. Right: FaucetButton pill (gated), ThemeSwitcher, ConnectButton (scale-90 wrapper, chainStatus icon, no balance). Mobile: labels collapse (`hidden lg:block` on faucet text).

**Landing "/" (explainer):**
- Hero card (rounded-3xl, sky→white→emerald gradient, 2 blurred `.blob`s): round chip + "built on uniswap v4" chip · H1 `the game that pays you to stay` ("to stay" = gradient clip-text) · sub paragraph · CTA pair (btn-primary `start trading →` / btn-ghost `stake your pepes`) · 3 HeroStats (reserve w/ MixLogo+`mix`, supply PSP, price) fed by useRound.
- "what is this?" — long-form paragraph (the manifesto).
- "the mechanics" — 6 cards from `mechanics[]` const: PixelIcon in gradient tile + title + body (copy in §5).
- lifecycle strip: gradient header bar + 5 steps grid (1 predeposit → 5 rebirth).

**Trade "/trade" (play):** RefBanner → `lg:grid-cols-5` row: SwapCard (col-span-2) + CurveChart (col-span-3) → StatsPanel.
- **SwapCard** props/state: `side buy|sell` (forced sell + toggle disabled in flat mode 2), `amount`, `slippage` (0.5/1/3/5/10% pills + custom ≤90%), `step idle|approve|swap|waiting|done`, `quoteRaw` (4s poll getBuy/SellOutput; flat mode = local psp×R/S), `sellFeeBips` (SWAP_FEE_BIPS read; live hook overstates sells → haircut), `minOut` + `freshMinOut()` re-quote at submit, allowance via useRpcReads. Predeposit phase (mode 0) morphs into predeposit form w/ window-fill bar. Mode-3 banner `💀 this round was carpet-bombed…`, mode-2 `⚪ round is dying — exits are toll-free…`.
- **CurveChart**: `yMode price|supply`, `linTouched` (default LINEAR unless sine active), hover index. SVG viewBox 640×440, PAD {64,16,16,40}; sky→emerald stroke gradient + fade fill, clip path, gridline ticks (1-2-5 log / nice linear), live vertical dash + pulsing dot, hover crosshair + 158×40 tooltip panel, sine markers (pink `#f472b6` tops / amber `#fbbf24` anchors, labels `launch`/`wave 1 top`/…). Footer line `live: … · ● you are here`.
- **StatsPanel ("pot board")**: 3 cards. volume (trades count, 🟦buys/🟩sells chips) · price history (last price + ▲▼% + 220×56 spark of last 40 trades, same gradient stroke) · fees generated (FeesAdded log sum, `4.5% → stakers on every trade · 0.5% → referrals`, `💎 X PSP staked and earning`). Data: getLogs fromBlock 0 + watchBlockNumber re-pull (see §4).

**Stake "/stake":** `lg:grid-cols-2`: StakeCard | (CarpetBombCard + ReferralCard).
- **StakeCard** state: `amount`, `step`, `pickedId` (from PepePicker), `pickerSeed`, `multiStep`, claimGenesis (predeposits poll when mode≥1), parked fees note. Sections: conditional "🐸 unclaimed genesis share" card → parked-fees note → main card (totals PSP/value≈mix/USD, multiclaim+reinvest row, PepePicker, amount input w/ `0 = pepe-only` hint, main CTA ladder, `🐸 hatch another pepe (stake 0)`, faucet row) → "your staked pepes" PepeCards grid → PepePanel.
- **CarpetBombCard** state: `selected Set<pepeId>` (id-keyed, survives reorder), 1s `now`. Phases: none → propose; voting → countdown + yes/no tallies + quorum bar (live denominator totalVotableWeight) + per-pepe vote selector chips (states: voted/unstaking/on) + vote yes/no; executable → `💥 execute carpet bomb`; failed → propose again; executed+flat → boom panel + exit-window countdown → `🪦 close the round…` (finalizeCarpet); executed+destroyed → carried banner.
- **PepeCard (in PepeCards)**: header (id, `unstaked pepe` / `% power` / `fully unlocked`) · Art (LOCAL render always) · staked/value≈mix+USD pair · lock-state strip (`indefinite lock` / `unlocks (vesting) Wd Xh · date` / `🚨 bomb opened all locks → withdraw anytime`) · request/keep-staking + withdraw pair · claim (shows pending mixETH) + reinvest pair. Vest math mirrors stepped decay (6 epochs).
- **ReferralCard**: pepe `<select>` → mono link box (`#/predeposit?ref=<id>`) → copy button; eligibility warning. **RefBanner** (top of Trade+Predeposit): captures ?ref → localStorage `psp-ref` → strips param → bind CTA (`registry.record`) / bound ✓ line / dismissed ✕.

**Predeposit "/predeposit":** header card (round+mode+cap/window chips+⏳ countdown chip) → left col: window-fill progress + depositors/your-deposit pair; deposit card (MixLogo chip, balance-MAX button w/ exact wadToExact, per-wallet cap line, faucet full variant + external ETH faucet link, CTA ladder); launch/claim card (launchable → `launch pooled buy`; launched → claimed ✓ / claim-on-stake redirect) → right col: ReferralCard.

**No dedicated clock component**: countdowns are inline per-surface (Predeposit chip, CarpetBomb voting, PepeCard vest), each a 1s `setInterval` + `fmtCountdown` (d/h/m/s ladder). The "pot": Landing hero reserve stat + StatsPanel fees card + StakeCard value pair.

## 3. STYLING / TOKENS TODAY

Everything lives in `src/index.css` (Tailwind v4 CSS-first; no config file — a `tailwind.config.js` would be IGNORED):

- **Fonts:** `@font-face GeistPixel` (woff2 var, 100–900). `--font-display` token; `body { font-family: var(--font-display); font-variation-settings: "ELSH" var(--psp-elsh) }`. **ELSH axis morphs glyph pixel-shape** (0 regular / 1 square / 20 circle / 40 grid / 60 triangle / 80 line) — site-wide dial at `:root { --psp-elsh: 0 }`. This is THE brand feature of the type system.
- **@theme tokens:** `--color-psp-sky #38bdf8`, `psp-sky-soft #bae6fd`, `psp-mint #4ade80`, `psp-mint-soft #bbf7d0`, `psp-deep #0369a1`, `--font-display`.
- **Dark mode = palette REMAP, not dark: variants.** `@custom-variant dark (&:where(.dark,.dark *))`; then `.dark { --color-white:#0b1424; --color-slate-100..900: navy ramp; --color-sky-50..200: dark tints; --color-emerald-*: dark greens; --color-psp-deep:#7dd8ff … }`. Utilities like `bg-white text-slate-800` literally flip meaning under `.dark`. WCAG-driven (comments cite 4.5:1/3:1 audits 2026-08-27). Some components ALSO use explicit `dark:` classes (PepeCards art tile, ThemeSwitcher, lock strip) — two mechanisms coexist.
- **Chart vars (plain :root so always emitted):** `--chart-grid/-minor/-panel/-panel-border/-live/-hover-dash` + `.dark` overrides. Mixed with HARDCODED hex inside SVG defs (`#38bdf8`/`#4ade80` gradient stops ×2 components, marker `#f472b6`/`#fbbf24`, hover fill).
- **Component classes:** `.card` (rounded-3xl sky-100 border white/90 + soft shadow + blur; `.dark .card` heavier shadow), `.btn-primary` (sky→emerald gradient, rounded-2xl, bold white, active:scale-[0.98], disabled 40%), `.btn-ghost` (white + sky-200 border, psp-deep text), `.input-amount` (2xl bold, sky-50/60 well, focus sky), `.chip` (rounded-full xs bold), `.blob` (blur-64 hero blobs, dark dims to 0.18).
- **Icon/color microsystem:** PixelIcon per-icon palettes (fixed hex: navy `#0F172A`, gold `#FDE68A`, sky `#7DD3FC`, teal `#0D9488`, etc.); MixLogo `dark:drop-shadow` 1px white halo; `text-[#fff]` hardcoded on-gradient-white pattern used everywhere.
- **RainbowKit theming:** App.tsx builds darkTheme/lightTheme with accent `#38bdf8`, accentForeground, borderRadius large, overlayBlur small, modalSize compact; CSS `RainbowKitProvider { --rk-modal-width: 92vw }` under 640px.
- **index.html:** pre-paint `.dark` class script (no flash, key `psp-theme`), theme-color metas `#7dd3fc` light / `#0b1424` dark. Title `Positive Sum Pepes`.

## 4. DATA HOOKS + UPDATE CADENCE

No websockets anywhere. Everything is polling raw `eth_call` through `rpc.ts` (wagmi reads sit idle on custom chains — deliberate architecture, see useRound header). Single chain from `VITE_CHAIN_ID` (default 8453 base).

| lane | mechanism | cadence |
|---|---|---|
| useRound (shared singleton, feeds ALL pages) | pub/sub listeners, one loop: currentRoundId, mixETH, rounds(id), staker, `loadSineCurve` (once per hook: ~110 sinePriceAt burst, cached forever) + 9 parallel calls (mode/reserve/supply/price-or-sinePriceAt(reserve)/curveConfig/zones/totalLocked/predepositState/flatTime) | 4s; fail → backoff 8s→60s |
| useBalances(token,mix) | balanceOf ×2 | 4s |
| useRpcReads(list, enabled) | ordered batch eth_call, key = serialized reads | 6s default; backoff 8s→60s |
| SwapCard quote | getBuy/SellOutput (flat mode: local math) + SWAP_FEE_BIPS once | 4s; re-quoted fresh at submit |
| Predeposit page | predepositState/duration/depositors/predeposits + allowance | 4s each; cap-per-wallet once |
| StakeCard reads | useRpcReads batches + tokenOfOwnerByIndex×n + positions/pendingFeesOf×n; predeposits (claim) when mode≥1 | 6s; claim poll 6s; 4s re-render tick |
| CarpetBombCard | 8-call useRpcReads + per-pepe weight/voted loop | 6s + 5s pepe loop |
| StatsPanel | getLogs(Buy/Sell/FeesAdded, fromBlock 0) + `watchBlockNumber` re-pull | per new block (closest thing to push) |
| PepePanel | primaryOf→dnaOf→descriptor→renderSVG | 6s |
| PepePicker | descriptor once + renderSVG×6 | per seed only |
| Referral (useReferral/useCanRefer ×2 instances) | registry + pepe ids + attribution | 4s |
| useEthUsd | CoinGecko simple/price | 5-min module cache; null on fail (never fake) |
| Countdowns | local 1s setInterval heartbeat | 1s (Predeposit, CarpetBomb, PepeCards) |
| Writes | wagmi useWriteContract (approve→action pattern everywhere, errors truncated to 140 chars) | on-click |

**Env / demo lane (there is no separate "demo mode"):** chain + addresses come from VITE_* envs (anvil by default in .env.local, base in prod). Testnet affordances are env-gated flags in config.ts: `FAUCET_ENABLED = VITE_MIX && VITE_FAUCET` (gates Topbar pill / StakeCard row / Predeposit faucet card + `NATIVE_ETH_FAUCET_URL` external ETH link when `TESTNET_ETH_FAUCET`), `REINVEST_ENABLED = VITE_REINVESTOR`. Graceful-degradation lane when chain/descriptor is down: local `renderPepeSvg` renders the picker/panel/teaser art; flat-mode quotes computed locally; CoinGecko null. `.env.local` takes priority over mode files (documented in .env.sepolia.example).

## 5. COPY INVENTORY (exact strings worth keeping — voice is lowercase, wry, no trailing periods)

**Global:** title `Positive Sum Pepes` · footer `positive sum pepes — the game that pays you to stay` · nav `home / trade / stake / predeposit` · topbar wordmark `positive sum pepes`.

**Landing hero:** chip `built on uniswap v4` · H1 `the game that pays you to stay` · sub: `positive sum pepes is a fully on-chain bonding curve game. buy the dip on the curve, stake for a cut of every trade, and vote to carpet-bomb the round when the cycle is done — the treasury inherits into round n+1.` · CTAs `start trading →` / `stake your pepes` · stat labels `reserve / supply / price`.

**Landing "what is this?" (manifesto, keep verbatim):** `a memecoin with a mechanical soul. PSP mints and burns along a deterministic price curve denominated in mixETH — an ETH yield token. sells on the curve pay a toll that accrues to everyone who stakes, and because the entire reserve sits in mixETH, its yield keeps flowing into the pot from outside the game: your backing compounds whether the chart is green or not. that outside yield is what makes this positive sum — most memecoins recycle nothing. when a round is dying, exits are toll-free at exact average backing — nobody pays to leave a loser. and there is no team allocation silently diluting you: the only way new PSP exists is someone paying real reserves in. and the whole engine is a uniswap v4 hook — the curve lives inside a real v4 pool, so this is v4-grade plumbing under a meme hood, not an erc-20 with a website.`

**Mechanics cards (title → body):**
- `bonding curve` — `every buy climbs a preset price curve; every sell walks it back down. no LPs to farm you, no rug to pull — the curve is the market and it never sleeps. it runs as a uniswap v4 hook on a real v4 pool: battle-tested plumbing, zero custodians.`
- `predeposit window` — `each round opens with a short predeposit window. up to 500 mixETH gets first position at the seed price and PSP auto-locks at launch. miss it and you buy on the open curve.`
- `stake & earn fees` — `lock PSP and every curve fee flows to stakers pro-rata, in mixETH. your bag yield-farms the degens. extend anytime in the final week.`
- `carpet bomb` — `if stakers vote with 69% quorum and a majority, the round is flattened: every lock opens immediately and the curve goes flat so stakers can exit at average backing. after the exit window closes, whatever remains drains to the factory and the next round is born with the treasure.`
- `positive sum` — `the whole reserve sits in mixETH, an ETH yield token curated by alchemix dao — defi OGs running trusted infrastructure since 2021 — so the pot earns from outside the game and your backing compounds even when nobody trades. fees recycle to stakers instead of extracting. the math tilts positive for everyone who stays.`
- `your keys, your pepes` — `non-custodial end to end. mixETH in, mixETH out — every trade settles against the round pool in a single transaction. no admin keys on the curve, no pausing, no upgrades mid-game.`

**Lifecycle strip:** `1 predeposit capped window, pooled genesis buy · 2 launch seed buys mint initial PSP · 3 trade curve market, fees accrue · 4 carpet bomb 69% quorum ends it · 5 rebirth treasure seeds round n+1` (header `round lifecycle`).

**Trade:** `pay / sell / receive (est.) / slippage / custom % / expected out / expected out (after fee) / min out (fresh at submit)` · `flat — pro-rata, fee-free` · `⚪ round is dying — exits are toll-free at exact average backing. buying is disabled.` · `💀 this round was carpet-bombed. wait for round n+1.` · CTAs `buy PSP / sell for mixETH / approve X mixETH / predeposit X mixETH / connect wallet / enter an amount / insufficient mixETH` · chart `the curve`, `● you are here`, `curve data unavailable — waiting for the round`, `loading curve…`.

**Stats:** `volume / price history / fees generated` · `X trades all-time this round` · `🟦 buys / 🟩 sells` · `last 40 trades · mixETH per PSP` · `no trades yet` · **`4.5% → stakers on every trade · 0.5% → referrals`** (fee-split claim — keep in sync with contract params) · `💎 X PSP staked and earning`.

**Stake:** `indefinite lock · fees flow while you stay · request a withdraw to start the 6-week exit ramp` · `0 = pepe only` / `0.0 — or nothing, just the pepe` / `0.0 — new pepe` · `🐸 hatch this pepe (stake 0)` / `🐸 hatch another pepe (stake 0)` · `↑ pick a pepe above to enable staking` · `multiclaim — X mixETH` · `↻ reinvest all / approve & reinvest all` · `⛏ request withdraw` / `↩ keep staking` · `no expiry — request to exit` / `withdraw anytime` / `fully unlocked` / `🚨 bomb opened all locks` · `unclaimed genesis share: your predeposit (X mixETH) has an unclaimed pro-rata PSP share waiting — claiming mints a fresh pepe with the PSP locked in, earning fees from day one.` · parked fees: `⏳ X mixETH of swap fees parked — no staked weight yet, so they attach on the next trade once weight exists. nothing is lost while waiting.`

**Carpet bomb:** `carpet bomb / stakers vote to end the round · treasury inherits into the next` · `no active proposal. initiating a vote requires staked PSP — quorum is measured against locked PSP not currently unstaking (69%), majority of cast votes (50%+).` · `🗳️ voting open / ✅ passed — executable / ❌ failed` · `vote with which pepes?` / `X PSP selected` · `vote yes (n) / vote no (n)` · `💥 execute carpet bomb` · `💥 boom. the curve is flat — every lock is open. unstake and sell at average backing (X mixETH per PSP). buying is disabled until the next round.` · `exit window open · finalize in X · whatever remains seeds round n+1` · `🪦 close the round — carry the remainder to round n+1` · `💥 boom. this round was closed — reserves carried into the next round. head to trade for round n+1.` · `unstaking PSP leaves the quorum pool · new stakes join it and can vote` · `⏳ = unstaking (no vote) — cancel the withdraw on the stake page to restore it` · `stake PSP to propose / initiate vote / 🔄 propose again`.

**Predeposit page:** `commit mixETH before launch — everything pools into the genesis buy, then claim your PSP.` · `window fill / depositors / your predeposit (mix)` · `predeposit window is closed — no new deposits.` · `cap reached or window over — anyone may launch the pooled genesis buy.` / `launch pooled buy` · `✅ claimed — your genesis PSP is locked inside your pepe on the stake page (vesting on the decay schedule, earning fees as they accrue).` · `claim your PSP on the stake page →` / `see your pepe →` · `over the per-wallet cap — max is X mixETH` · faucet `faucet: mint mixETH (free)` / `get base sepolia ETH ↗`.

**Referrals:** `share your link — when they connect and bind, their trades pay you referral fees from the round's swap fees.` · `bind attribution` · `you were referred by pepe #N — connect a wallet to bind` · `✅ referred by pepe #N — attribution bound.` · `pepe #N isn't referral-eligible yet — visitors can't bind to it.` · `stake a pepe to unlock referral links`.

**Pepe art surfaces:** `connect to meet your pepe` · `here's a random one meanwhile — 100M combinations` · `an un-hatched pepe` · `one transaction hatches it — stake any amount, or zero to just collect the art` · `looking for your pepe… if this hangs, the dev chain is down — art still renders locally` · `pepe #N · PSPP` · `rendered on-chain · yours forever` / `local render — same art data the contract draws from` · `choose your pepe` · `rolled fresh from the on-chain renderer · the one you pick is the one you mint` / `rolled locally — same art data the contract renders` · `tap a pepe to select it` / `pepe #N locked in — pick another or stake below`.

**Misc:** theme labels `system theme / light theme / dark theme` · max-fill `balance X MAX` · `faucet · free mixETH` · `get mixETH` · `100M combinations` (trait math: 8 axes × 10 options = 10^8).

## 6. PEPE AVATAR RENDER PATH (on-chain → image)

1. **DNA:** `PSPStaker.dnaOf(tokenId) = uint256(keccak256(abi.encodePacked(tokenId)))` — mirrored client-side in PepePicker.tsx as `dnaOfId(id)` (viem keccak256 of 32-byte hex). Candidate picker ids are random uints ≥ 1e12 (entropy space above the sequential counter).
2. **Canonical art:** `PSPStaker.descriptor()` → `PepeDescriptor.renderSVG(dna)` via eth_call → raw SVG **string injected with `dangerouslySetInnerHTML`**; sizing via arbitrary child selectors `[&>svg]:h-full [&>svg]:w-full` (the SVG ships with no classes). 69×69 viewBox, `shapeRendering="crispEdges"`, background rect = palette slot 15, then RLE layers base → expr → eyes → eyewear → hat → item, each horizontal run = one `<rect>`.
3. **DNA codec v2:** 8 axes × 4 bits (nibbles at shifts 0/4/8/12/16/20/24/28 → expr/eye/hat/wear/item/skin/iris/bg), each `% 10` (counts in pepeArt.json) → 100M unique trait combos.
4. **Art data:** `src/lib/pepeArt.json` (21KB, single line, GENERATED mirror of the contract's PepeArtData — never hand-edit): base sprite RLE, 10× each layer array (null = blank), skins = 10 ramps × 9 slots ×3 bytes, fixedSlots 12, iris/bg tables. Palette: 24 slots assembled from skin ramp + fixed shading + iris (slot 6) + bg (slot 15).
5. **Client mirror:** `renderPepeSvg(dna)` in pepeRender.ts reproduces the exact output. Used for: Topbar logo (`randomDna()` per load), PepePanel teaser + chain-down fallback, PepePicker `localMode` (descriptor unreachable), **PepeCards `Art` — ALWAYS local**, and `PspIcon` (dna `0n` = base pepe = canonical PSP token mark → data-URI with `shapeRendering→shape-rendering` normalization so the `<img>` parse keeps crisp edges).
6. **Red-line:** on-chain output is canonical; the mirror must stay byte-faithful or previews lie about what gets minted.

## 7. RISKS / RED-LINES FOR THE REDESIGN

1. **Dark mode is a variable remap, not `dark:` classes.** `.dark` redefines `--color-white`, slate/sky/emerald ramps and psp tokens. Any NEW utility step you introduce (amber-*, rose-*, slate-600, etc.) that isn't remapped will keep its light value in dark mode → invisible text. The chart `--chart-*` pair must move with the palette. Some components already use literal `dark:` classes (PepeCards, ThemeSwitcher, PepePanel spacing) — two systems coexist; know which one you're touching.
2. **Pepe SVG injection:** every pepe/PixelIcon surface sizes through `[&>svg]` arbitrary selectors + `dangerouslySetInnerHTML`. Restructure the wrapper DOM (add intermediate divs, switch to JSX children, or class the SVG) and art collapses to intrinsic size. On-chain SVG uses camelCase attrs (`shapeRendering`) — only PspIcon normalizes; don't route contract SVG through `<img>`/data-URI without the same fix.
3. **ELSH font axis:** `font-variation-settings: "ELSH" var(--psp-elsh)` on body. Swapping the font stack or dropping the variation-settings kills the site-wide pixel-morph dial (a design knob deliberately left in). New fonts must be weighed against GeistPixel being load-bearing for the pixel identity.
4. **PixelIcon system:** 8 hand-drawn 24×24 grids + per-icon palettes, `shapeRendering="crispEdges"`, aligned `align-[-0.28em]` to text. Replacing with a generic icon library (lucide/heroicons) breaks the art direction AND the icon-iter1 qa proofs. Extend, don't replace; keep palettes deep-shade (icons sit on bright gradient tiles).
5. **CurveChart internals are load-bearing:** hover mapping (`onMove`) inverts the same `sx()` used to draw; viewBox 640×440 + PAD constants are baked into tooltip clamps; gradient/marker colors are hardcoded hex INSIDE `<defs>` (won't follow theme vars). Restyle the frame freely; touch scale math carefully.
6. **Tailwind v4 gotcha:** there is no config file; tokens live in `@theme` inside index.css. Adding `tailwind.config.js` silently does nothing.
7. **Copy is inline JSX (no i18n):** preserve the lowercase voice and the factual claims that mirror contract parameters — `69% quorum / 50%+ majority`, `4.5% → stakers · 0.5% → referrals`, `6-week exit ramp`, `up to 500 mixETH` predeposit cap, `no admin keys on the curve, no pausing, no upgrades mid-game`. Wrong numbers = protocol misrepresentation. (Known drift: UI-CHANGES.md flags Landing mainnet-vs-testnet timing mismatch.)
8. **HashRouter dependency:** referral links are `…/#/predeposit?ref=<pepeId>` — RefBanner captures from hash-query params. Switching to BrowserRouter/history breaks every shared link + the capture path.
9. **RainbowKit theming is duplicated** (App.tsx dark/light theme objects + CSS var for mobile width). Restyle must update both or the modal clashes with the new skin.
10. **Polling architecture is the app:** shared 4s singleton + 6s batchers + backoffs exist because per-component wagmi polling tripped rate limits (comments in useRound/useRpcReads document this). A redesign must keep read fan-out centralized — don't sprinkle new useRound-style loops per component.
11. **Conditional UI gates:** predeposit nav link appears only pre-launch; faucet/reinvest/ETH-faucet surfaces are env-gated (`FAUCET_ENABLED`, `REINVEST_ENABLED`, `TESTNET_ETH_FAUCET`) — mock them OFF in redesign previews or testnet affordances will show in "production" shots.
12. **pepeArt.json + curveConfigs.json + curveMath.\* + root debug scripts are generated/dev tooling** — do not "clean up" or restyle them into the app; pepeArt drift = previews that lie.
13. **No OG/favicon/description/apple-touch icons exist anywhere** (source and dist verified). OG plumbing is greenfield: add to index.html head (plus a static og-image under public/). Note: factory ABI already exposes `html()` (on-chain frontend pattern) — unused by this app; don't confuse the two.
14. **Page wrapper gradient (`from-sky-50 via-white to-emerald-50`) is light-only** — it is NOT remapped in dark mode; dark relies on cards/topbar flipping themselves. A dark page background must be added explicitly or the app edges stay bright in dark mode.
15. **Hardcoded `text-[#fff]` on-gradient-white** appears ~15×; if the gradient brand changes, hunt these (grep `#fff]`) or you get white-on-light labels.
