# PSP session state — 2026-08-17

## UPDATE 2026-08-26: A-1 FIXED — referral attribution poisoning (HIGH, audit 2026-08-23)

**the fix (design: user-signed binding only):**
- `CurveHook`: hookData slims to a 32-byte `(trader)` payout hint; the lazy
  `recordFor` block is deleted — swaps can never CREATE attribution. Forged
  64-byte payloads are length-mismatched → ignored wholesale.
- `PSPReferralRegistry`: fully permissionless — `recordFor`, `setRecorder`,
  `authorizedRecorders`, `owner`, `NotAuthorized`/`NotOwner`,
  `RecorderAuthorized`, dead `StakerUpdated` all deleted. Ctor `(staker, minStake)`.
  `record()` (msg.sender-bound) is the ONLY bind path.
- Zaps drop the lying `referrerNftId` param (pre-deploy clean break; frontend
  never used it); encode only the trader identity (2026-08-19 always-carry fix preserved).
- Factory/HookDeployer: recorder wiring deleted; `deployRegistry(staker, minStake)`.
- UX change: binding is order-insensitive now — record() any time; trades before
  the record pay stakers (nothing consumed by trading).

**tests:** PoC flipped to `test_PoC_ForgedHookDataCannotStealAttribution`
(byte-identical attack, hijack blocked, attacker earns 0, victim binds intended
referrer after). Referral.t.sol R1 (explicit record + AlreadyReferred + inert
later refs), R2 (no lazy swallow path), R6 (user-signed cycle guard) rewritten.
62 zap callsites swept (param drop) + Longitudinal `_buyViaZap` binds via record().

## UPDATE 2026-08-24 (c): DARK/NIGHT THEME + system/light/dark switcher

**what shipped:** full dark theme via Tailwind v4 variable remap — zero changes
to component markup for surfaces/borders/text. `frontend/src/lib/theme.tsx`
(ThemeProvider: mode = system|light|dark, localStorage key `psp-theme`,
matchMedia listener while in system mode, toggles `.dark` on `<html>`).
`index.css` `.dark {}` block remaps `--color-white/sky-*/emerald-*/slate-*` to a
deep-navy night palette; `--color-psp-deep` → `#53c2ff`. Chart SVG hexes
replaced with `--chart-*` vars (grid/minor/panel/border/live/hover-dash).
**10 `text-white` uses on accent surfaces pinned to `text-[#fff]`** so the
white-var remap only hits backgrounds. FOUC guard script in `index.html` applies
saved theme pre-paint. RainbowKit theme follows resolved mode (App.tsx Shell).
Switcher: `components/ThemeSwitcher.tsx` — 3 SVG-icon segmented pill in Topbar.
Live-verified on ebony-grace-drd5.here.now: dark bg #0b1424, chart gridlines
resolve #16233c, persistence across reload, all three modes, light unchanged.

## UPDATE 2026-08-20: TRAIT STUDIO SHIPPED + QA'D — wave-2 fully closed

