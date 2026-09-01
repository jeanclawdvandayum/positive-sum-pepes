# REDESIGN PHASE 0 — keystone: tokens + PhaseEngine + Clock instrument

Read BOTH first:
- ~/clawd/positive-sum-pepes/frontend/REDESIGN-SPEC.md (the contract)
- ~/clawd/positive-sum-pepes/frontend/REDESIGN-INVENTORY.md (the map)

Working dir: ~/clawd/positive-sum-pepes/frontend. This phase builds the
shared core ONLY — no page redesigns yet. Existing pages must still render
(visual drift acceptable, breakage not).

Build:
1. TOKENS in the Tailwind theme + a small tokens.css layer:
   bg-0 #0b1424, bg-1 #101c30, bg-2 #16253d, line #22344f, text-hi
   #e8f0f7, text-lo #8ba3bd, phase-calm #3ddc97, phase-heat #ffb347,
   phase-critical #ff4d5e, pot-gold #ffd75e, pepe #58c470. Add
   --accent resolution driven by html[data-phase="calm|heat|critical"]
   (accent = phase color). Preserve the .dark remap pattern — the phase
   attributes must work in both themes. Keep GeistPixel/ELSH font stack
   as the DISPLAY role (load-bearing, do not drop); add DSEG7 (clock
   numerals only), IBM Plex Sans (body 15–16/1.6), IBM Plex Mono
   (tabular data, font-variant-numeric: tabular-nums).
2. src/phase/PhaseEngine.ts: single module owning time→phase: CALM >12h,
   HEAT 12h–1h, CRITICAL <1h, sub10 flag <10min. Sets data-phase + data-sub10
   on <html>, owns the ONE rAF loop for the live clock value, drives
   document.title countdown when sub10. Exposes usePhase() + useCountdown()
   hooks and an injectTime(+5min) event API (for buy→clock jump). Kill the
   three inline 1s interval countdowns' duplication by refactoring them to
   consume PhaseEngine (keep their DOM placements).
3. src/components/Clock.tsx: THE instrument — DSEG7 numerals, radial
   phosphor glow behind numerals (the ONLY permitted gradient), glow
   breathing rate phase-scaled (slow / faster / 1×s), sub-10 breathing
   scale 1.00→1.015, +5:00 injection flash (added minutes flash accent +
   floating "+5:00" chip). Phase word label ("calm/heating/critical")
   rendered alongside. Full prefers-reduced-motion path: instant updates +
   color flashes only.
4. src/components/PotOdometer.tsx: mechanical digit roll + gold flash on
   changed digits; tabular mono; accepts value + unit.
5. Primitives: TickerBar (continuous horizontal stat ticker), PepeChip
   (header identity chip: on-chain SVG pepe + .wei name), Skeleton
   (shimmer in bg-2). Place in src/components/, wire NONE into pages yet
   beyond what's needed to keep the app building.
6. Scanline overlay: pure-CSS 2–3% repeating-gradient fixed overlay,
   pointer-events:none, disabled under prefers-reduced-motion and light
   theme. Mounted but inert until pages adopt it.

Constraints (red-lines from inventory): do not touch data hooks
(useRound/useRpcReads cadences), HashRouter ?ref= capture, RainbowKit
config, pepeArt.json, pepeRender.ts, CurveChart math, PixelIcon grids.
Verify: `npm run build` green (tsc + vite). Print: files created/changed,
build status, and any spec-vs-codebase conflicts you had to resolve.
