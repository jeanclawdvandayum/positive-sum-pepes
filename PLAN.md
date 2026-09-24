# PLAN — alt UI motion pass (IBCO pepe prompt, action FX, detonation set-piece)

Scope: **alt UI only** (`frontend`, `npm run dev:alt`, served at http://127.0.0.1:4180). The original UI
must render and behave exactly as before. Branch: `alt-ui-fx` off `single-sine-spec`.

## Ground rules (binding for every slice)

- **Alt-only gating.** Shared files (`Predeposit.tsx`, `PepePicker.tsx`, `DetonateButton.tsx`, `Stake.tsx`,
  `useConfirmedWrite.ts`) change only behind `variant="alt"` props or through the FX store, which has no effect
  unless `ActionFxLayer` is mounted. Only `AltShell` mounts it. All new CSS lives in `frontend/public/alt/*.css`
  and is scoped under `.alt-shell` / `body.alt-mode`.
- **Copy stays the same.** Don't add, remove or reword any user-facing text. Decorative glyphs
  (arrows, icons, particles) are fine. FX chips may show numbers the UI already knows (`+1:09`, `+2 seats`).
- **No new chain reads, no new rAF loops — one scoped exception (Round 4).** PhaseEngine stays the only
  permanent rAF loop (CLOCK-REDESIGN §6.7). Everything else is CSS keyframes or `el.animate`. The
  detonation set-piece's 3D scene (`src/alt/fx/boom3d.ts`, three.js) may run its own
  `requestAnimationFrame` loop **only while the set-piece is mounted**: created lazily, started just
  before the blast, stopped on finish, skip or unmount, and disposed completely (renderer, geometries,
  materials, `forceContextLoss`, canvas removed). Under `prefers-reduced-motion: reduce` it never loads.
  `three` is the one sanctioned npm dependency added since Round 1, loaded in a lazy chunk (see Feature 4).
- **Motion answers the user or the data.** No scroll entrances and no new ambient loops outside the clock,
  the armed detonate button and the hatch egg waiting to be tapped. Hover responses are fine on interactive controls, but not on every card.
- **`prefers-reduced-motion: reduce`** → no transforms, particles or shake. Show a short color or opacity flash
  only. The set-piece becomes a static dim + stamp (no 3D, and the three.js chunk is never fetched).
- **Never block input.** FX overlays use `pointer-events: none`. Two FX overlays catch input and never trap
  the user: the detonation set-piece (a click or Esc skips it; it auto-ends at ~6.2s) and the hatch modal
- **Performance.** Animate only `transform`/`opacity`/`filter`. Allow at most ~50 DOM particles per burst
  (pepe confetti: ≤46). Every FX node is removed on `animationend` or after a timeout.

## Feature 1 — IBCO: highlight the pepe selector (the primary ask)

Files: `src/pages/Predeposit.tsx`, `src/components/PepePicker.tsx`, `public/alt/polish.css`.

- `needsPepe = variant==='alt' && artVersion===2n && !(reservedPepe && reservedPepe>0n) && selectedPepe===null && amountWad>0n && !pd?.closed`.
  The prompt shows whether or not a wallet is connected.
- Pass `attention={needsPepe}` to `PepePicker` (a new optional prop, default false). The picker sets
  `data-attention` on its root.
- Attention treatment (alt CSS):
  - Two strong pulses of a `--green` outline and glow on the picker card, then a steady glow ring while it
    still applies.
  - A one-time staggered hop across the 6 tiles (translateY −4px, 40ms stagger).
  - The existing helper line "tap a pepe to select it" turns `--green`, with a small bobbing ↑ glyph.
  - Retrigger the pulse when the amount changes from empty to non-empty.
- When the amount input blurs while `needsPepe` is true and the picker is outside the viewport, smooth-scroll
  the picker into view (`block:'center'`). Don't do this while the user is typing.
- On selecting a tile, the glow resolves: the ring fades and the selected tile plays a stamp-pop (scale
  1→1.08→1) with the ✓ badge popping in.

## Feature 2 — Hover and micro polish (opus design pass)

File: `public/alt/polish.css`. Scoped CSS; small TSX hooks only where a class or attribute is needed.

1. **Primary buttons** (`.btn`, `.btn-primary`, `.tx-action`): a diagonal sheen sweeps once on hover. Press
   depresses 1px. Enabled CTAs fill the accent from left to right on the change from disabled to enabled
   (the button "arms").
2. **Pepe tiles** (picker, stake picker): hover lifts 3px, tilts −2°, adds a `--green` edge glow and runs
   `image-rendering:pixelated` a crisp 1-step scale. Taken tiles don't react.
3. **Refresh (die) button**: the die rolls (360° in steps(4)). The new tiles deal in with a 30ms stagger.
4. **Nav links**: the underline slides in from the left on hover. The active link underline slides between
   routes (view transition or a pseudo-element).
5. **Buy/sell tabs**: a sliding indicator slab moves between tabs.
6. **Ladder rows** (`.ladder-row`): hover brightens the row and grows the share bar 4%. Your own rows (`.you`)
   get a slow 1-pass border shimmer when they first appear.
7. **Amount inputs**: on focus the green outline grows from the caret side. Invalid input shakes 2px, with a
   red flicker.
8. **Theme toggle**: the sun rotates 90° on click.
9. **Instrument pot / pooled total**: when the value changes, the digits flash `--amber` for 600ms. This is
   the spec's odometer flash and works as a data response.
10. **Header wallet pepe chip**: a subtle breathing glow only while a tx is pending.

## Feature 3 — Action FX engine + unique per-action animations

New files:

- `src/lib/actionFx.ts`
- `src/alt/ActionFxLayer.tsx`
- `src/alt/fx/*.tsx` (one small component per effect, or a single map)
- `public/alt/fx.css`
- `src/alt/FxLab.tsx`

Edits: `src/lib/useConfirmedWrite.ts`, `src/alt/AltShell.tsx`, the clipboard call sites.

### Contract (every slice builds against this)

```ts
// src/lib/actionFx.ts
export type FxKind =
  | 'buy' | 'sell' | 'predeposit' | 'launch' | 'stake' | 'topUp' | 'claimFees' | 'reinvest'
  | 'requestWithdraw' | 'cancelWithdraw' | 'unlock' | 'claimPot' | 'redeem' | 'claimPredeposit'
  | 'claimReferral' | 'nameCommit' | 'nameRegister' | 'refLink' | 'shareImage' | 'faucet'
  | 'transferPepe' | 'approve' | 'spawn' | 'detonate' | 'fail'
export type FxPepe = { id: bigint; dnaVersion: bigint }   // the pepe a hatch reveals (DNA = keccak(id))
export type FxEvent = { id: number; kind: FxKind; anchor?: DOMRect; target?: DOMRect; detail?: string; pepe?: FxPepe }
export type FxOptions = { anchor?: Element | DOMRect; target?: Element | DOMRect | string; detail?: string; pepe?: FxPepe }
export function fireFx(kind: FxKind, opts?: FxOptions): void
export function fxKindFor(functionName: string): FxKind | undefined   // maps every write functionName
export const actionFx: { subscribe(l: () => void): () => void; snapshot(): FxEvent[]; done(id: number): void }
export function captureAnchor(): Element | undefined  // last pressed button within 2s
```

- `actionFx.ts` installs one capture-phase `pointerdown` + `keydown`(Enter/Space) listener. It records the
  nearest `button, [role=button], a` as the last pressed element with a timestamp. It installs lazily on the
  first `subscribe`, so the original UI never installs it.
- `useConfirmedWrite`:
  - `confirmed()` snapshots `captureAnchor()` at start.
  - On success it calls `fireFx(fxKindFor(functionName), { anchor })`. On a real failure (not a user
    rejection) it calls `fireFx('fail', { anchor })`. Validate-only calls fire nothing.
  - `writeWithApprovals` fires the action kind, not `approve`.
  - `fireFx` is a no-op without subscribers.
  - A third, FX-only argument `{ pepeArt }` (the staker's DNA version, passed by `Stake` in alt) lets a
    confirmed predeposit claim fire `pepe`: the id comes from `claimPredepositPSPWithPepe`'s args, or for
    `claimPredepositPSP` from the receipt's ERC-721 mint (`lib/hatchFxPepe.ts`; an automatic address-id
    mint has genesis art, not keccak(id), so it reveals a decorative pepe). No new chain reads.
- `target` accepts a CSS selector that is resolved at fire time, e.g. `'.ladder-panel'`, `'.alt-clock'`,
  `'.header-tools'`, `'.pd-progress'`.
- `ActionFxLayer` is a fixed full-viewport portal with `pointer-events:none` and `z-index: 9000` (below the
  toasts at 10000). It renders active events and calls `done(id)` on finish (or a hard timeout: 4s, 7s for
  `detonate`). `claimPredeposit` renders the hatch modal in its own portal at 9500; it ends when dismissed.

### Per-action catalog (each must be visually distinct)

| Action (functionName) | Kind | Animation |
|---|---|---|
| `buyWithMix(Guarded)` | buy | **Ticket punch.** Pixel ticket stubs (one per seat, max 5) print upward out of the button and land on the ladder's top seats (newest first), each seat flashing as it is taken. The clock jolts and the confirmed `+m:ss` chip floats off it (spec §4.3). A burst of smile/smirk/amazing pepe confetti flies from the button. |
| `sellToMix` | sell | **Drain.** mixETH coins fall into the button like a slot, with a downward shutter wipe, while a burst of rage/angry/sad/meh pepe confetti flies out of it. |
| `predeposit(WithPepe)` | predeposit | **Cannonball.** A clone of the selected pepe tile arcs from the picker into `.pd-progress`. Water-ripple rings spread on the pooled card and the total flashes. |
| `launchPooledBuy` | launch | **Ignition.** A flare streak rises from the button, the whole page gets a brief warm flash, and the clock digits "power on" segment by segment. |
| `lockWithPepe`, `lock` | stake | **Clamp.** A pixel padlock drops onto the anchor, the shackle snaps shut with a 2-frame squash, and chain links flash across. |
| `stakeFor` | topUp | **Feed.** PSP pixels stream into the pepe card, which does a satisfied bounce. |
| `claimAllTo`, `claim*Fees`, `claimMany` | claimFees | **Fountain.** Coins burst up from the button and arc into the header wallet chip, which pulses once. |
| `reinvest`, `reinvestAll` | reinvest | **Loop.** Coins orbit the anchor in a circular trail and dive back into the pepe card, with a ⟳ trace. |
| `requestWithdraw` | requestWithdraw | **Hourglass.** The hourglass flips and the 6 vest pips light in sequence. |
| `cancelWithdraw` | cancelWithdraw | **Rewind.** The hourglass flips back, the pips unlight in reverse and the padlock re-snaps. |
| `withdraw`, `exit` | unlock | **Break free.** The padlock shackle pops open and the pieces tumble. |
| `claimPot` (play + graveyard) | claimPot | **Jackpot.** Gold pixel confetti falls from the top edge (≤40 pieces). The anchor gets a stamped "✓" seal. |
| `redeemBacking` | redeem | **Transmute.** PSP pixels ignite into embers, which cool into mixETH coins rising from the anchor. |
| `claimPredepositPSP(WithPepe)` | claimPredeposit | **Hatch.** A centered modal: a pixel egg wobbles on a spotlit pedestal (tap hint; hover cracks it). Tap/Enter/Space: shake → cracks → the shell bursts → a tadpole wriggles out → legs → froglet → the claimed pepe's real art (`renderPepeSvg`, decorative if unknown) with a light burst, sparkles and a bounce. Esc, click outside or close dismisses. |
| `claimReferralRewards` | claimReferral | **Chain.** Three nodes link up left to right across the anchor, then coins drop onto it. |
| `commit` (name) | nameCommit | **Wax seal.** A seal stamps down onto the anchor with a squash and ink splash. |
| `register` (name) | nameRegister | **Nameplate.** A plate slides under the anchor, a typewriter caret sweeps across it, and a sparkle follows. |
| clipboard ref link (`ReferralCard`, `ReferralsCard`) | refLink | **Link forge.** Two chain halves snap together, then a paper plane flies off. No new text. |
| clipboard share image (`ReferralShare`) | shareImage | **Polaroid.** A camera flash, then a mini frame drops and settles. |
| `drip` (faucet) | faucet | **Drip.** Three droplets fall from the top of the anchor and splash into the balance. |
| `safeTransferFrom` | transferPepe | **Send-off.** The pepe card slides off to the right with a motion trail. |
| `approve` (standalone) | approve | **Key turn.** A small key rotates 90° inside the button. Keep it subtle. |
| `reserveSpawn`/`birthStep` | spawn | **Respawn.** Reuses the landing `xd-respawn-roll` motif: an egg rolls and a pepe pops out. |
| failure | fail | The anchor shakes 3px twice and flickers red. No particles. |

`FxLab` (`#/fx-lab`, **DEV only**: `import.meta.env.DEV` guards both the route and the import) is a grid of
mock anchors, one button per kind, and a mock detonation stage (fake clock at 00:00:00, fake 5-seat ladder). The
mock pepe card previews the pepe `claimPredeposit` will hatch (↻ rerolls the id); `claimPredeposit (no id)`
hatches a decorative pepe. It lets QA trigger and screenshot every effect without a wallet. It is excluded
from production builds.

## Feature 4 — Detonation set-piece (carpet bomb)

Files: `src/pages/play/DetonateButton.tsx` (alt-gated via `variant="alt"`, passed from `AltPlay`),
`src/alt/fx/DetonationSetPiece.tsx`, `public/alt/detonation.css`.

Contract: `export default function DetonationSetPiece({ onDone }: { onDone: () => void })`.
`ActionFxLayer` renders it for kind `detonate`.

- **Armed (clock at zero, idle):**
  - Hazard-stripe border crawl on the button.
  - A pixel fuse spark flickers on the bomb icon.
  - A slow red heartbeat glow (the one sanctioned ambient loop besides the clock, and only at zero).
  - Hover: the stripes speed up and the bomb wobbles.
  - Press: the button depresses 2px.
- **Pending (wallet + mining):** the fuse burns along the button's bottom edge as the pending fill. The spark
  travels, and the label stays as-is.
- **Success, ~6.2s sequence** (`fireFx('detonate')`; skippable by click or Esc at any beat):
  1. 0–900ms **alarm:** the screen dims to 50%, three red vignette pulses, two siren beams sweep, hazard
     tape slides onto the top and bottom edges.
  2. 900–1300ms **slam:** a white flash, then `00:00:00` in `--time-lit` (forced to the critical red) lands
     from scale 3.4 with a red glow; the dim deepens to 82%; a square shockwave ring leaves the button.
  3. Shake in three stages (page + stage, element.animate, restored exactly): A ±12px at 1000ms, a ±3px
     rumble 1600–3200ms, C ±18px at 3250ms.
  4. 1600–2950ms **carpet bombing:** two passes of 12 pixel bombs (left→right under the clock, then
     right→left above it), each landing in a fireball with a hanging smoke puff.
  5. 3250ms **blast — the 3D cloud takes over** (`src/alt/fx/boom3d.ts`, lazy `import()` behind
     `boomLoader.ts`; the armed button prefetches the chunk, and the set-piece creates the scene at mount
     so its shaders compile during the alarm): a hard 40ms screen flash, then a volumetric pixel-3D
     nuke — ignition fireball, a rising rolling toroidal cap with internal churn that cools
     white→yellow→orange→red→smoke with an ember-lit underside, a swirling stem, a base-surge dust
     skirt spreading along the ground, a racing ground shockwave ring and a condensation shell — plus a
     slow camera push-in and a decaying camera shake under the DOM page shake. Rendered at 1/4 (1/3 on
     narrow screens) of the viewport and upscaled `image-rendering: pixelated`, posterized to a
     9-color theme palette (`--boom-*` on `.dtn-stage`) with edge Bayer dithering; 1,651 GPU puffs in
     one draw call, analytic (no CPU sim), driven by the stage's own CSS clock. The clock is knocked
     up and back and the cloud rises beneath it.
  6. 3350–5300ms **debris:** 16 pixel chunks and two flank bursts of pepe confetti thrown from
     behind the cloud.
  7. 4200ms **lock:** the ladder rows gray out left to right and the "PAID"-style stamp glyph hits the
     clock's corner (no new copy).
  8. 5300–6200ms **settle:** the dim relaxes to 45%, the 3D cloud dither-dissolves, the tape leaves,
     the stage fades out. The existing `onDetonated` flow continues.
- Fallbacks: no hardware WebGL2 (probed with `failIfMajorPerformanceCaveat`), a failed chunk fetch, or
  the scene not ready by the blast → the run keeps a rebuilt CSS cloud (same `--boom-*` palette: a
  cel-shaded cap/stem/skirt of stacked `currentColor` box-shadow lobes that cool with one `filter`
  ramp) plus the existing shockwave and ground ring.
- Reduced motion: dim, then a static stamp and fade (≤1.2s). No shake, particles or 3D — the three.js
  chunk is not even fetched.

## Build order and ownership (parallel, glm-5.3-flash implementers)

|Slice|Owner|Files (exclusive)|
|---|---|---|
|A: IBCO highlight + polish|GlmIbcoPolish|`Predeposit.tsx`, `PepePicker.tsx`, `public/alt/polish.css`, tiny class hooks in `AltTrade.tsx`/`AltPlay.tsx` ladder markup|
|B: FX engine + catalog + lab|GlmFxEngine|`src/lib/actionFx.ts`, `useConfirmedWrite.ts`, `src/alt/ActionFxLayer.tsx`, `src/alt/fx/*` (except DetonationSetPiece), `public/alt/fx.css`, `src/alt/FxLab.tsx`, `AltShell.tsx` (mount layer, lab route, add `polish`/`fx`/`detonation` to the stylesheet list), clipboard call sites|
|C: Detonation|GlmDetonation|`DetonateButton.tsx`, `src/alt/fx/DetonationSetPiece.tsx`, `public/alt/detonation.css`, the `variant="alt"` prop at the `AltPlay` call site|

Implementers skip project-wide gates. Each one runs only `./node_modules/.bin/tsc -b` from `frontend/` before
reporting.

## QA (astra + opus 5.5 reviewers → feedback to the owning glm implementer via hub)

- **Astra:** correctness and robustness.
  - Alt-only gating: the original UI is untouched.
  - Reduced motion.
  - No rAF, no new reads, no new deps.
  - Listener leaks and cleanup.
  - Copy unchanged (diff check).
  - `pointer-events`.
  - z-index versus toasts.
  - Mobile at 390px.
- **Opus 5.5:** design quality. Checks that each effect is distinct, readable and on-brand (pixel, amber =
  time/money, green = action), that timing and easing feel right, and that detonation is "screenshot-worthy".
- Both drive the live dev server: `#/predeposit` for Feature 1, `#/fx-lab` for Features 3–4, and every route
  for Feature 2.
- Feedback goes directly to the owning implementer. Allow at most 2 fix rounds, then a final verdict.

## Done when

- Feature 1 is verified on the live IBCO page (amount entered, no pepe → highlighted; select → resolves).
- Every catalog row fires distinctly in FxLab, and each call site maps through `fxKindFor`.
- The detonation set-piece plays in FxLab and is wired to real `detonate()` success.
- `tsc -b`, `npm run build:alt`, the default `vite build` and `frontend/tests` all pass.
- The original UI shows no visual diff on `/`, `/play` and `/predeposit`.
- One commit per feature on `alt-ui-fx`.

---

# Round 2 — wallet modal, picker spacing, truthful buy chip

## Feature 5 — RainbowKit modal in the alt style (alt only)
- `frontend/src/App.tsx`: when `VITE_ALT_UI === '1'` pass an alt theme from new `frontend/src/alt/rainbowTheme.ts`;
  the original UI keeps its current dark/light themes byte-for-byte.
- The alt theme is built on `darkTheme()`/`lightTheme()` (for resolved mode) but every color, font, radius and
  shadow points at alt CSS variables (`var(--panel)`, `var(--ink)`, `var(--green)`, `var(--line)`,
  `var(--body)`, …). The variables switch with `html[data-theme]`, so one mapping covers day and night.
- All radii are `0`. Fonts: body = `var(--body)`; titles use `var(--display)` via scoped CSS overrides in
  `public/alt/polish.css` under `body.alt-mode [data-rk]`. Shadows are hard offsets (`5px 5px 0 var(--shadow)`), with no blur.
- The overlay matches the site (dim scrim; blur `none` or `small`). Buttons follow the alt button language:
  square, green action and hard shadow.
- Covers the connect, account and chain modals. Text stays as RainbowKit renders it.

## Feature 6 — Pepe picker spacing (IBCO, alt only)
- The picker card on `#/predeposit` has large blank areas: the grid is capped at 370px and centered inside
  a card that spans two rows. In alt, the tiles grow to fill the card width (3×2 grid, even gaps), and the
  card's vertical space is used without empty bands.
- The helper line "tap a pepe to select it" (and its selected-state text) aligns with the left edge of the
  tile grid.
- The stake page picker must not regress (check `#/stake`). Mobile 390px stays usable.

## Feature 7 — Buy success chip reports confirmed facts only
- Delete the pre-sign estimate (`primeFxDetail` in AltTrade). Remove `primeFxDetail`/`takeFxDetail` and all
  their plumbing if nothing else uses them.
- In `useConfirmedWrite`, the `wait` step already fetches the receipt. Keep that receipt (don't read it a second time),
  decode `TimeAdded(address,uint256,uint256)` (ABI in `lib/abi.ts`) from its logs, and use the confirmed
  `secondsAdded` for the buy chip as `+m:ss`. `secondsAdded == 0` (clock at cap) → no numeric chip. No seat
  count, because seats can't be derived exactly from the events.
- Put the decode in a pure exported helper, and cover it with a node test in `frontend/tests/`. The test builds
  realistic receipt logs:
  - the normal case;
  - a clock capped by a concurrent buy (seconds smaller than the estimate);
  - zero seconds;
  - no TimeAdded log;
  - an unrelated log first.

---

# Round 3 — fun pass (hatch modal, pepe confetti, long detonation)

## Feature 8 — Pre-built pepe confetti sprites
- `frontend/scripts/gen-confetti-sprites.mjs` (node, no deps: `node --experimental-strip-types
  scripts/gen-confetti-sprites.mjs` from `frontend/`) renders 100 distinct pepes per mood with the real
  release-2 art (`renderPepeSvg`), rasterises them and writes one indexed PNG per mood to
  `public/alt/confetti/` (`sad`: RAGE/ANGRY/SAD/MEH, `happy`: SMILE/SMIRK/AMAZING; 10×10 cells of 69px) and
  the index `src/alt/fx/confettiSheets.json`. Deterministic seeds; nothing is generated at runtime.
- `src/alt/fx/confetti.tsx` samples distinct sprites per burst (background-position into the sheet),
  mixes in plain pixel squares (≤46 nodes), and flies them on gravity arcs clamped to the viewport.
  Sell, buy and the detonation use it.

## Feature 9 — Hatch modal, long detonation, global pass
- Hatch modal: see the catalog row and the `useConfirmedWrite` contract note above (`src/alt/fx/HatchModal.tsx`).
- Detonation: see Feature 4 (~6.2s beats; Round 4 added the 3D cloud).
- Global pass: every effect is centered on its anchor, glyphs are sized to read (coins 11px, padlock 26px,
  seal 34px, …), glyph colors hold contrast in both themes, the clock chip is 15px bold on the clock
  housing and prefers an on-screen clock, and particles stay inside a 390px viewport.

---

# Round 4 — the 3D mushroom cloud (three.js)

The CSS cloud read as child-like. The blast is now a real volumetric explosion.

## Feature 10 — Pixel-3D nuke (`three` in a lazy chunk)
- `frontend/package.json` adds `three` (+ `@types/three` dev-only). It never touches the entry bundle:
  `src/alt/fx/boom3d.ts` is only reachable through the dynamic `import()` in `src/alt/fx/boomLoader.ts`,
  which the armed alt detonate button prefetches and the set-piece awaits. `vite build` confirms three
  lives in its own chunk, and the default (non-alt) build pulls it nowhere (the prefetch is behind
  `VITE_ALT_UI === '1'`, statically eliminated).
- See Feature 4 step 5 for the scene contract (palette, puffs, timing, camera) and the fallback ladder.
- Verification notes (2026-09): a locked 60fps at 1440×900 (165 frames over the blast window: mean 16.67ms,
  p95/p99/max 16.8ms, zero frames over 20ms; boom CPU cost ≤0.8ms/frame; 1,651 instances). Skip at
  120/1200/3200/3300/4000/4600/5000/5900ms leaves no canvas, no rAF and no console warnings, and restores
  the page transform exactly. Aborted/slow three.js fetches and blocked WebGL2 fall back to the CSS cloud;
  reduced motion never fetches the chunk.