**what shipped:** a single-file, zero-dependency GUI (Trait Studio) replacing
hand-editing of ASCII trait files. 48×48 pixel-grid editor with real palette
colors, live pepe preview, and one-click compile to `PepeArtData.sol`.
**local `studio/dist/trait-studio.html` is the current canonical build** (works
via file:// double-click).

**repo map (studio/):**
- `compiler.js` — JS UMD port of `script/gen_pepe_art.py`, proven BYTE-IDENTICAL
  to the python: compiled output === golden `src/PepeArtData.sol` (8303 bytes,
  sha256 `963b1862…8ce72d`; an earlier "8299" quote was wrong — sha was always right)
- `test_compiler.mjs` — referee test: grid round-trips ×26 traits, byte-exact
  re-serialization ×5 trait files, output ≡ golden. run: `node studio/test_compiler.mjs`
- `spec/COMPILER_SPEC.md` (compiler API contract), `spec/APP_SPEC.md`, `README.md`
- `qa/QA_REPORT.md` — fresh-eyes QA report (80+ checks)
- gotcha: repo `package.json` is `type: module` → UMD attaches to
  `globalThis.PSPCompiler` under node ESM, not `module.exports`

**features:** pencil/eraser/fill/line/rect/eyedropper, mirror-X, ghost underlay,
cell-size slider · trait add/rename/delete/move with DNA-shift warnings · palette
dock · live preview with skin/iris/bg + RANDOM + PNG export · compile modal with
sha256 + "identical to repo build ✓" banner · import/export files · localStorage
persistence · built-in self-test.

**how it was built (3 agents, fresh eyes):** A ported the compiler (byte-identical
proof), B built the GUI (attempt 1 died silently mid-gen; attempt 2 landed as 5
modules — B also caught a real bug: NEUTRAL expression wasn't overlaying the base
head, fixed), C ran fresh-eyes QA.

**post-QA fixes (applied AFTER qa/QA_REPORT.md was written — report predates them):**
- **P1:** modal buttons (delete/rename/move confirms) never dismissed — promise
  wrappers never called `close()`; a stale dialog could lock keyboard shortcuts.
  patched all 3 modal helpers; browser-verified (delete → modal closes, no lockout).
- **P2:** dirty-dot tooltip went stale after painting — patched, title flips with state.

**gates at close:** referee test ALL CHECKS PASSED · full `forge test` 571/571
green (08-20 overnight run; supersedes the 08-19 "542 green + 4 knowns" count
below) · browser: self-test pass, zero console errors, paint→preview updates,
undo works, compile modal reports identical-to-repo ✓

**deployment state:** https://oaken-marvel-3e24.here.now is STALE (published
pre-QA-fix) and was a 24h anon deploy anyway. claim (permanent):
https://here.now/c/CBLKnsishm6RbdXj. NOTE: this is the *studio* site — separate
from the protocol frontend demo at rosy-palm-vzxv (08-18 section below).

**edit flow going forward:** paint in studio → Compile → drop `PepeArtData.sol`
into `src/`, OR Export Files → `script/traits/`. both doors are byte-exact.

**next-session checklist:**
1. republish studio from `studio/dist/` (bash
   `~/.hermes/skills/here-now/scripts/publish.sh <dir> --client hermes`; publish.sh
   patched 2026-08-19 to not clobber claimToken; first publish NO --slug, updates
   WITH --slug) — then verify modal-fix behavior on the live URL
2. QA round 2 corners: compiled-download byte-compare vs golden, reload
   persistence, 375px viewport, palettes-tab editing
3. kill stray local http.servers if still up: ports 8791, 8792 (pid 47140)

## UPDATE 2026-08-19: ALL AUDIT FINDINGS RESOLVED — C-1 AND F-9 BOTH FIXED

**C-1 hook-squat FIXED (fork-verified):** entropy-keyed salts
(`keccak(prevrandao,timestamp,number,controller)` base, counter-offset) + occupied-candidate fall-through (4 candidates, atomic probe-then-create2) in HookDeployer/HookMiner. Pre-squat impossible; same-block front-run needs all 4 candidates re-squatted every retry block; residual = proposer-level grief (defense: private relay + retry). ControllerDeployer EIP-170 headroom (629B) untouched. Gas: honest finalize 8.1M / 1-squat 8.8M (pinned draws). Frontends must READ hook addresses from round state — no longer precomputable (update before republish).

**F-9 flat-window pot FIXED (zero-fee flat window):** CurveHook charges NO swap fee in Flat mode — dying-round trades accrue nothing to pot or stakers, and exits pay exactly pro-rata avg backing (floor-only, no toll). Kills F-9 at the source: no pot accrual → nothing stranded at finalize. No RoundController/ControllerDeployer changes; CurveHook shrank 279B. Flat round trips break exactly even. Commits: `92549eb9` (C-1), `819aa427` (F-9).

