# PLAN — alt UI motion pass (IBCO pepe prompt, action FX, detonation set-piece)

Scope: **alt UI only** (`frontend`, `npm run dev:alt`, served at http://127.0.0.1:4180). The original UI
must render and behave exactly as before. Branch: `alt-ui-fx` off `single-sine-spec`.

## Ground rules (binding for every slice)

- **Alt-only gating.** Shared files (`Predeposit.tsx`, `PepePicker.tsx`, `DetonateButton.tsx`,
  `useConfirmedWrite.ts`) change only behind `variant="alt"` props or through the FX store, which has no effect
  unless `ActionFxLayer` is mounted. Only `AltShell` mounts it. All new CSS lives in `frontend/public/alt/*.css`
  and is scoped under `.alt-shell` / `body.alt-mode`.
- **Copy stays the same.** Don't add, remove or reword any user-facing text. Decorative glyphs
  (arrows, icons, particles) are fine. FX chips may show numbers the UI already knows (`+1:09`, `+2 seats`).
- **No new chain reads, no new rAF loops.** PhaseEngine is the only rAF loop (CLOCK-REDESIGN §6.7). Build
  motion with CSS keyframes/transitions or the Web Animations API (`el.animate`). No canvas loops, no
  `requestAnimationFrame`, no new npm dependencies.
- **Motion answers the user or the data.** No scroll entrances and no new ambient loops outside the clock and
  the armed detonate button. Hover responses are fine on interactive controls, but not on every card.
- **`prefers-reduced-motion: reduce`** → no transforms, particles or shake. Show a short color or opacity flash
  only. The set-piece becomes a static dim + stamp.
- **Never block input.** FX overlays use `pointer-events: none`. The detonation set-piece is the only overlay
  that catches input: a click or Esc skips it, and it auto-ends in 3s or less.
- **Performance.** Animate only `transform`/`opacity`/`filter`. Allow at most 40 DOM particles per effect.
  Every FX node is removed on `animationend` or after a timeout.

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
export type FxEvent = { id: number; kind: FxKind; anchor?: DOMRect; target?: DOMRect; detail?: string }
export function fireFx(kind: FxKind, opts?: { anchor?: Element | DOMRect; target?: Element | DOMRect | string; detail?: string }): void
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
- `target` accepts a CSS selector that is resolved at fire time, e.g. `'.ladder-panel'`, `'.alt-clock'`,
  `'.header-tools'`, `'.pd-progress'`.
- `ActionFxLayer` is a fixed full-viewport portal with `pointer-events:none` and `z-index: 9000` (below the
  toasts at 10000). It renders active events and calls `done(id)` on finish (or a hard timeout).

### Per-action catalog (each must be visually distinct)

| Action (functionName) | Kind | Animation |
|---|---|---|
| `buyWithMix(Guarded)` | buy | **Ticket punch.** Pixel ticket stubs (one per seat, max 10) print upward out of the button, fly on an arc into `.ladder-panel`. The clock jolts and a `+m:ss` chip floats off it (spec §4.3). Existing PixelBurst stays. |
| `sellToMix` | sell | **Drain.** mixETH coins fall into the button like a slot, with a downward shutter wipe. |
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
| `claimPredepositPSP(WithPepe)` | claimPredeposit | **Hatch.** A card flips from pixel card-back to the pepe face, with a sparkle burst. |
| `claimReferralRewards` | claimReferral | **Chain.** Three nodes link up in sequence along a line toward the anchor, then coins drop. |
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
mock anchors, one button per kind, and a mock detonation stage (fake clock at 00:00:00, fake ladder). It lets
QA trigger and screenshot every effect without a wallet. It is excluded from production builds.

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
- **Success, ≤3s sequence** (`fireFx('detonate')`):
  1. 0–120ms: the screen dims to 70% black.
  2. 120–350ms: a white flash, then the clock slams in at `00:00:00` with a hard glow burst and scale
     1.3→1.
  3. 350–900ms: a shockwave ring expands from the button, the page shakes (translate ±6px, decaying), and a
     pixel debris burst flies out.
  4. 600–1800ms: **carpet bombing.** A row of 12 pixel bombs drops diagonally across the viewport. Each
     lands with a small burst, staggered left to right.
  5. 1800–2700ms: the ladder rows lock (a grayscale sweep) and a "PAID"-style stamp shape hits (glyph only,
     no new copy). A "round archived" card assembles from 4 tiles only if that copy already exists. If not,
     use the existing post-round UI and just reveal it.
  6. Fade out. The existing `onDetonated` flow continues.
- Reduced motion: dim, then a static stamp and fade. No shake or particles.

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