**Suite state: 542 green.** The only 4 failures are the adjudicated test-side knowns (B7b/d/e harness bugs + B4j fuzz epsilon), documented in the wave-2 adjudication skill ref.

resume-from-here doc. read this + `git log --oneline -5` to get back up to speed.

## what PSP is
bonding-curve memecoin lab: swaps route through a v4-style pool with CurveHook
(solidity, foundry, mock pool manager for anvil). swap fees split 4.75% -> stakers
/ 0.25% -> side pot (the pot leg accrues in PSP). quote currency is mixETH.
stakers lock PSP for 90d to earn fee share + vote rights.

## the big arc: two-phase carpet bomb (DONE, tested, live-verified)
old behavior was wrong: carpetBomb() flattened then instantly destroyed+drained+spawned
in the same tx, so the exit window closed instantly.

new semantics per scoopy's intent:
- `carpetBomb()`:
  1. pot's PSP auto-sells FIRST via `hook.redeemPotBacking()` at exactly
     `(reserve * psp) / supply` = the flat rate (average backing). pot PSP burned,
     mixETH ring-fenced to factory via `creditSidePot()` for round 2's bonus depth.
     emits `CarpetBombExecuted(potRedemption)`.
  2. mode -> Flat, stamps `flatTime = block.timestamp`. no destroy, no drain, no spawn.
- while `flatTime != 0`: `unlock()` bypasses the 90d expiry (locks force-open),
  `lock()`/relock revert `RoundFlattened`, bomb voting closed (Flat and Destroyed both gate).
- stakers exit by selling through the normal zap: `_handleFlatSell` pays average
  backing minus 5% exit toll. ratio-preserving math: reserve/supply constant no
  matter how many exit, no last-runner advantage. pot redemption uses the same
  formula so it doesn't move the rate either.
- `finalizeCarpet()` — permissionless, callable after `FLAT_EXIT_WINDOW = 3 days`:
  destroys, drains remaining mixETH to factory, spawns round 2. idempotent
  (hook refuses Destroyed -> Destroyed). EIP-170 clean (dropped a redundant
  `roundFinalized` bool to reclaim 17 bytes).

## commits
- `08b1985` flat exit rewiring + finalizeCarpet + test updates
- `859098a5` test proving side-pot auto-sell executes at flat rate

## tests: 350/350 (30 suites)
new `test/unit/FlatExit.t.sol`:
- `test_FlatExit_StakerUnlocksEarlyAndSellsAtAverageBacking` — alice unlocks with
  90d still on the clock; sells at avg backing minus toll (exact-value assert);
  pot redemption == (reserveBefore * potPSPBefore) / supplyBefore; factory balance
  credited exactly; flat rate unchanged by the redemption (assertApproxEqAbs 5 wei).
- `test_FlatExit_UnclaimedBackingInheritsToRound2` — nobody exits during window,
  finalizeCarpet carries full reserve to round 2.
- ~10 older tests updated to bomb -> `skip(3 days + 1)` -> `finalizeCarpet()`.

## frontend (build green, `npm run build` ~6s)
- landing copy fixed: no more "stakers feed the next round". now: bomb opens every
  lock, stake exits at avg backing, only the unclaimed seeds the rebirth.
- `flatTime` wired end to end: `lib/abi.ts` (+ finalizeCarpet, flatTime), `lib/useRound.ts`,
  `components/CarpetBombCard.tsx` (flat state: avg backing price, exit-window countdown,
  finalize button), `components/StakeCard.tsx` (unlock force-enabled when flat,
  "lock force-opened" state).
- `.env.local` points at the live anvil ensemble (below).

## live anvil ensemble (http://127.0.0.1:8545, verified full cycle)
- factory: 0x51A1ceB83B83F1985a81C295d1fF28Afef186E02
- round 1 controller: 0xf3a0988dcdfddf56861be7413ce85db4402bdc82
- hook: 0x26f15c14a54f3cf39f3873ea73ea95e6a5912a88
- psp token: 0xd6ccb4cfb12893d8090acf4205fedda604b50691
- mixETH: 0x2E2Ed0Cfd3AD2f1d34481277b3204d807Ca2F8c2
- zapIn: 0x0355B7B8cb128fA5692729Ab3AAa199C1753f726
- zapOut: 0x202CCe504e04bEd6fC0521238dDf04Bc9E8E15aB
- driven state: round 2 is live now. history: 60 mix predeposit -> launch ->
  1.616M PSP staked (key0) -> 20 mix zap buy -> pot 342.618 PSP -> bomb:
  CarpetBombExecuted 0.015483 mixETH == 342.618 * (79.05/1.749M) EXACT ->
  mode Flat, flatTime set, reserve 79.03451697844478 == 79.05 - 0.015483 ->
  finalizeCarpet -> round 2 born.
- loose end: the live early-unlock send no-op'd silently (totalLocked unchanged).
  suite proves the behavior; re-verify on round 2 if demoing live.

## RESOLVED 2026-08-18: UI live + curve graph fixed

- **curve-graph root cause:** `.env.local` pointed at a pre-C-1 deploy's factory
  (stale addresses after HookDeployer bytecode change). every read reverted;
  `useRound`'s silent catch → EMPTY → "loading curve…" forever. fix = fresh
  deploy + env rewrite. NOTE: deploy console-logs print SIMULATION addresses —
  entropy salts (C-1) make broadcast addresses differ. trust `factory.rounds(id)`
  / broadcast receipts only.
- **live demo:** https://rosy-palm-vzxv.here.now (claimed, permanent slug).
  https pages can't fetch http://127.0.0.1 → anvil is exposed via cloudflared
  quick tunnel: VITE_RPC_URL=https://tobacco-pipe-quarters-equally.trycloudflare.com.
  chain: anvil localnet, factory 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9,
  hook 0x320ad0e24abfa0eb7008540339f26f5ba3b06a88, round 1 Active,
  supply ~3.15M PSP, reserve ~563.8 mixETH.
- **restart sequence if the mac bounces:**
  1. anvil (bg) 2. `PSP_ANVIL=1 forge script script/DeployPSP.s.sol --rpc-url
  http://localhost:8545 --broadcast --slow --sender 0xf39F…92266 --unlocked`
  3. DriveAnvil same flags + DRIVE_FACTORY/DRIVE_ZAPIN env (real addrs from
  broadcast dir!) 4. cloudflared tunnel --url http://localhost:8545 (NEW url →
  update .env.local VITE_RPC_URL) 5. npm run build 6. republish
  `--slug rosy-palm-vzxv` 7. verify chart path via DOM probe.
- F-9 copy fixes: Landing ("exits toll-free at exact average backing"),
  SwapCard flat-mode banner (was "trading paused" — WRONG post-fix, now shows
  toll-free exit message).

## gotchas (do not relearn these)
- cast with tuple args: tuple + each scalar as SEPARATE shell words:
  `cast send $Z "buyWithMix((address,address,uint24,int24,address),uint256,...)" "($MIX,$TOK,0x800000,60,$HOOK)" 20000000000000000000 0 0`
  single-string form dies with "encode length mismatch".
- PoolKey.fee is uint24 with dynamic-fee flag 0x800000. passing uint256 width in
  the signature = wrong selector = bare revert, zero subcalls (looks like a guard
  hit but isn't). verify selectors against deployed bytecode with `cast code | grep`.
- foundry: use `skip()`, never `vm.warp(block.timestamp + x)` — vm.warp reads a
  stale contract timestamp and time-travels backwards.
- anvil impersonation doesn't survive some operations: re-run
  `anvil_impersonateAccount $F` + `anvil_setBalance` before factory-only calls
  (launchPooledBuy) after each forge-script redeploy.
- `deployRound` bare-reverts while a round is live — don't stack rounds manually,
  redeploy the whole ensemble with `PSP_ANVIL=1 forge script script/DeployPSP.s.sol
  --rpc-url http://127.0.0.1:8545 --broadcast --sender 0xf39F...2266 --unlocked`.
- `potState()` = (potPSP, potMixFunded); potMix is PRE-LAUNCH funding, not bomb
  redemption. bomb redemption goes to `factory.creditSidePot()` — assert via
  CarpetBombExecuted event data or factory mixETH balance delta.
- key0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, pk
  0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 (anvil default).

## DECIDED 2026-08-23: curve1 (sawtooth) is THE curve
- scoopy picked curve1 from the tooth iteration (12 teeth: exp ramp -> flip ->
  log tread; beta=0.35, k2=0.5). DeployPSP PSP_CURVE defaults to 1 = curve1.
- curve2 (sharkfin) + curve3 (switchback) stay in the gallery as alternates.
- graphs default LINEAR now (log toggle kept) — teeth read literally.

## 2026-08-23 (later): chosen-art staking + StakerDeployer vessel
- lockWithPepe(amount, pepeId): user-chosen pepe id, dna = keccak(id) — UI rolls
  6 candidates (renderSVG via eth_call), user picks, stake commits that exact art.
  BadPepeId (zero/taken) + PepeAlreadyOwned guards; sequential lock() skips
  claimed ids via skip-loop; plain lock() remains the top-up path.
- PSPStaker creation code moved to StakerDeployer vessel (EIP-170):
  lockWithPepe growth pushed ControllerDeployer 24,291B > 24,000 guard →
  now 16,989B. Vessel wired: RC ctor arg (trailing), deployController param
  (type-identical passthrough preserved), PSPFactory ctor + immutable.
- UI: PepePicker (6-up randomizer + refresh) above the amount form on /stake
  when wallet holds no pepe; submit gates on selection. Linear chart window =
  max(reserves + 1000, reserves * 1.1). Curves tab removed.
- 603/603 green (595 + 7 chosen-art + 1 vessel headroom).

## 2026-08-23 (later) — multi-agent audit + longitudinal e2e
- AUDIT: audits/2026-08-23-multiagent-audit.md. One HIGH: A-1 referral
  attribution poisoning via forged V4 hookData on direct pool swaps —
  PoC test/integration/PoisonedAttribution.t.sol (passes = vulnerable).
  **FIXED 2026-08-26** (see next entry): user-signed record() is the only
  bind path; hook/registry/zap surfaces rewritten, PoC flipped to
  hijack-blocked, R1/R2/R6 rewritten to explicit record().
- E2E: test/integration/LongitudinalLifecycle.t.sol (4 tests) — 8 users,
  2 full rounds, ~4 months, per-phase mixETH/PSP conservation audits,
  staggered-join fee fairness, 102-cycle buy/sell chains, carry exactness.
  Learnings encoded: carry > PREDEPOSIT_CAP (500 mix) closes round-2's
  public window (instant launch); drainAll takes reserve + fee surplus;
  quorum denominator = max(locked, supply) at propose.
- Skill evm-cortex patched with the hookData-identity pattern + the
  longitudinal conservation-audit recipe.

## 2026-08-24 — user's edited studio art landed (THE art fix)
- SOURCES: user re-sent compiled.zip + expressions.txt (Desktop zip was a boomerang of my own bundle).
  All 6 files hash-differ from golden → genuine edit, finally.
- palettes.py export typo: every skin entry `))})` → repaired to `)}`; after fix,
  `python3 script/gen_pepe_art.py` output is BYTE-IDENTICAL to studio-compiled PepeArtData.sol
  (round-trip proof: sources ⟺ on-chain art consistent).
- NEW art: skins +Grey/Orange/Green (8), iris +BASE (7), bgs +Yellow/MAGENTA (10),
  eyes +STARRY/EYEROLL/DEAD (9), hats +NARUTO/TOPHAT/FRENCH/WIZARD/HOMER (10),
  wear +MOGGED/MAGNIFYING/EYEPATCH/HEARTGLASSES (8), items +STITCHES/TATTOO/MUSTACHE/NOOSE,
  SNACK cookie REMOVED (8). COMBOS 1,440,000 → 25,804,800.
- Slot 13 "cookie gold" #B27532 repurposed → blue #001EFF (letter k).
- Letter map: r=7 R=8 c=9(red tongue) n=10 g=11 d=12 k=13 s=14(dark interior) b=15.
  GOTCHA: str() dumps of slot grids are ambiguous (14 vs 1,4) — trust hexgrid composites only.
- PepeDescriptor.t.sol: 6 stale-golden tests re-pinned to MEASURED pixels
  (axis bounds, COMBOS, neutral lip y28→y29, smile seam juts [30][21]/[30][32],
  smirk dark inner band, cigarette moved right x31-43, Item_Others → pipe/chain/
  stitches/tattoo/noose). NoTeethEver still passes.
- 608/608 green. Fresh anvil deploy: Factory 0x18e3…b629, ZapIn 0xc0f1…4f8,
  ZapOut 0xc963…8a75, Descriptor 0x4b6a…af28. DriveAnvil round 1 driven.
- UI: https://rising-fresco-yg7r.here.now/ (anon 24h; claim https://here.now/c/_dRftEf9f28y7yXP)
  — old regal-fennel slug expired, new one issued.

## 2026-08-24 (b) — studio app updated + DNA codec fix
- STUDIO SYNCED to new art: psp_state.json palettes rebuilt from repaired palettes.py
  (8 skins / 7 irises / 10 bgs), GOLDEN_SHA repinned everywhere (0c94847e…13dd) in
  test_compiler.mjs + app-core.js + make_defaults.py, spec/golden/PepeArtData.sol(.sha256)
  refreshed, defaults.js regenerated (self-proves vs golden), dist rebuilt (314,592 B).
  test_compiler.mjs: ALL CHECKS PASSED. Zipped to scoopy (psp-studio.zip, 26 files).
- **BUG FOUND + FIXED (pre-mainnet): eyes field was 3 bits but art has 9 eyes traits**
  → id 8 was UNREACHABLE on-chain ((x&7)%9 = identity; pack(eyes=8) collided with hat).
  COMBOS advertised 25.8M vs 22.9M reachable. Layout widened: eyes 4 bits —
  expr<<0 | eyes<<3(4b) | hat<<7 | wear<<11 | item<<15 | skin<<19 | iris<<22 | bg<<25.
  Patched: PepeDescriptor.sol decode+pack, studio app-core.js packDNA, KnownUnpack test
  (+ eyes=8 regression + pack(decode(maxDna))==maxDna). Descriptor suite 18/18.
  NOTE for future art additions: axis counts are bounded by bit widths —
  expr 8, eyes 16, hat 16, wear 16, item 16, skin 8, iris 8, bg 16 (modulo counts).
- Fresh anvil redeploy (codec): Factory 0xab16…c926, ZapIn 0x38a0…93d4, ZapOut 0x5fc7…177c.
  UI: https://ebony-grace-drd5.here.now/ (claim https://here.now/c/KoErkcW10wB4E9HW).

## UPDATE 2026-08-26 (b): HEAD EDITING in the Trait Studio

The one base head sprite is now editable, first-class:
- `script/traits/head.txt` — single `BASE` block, full-canvas 69-char rows,
  canonical header (byte-stable through compiler traitText). GENERATED from
  the original _base() trace by script/out/gen_head_txt.py; from now on the
  FILE is the source of truth (gen_pepe_art.py loads it, reference trace is
  the fallback). gen also rewrites studio/spec/psp_state.json on regen.
- studio: HEAD tab (first), single BASE entry, all six trait ops disabled,
  full paint tools + per-trait undo work on it, ghost underlay skipped when
  editing the head itself (it IS the head), no-teeth validation extended to
  the head grid, export now carries 6 files (head.txt), import has a
  head-specific replace flow. localStorage format v2 (axes.head); v1 saves
  auto-convert.
- PROOFS: python door — regen via head.txt byte-identical (golden sha
  unchanged 2f41f45a…9229, so forge 612/612 carries over, no contract
  change). Node door — referee ALL CHECKS PASSED (head.txt parse/round-trip/
  byte-stable + golden compile). Browser — paint→preview→undo→compile
  identical, self-test pass, zero console errors.
- LIVE: https://fancy-comet-qdpg.here.now/trait-studio.html
  (claim https://here.now/c/VcuGwTbHGt-ITdyV). Zip: ~/clawd/psp-studio-69.zip.
- Edit flow for scoopy: paint head in studio → Compile → drop PepeArtData.sol
  into src/, OR Export Files → drop head.txt (+ any traits) into
  script/traits/ → python3 script/gen_pepe_art.py. Both doors byte-exact.

## UPDATE 2026-08-27: STUDIO PASS v3 INTEGRATED (scoopy's art, both doors)

Scoopy edited/added traits in the studio and shipped two zips (identical):
6 trait files + palettes.py + his compiled PepeArtData.sol.

- **Axes 10 across the board** (was 8 expr / 9 eyes / 8 wear / 8 item / 8 skin
  / 7 iris): new CRINGE (gritted teeth — human-approved exception to the
  no-teeth invariant, exempted as expr id 8), MEH, CROSSEYED, HOODIE
  (replaces HOMER), 3D/Cyber/Cool shades (MAGNIFYING dropped), CIGAR/BONG/
  JARHEAD/LOLLIPOP (TATTOO/MUSTACHE dropped). **Item file order: JARHEAD=8,
  LOLLIPOP=9** (bit me once — dna item 8 is the jar, not the candy).
- **Palette**: Gold/Diamond/Night/Lime/Orange retuned, Toad+Sick skins,
  Magenta/NeonGreen/Grey irises, Midnight/Void recolored, cookie slot 13 now
  #0055FF (bong water). 7 hand-set slot-19 mid-shadows pinned in
  script/traits/palettes.py; `_extend()` is setdefault — hand-set wins over
  derivation. Studio export flattens palettes (drops 16-23) — always MERGE
  exports into the repo file, never overwrite.
- **PROOF**: repo regen (`python3 script/gen_pepe_art.py`) is BYTE-IDENTICAL
  to his compiled .sol. Golden sha 73fff0a5…d364 (pins: test_compiler.mjs,
  app-core.js badge, make_defaults.py). Referee ALL CHECKS PASSED.
- **Descriptor codec v2**: every axis 4 bits (expr<<0 … bg<<28). Old 3-bit
  expr/skin/iris fields would ALIAS ids 8/9 onto 0/1 — real bug, fixed.
  COMBOS = 10^8 = 100,000,000. Name tables rewritten to match.
- **Tests**: PepeDescriptor.t.sol re-pinned from measured compose (23 edits +
  3 fixes). Key pin deltas: brows #1A2E1E (skin-deep), bridge row 29
  #D3EDCD glint, smirk band LIPSDARK, cigarette filter cols 44-47 + ember
  60-62 rows 43-44, bong glass #5C6270/#C2C8D4 + water #0055FF + cherry,
  lollipop [39][36] RED / [40][31] WHITE, jar [0][33]/[44][9]. Descriptor
  suite 19/19.
- **ArtDump v5** (test/unit/ArtDump.t.sol): dumps 80 axis SVGs + 16 new-trait
  highlights + 16 deterministic randoms to out/art-dump/. Rasterize sheets:
  python3 /tmp/svg_sheet.py out/art-dump out.png 10 (rect-SVG parser + PIL).
- **Frontend**: zero changes needed — PepePanel/PepePicker render via
  eth_call renderSVG; new bytecode picked up on next anvil deploy.
- **Live studio**: https://fancy-comet-qdpg.here.now/trait-studio.html
  (verified serving v3 defaults + new golden badge).
